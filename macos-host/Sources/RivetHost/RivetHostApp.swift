import SwiftUI
import RivetEmbedding
import RivetRuntime
import RivetSystem

@main
struct RivetHostApp: App {
    @StateObject private var model = AppModel()
    private let activationRouter = RivetActivationRouter()

    var body: some Scene {
        WindowGroup(RivetGeneratedConfig.displayName) {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 460)
                .task { model.start() }
                // URL schemes and file associations are declared from
                // rivet.rktd during packaging. Keep activation handling in the
                // native UI layer; forward only application-level data to the
                // Racket backend when the app actually needs it.
                .onOpenURL { url in activationRouter.handle([url]) }
        }
    }
}

/// Forwards backend events to the model on the main actor.
private final class EventRelay: @unchecked Sendable {
    private weak var model: AppModel?
    init(_ model: AppModel) { self.model = model }
    func receive(_ event: RivetEvent) {
        let model = self.model
        Task { @MainActor in model?.handle(event) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Starting embedded Racket CS…"
    @Published var ready = false

    @Published var accounts: [AccountInfo] = []
    @Published var selectedAccountID: String?

    @Published var snapshots: [SnapshotInfo] = []
    @Published var selectedSnapshotIndex: Int64?

    @Published var busy = false
    @Published var autoMinutes: Int64 = 0

    private var backend: EmbeddedRacketBackend?
    private var api: RivetAPI?

    var selectedAccount: AccountInfo? {
        accounts.first { $0.id == selectedAccountID }
    }

    var selectedSnapshot: SnapshotInfo? {
        snapshots.first { $0.index == selectedSnapshotIndex }
    }

    func start() {
        guard backend == nil else { return }

        do {
            let config = try EmbeddedRacketConfiguration.resolvedDefault(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName
            )
            let backend = EmbeddedRacketBackend(configuration: config)
            let relay = EventRelay(self)
            self.backend = backend

            Task.detached { [backend, relay] in
                do {
                    try backend.start { name, value in
                        guard let event = try? RivetEvent.decode(name: name, value: value) else {
                            return
                        }
                        Task { @MainActor in relay.receive(event) }
                    }
                    let api = RivetAPI(client: backend.client)
                    await MainActor.run {
                        self.api = api
                        self.ready = true
                        self.status = "Embedded Racket CS is ready"
                    }
                    await self.refreshAccounts()
                    await self.refreshAutoMinutes()
                } catch {
                    await MainActor.run {
                        self.ready = false
                        self.status = "Backend error: \(error)"
                    }
                }
            }
        } catch {
            status = "Configuration error: \(error)"
        }
    }

    func handle(_ event: RivetEvent) {
        switch event {
        case .notification(let message):
            status = message
        case .snapshots_changed(let message):
            status = message
            Task { await refreshSnapshots() }
        }
    }

    // MARK: - Actions

    func refreshAccounts() async {
        guard let api else { return }
        do {
            let found = try await api.list_accounts()
            accounts = found
            if selectedAccountID == nil, let first = found.first {
                selectAccount(first.id)
            }
            if found.isEmpty {
                status = "No WeChat account directories found on this machine"
            }
        } catch {
            status = "Could not list accounts: \(error)"
        }
    }

    func selectAccount(_ id: String) {
        selectedAccountID = id
        selectedSnapshotIndex = nil
        Task { await refreshSnapshots() }
    }

    func refreshSnapshots() async {
        guard let api, let id = selectedAccountID else { return }
        let previous = snapshots
        snapshots = (try? await api.list_snapshots(account_id: id)) ?? []
        // Keep the user's selection anchored on the timestamp it was made on.
        if let selected = selectedSnapshotIndex,
           !snapshots.contains(where: { $0.index == selected }) {
            selectedSnapshotIndex = previous.count != snapshots.count ? nil : selected
        }
    }

    func snapshotNow() async {
        guard let api, let id = selectedAccountID, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await api.run_snapshot(account_id: id)
            status = result.ok ? result.message : "Snapshot failed: \(result.message)"
            await refreshSnapshots()
        } catch {
            status = "Snapshot error: \(error)"
        }
    }

    /// Restores the snapshot the user picked in the timeline. The backend
    /// always takes a pre-restore safety snapshot first; the confirmation
    /// dialog in the view says so before anything happens.
    func restoreSelected() async {
        guard let api, let id = selectedAccountID, let index = selectedSnapshotIndex, !busy else { return }
        guard let account = selectedAccount else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await api.restore_snapshot(account_id: id,
                                                        index: index,
                                                        target: account.path)
            status = result.ok ? result.message : "Restore failed: \(result.message)"
            await refreshSnapshots()
        } catch {
            status = "Restore error: \(error)"
        }
    }

    func refreshAutoMinutes() async {
        guard let api else { return }
        autoMinutes = (try? await api.get_auto_snapshot()) ?? 0
    }

    func setAutoMinutes(_ minutes: Int64) async {
        guard let api else { return }
        autoMinutes = minutes
        do {
            try await api.set_auto_snapshot(minutes: minutes)
            status = minutes == 0
                ? "Auto snapshot turned off"
                : "Auto snapshot every \(intervalLabel(minutes))"
        } catch {
            status = "Could not set auto snapshot: \(error)"
        }
    }

    private func intervalLabel(_ minutes: Int64) -> String {
        switch minutes {
        case 60: return "hour"
        case 1440: return "day"
        case let m where m % 60 == 0: return "\(m / 60) hours"
        default: return "\(minutes) minutes"
        }
    }
}
