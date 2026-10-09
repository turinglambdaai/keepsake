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

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Starting embedded Racket CS…"
    @Published var ready = false

    @Published var accounts: [AccountInfo] = []
    @Published var selectedAccountID: String?

    @Published var snapshots: [SnapshotInfo] = []
    @Published var busy = false

    @Published var repoLocation = ""

    private var backend: EmbeddedRacketBackend?

    private var api: RivetAPI?

    var selectedAccount: AccountInfo? {
        accounts.first { $0.id == selectedAccountID }
    }

    func start() {
        guard backend == nil else { return }

        do {
            let config = try EmbeddedRacketConfiguration.resolvedDefault(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName
            )
            let backend = EmbeddedRacketBackend(configuration: config)
            self.backend = backend

            Task.detached { [backend] in
                do {
                    try backend.start()
                    let api = RivetAPI(client: backend.client)
                    await MainActor.run {
                        self.api = api
                        self.ready = true
                        self.status = "Embedded Racket CS is ready"
                    }
                    await self.refreshAccounts()
                    await self.refreshRepoLocation()
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

    // MARK: - Actions

    func refreshAccounts() async {
        guard let api else { return }
        do {
            let found = try await api.list_accounts()
            accounts = found
            if selectedAccountID == nil, let first = found.first {
                selectAccount(first.id)
            }
            status = found.isEmpty
                ? "No WeChat account directories found on this machine"
                : status
        } catch {
            status = "Could not list accounts: \(error)"
        }
    }

    func refreshRepoLocation() async {
        guard let api else { return }
        repoLocation = (try? await api.get_repository_location()) ?? repoLocation
    }

    func selectAccount(_ id: String) {
        selectedAccountID = id
        Task { await refreshSnapshots() }
    }

    func refreshSnapshots() async {
        guard let api, let id = selectedAccountID else { return }
        snapshots = (try? await api.list_snapshots(account_id: id)) ?? []
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

    func restoreLatest() async {
        guard let api, let account = selectedAccount, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await api.restore_latest(account_id: account.id,
                                                      target: account.path)
            status = result.ok ? result.message : "Restore failed: \(result.message)"
            await refreshSnapshots()
        } catch {
            status = "Restore error: \(error)"
        }
    }

    func saveRepoLocation() async {
        guard let api, !repoLocation.isEmpty else { return }
        _ = try? await api.set_repository_location(path: repoLocation)
        await refreshAccounts()
    }
}
