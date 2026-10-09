import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            // Sidebar: WeChat accounts found on this machine.
            List(selection: Binding(
                get: { model.selectedAccountID },
                set: { model.selectAccount($0 ?? "") }
            )) {
                Section("Accounts") {
                    ForEach(model.accounts, id: \.id) { account in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.id)
                                .font(.body.weight(.medium))
                            Text("\(account.path) · \(account.size_label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tag(account.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 260)
        } detail: {
            detail
        }
        .navigationTitle("Keepsake")
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
    }

    /// Snapshot timeline and actions for the selected account.
    private var detail: some View {
        VStack(spacing: 0) {
            if model.selectedAccountID == nil {
                emptyState
            } else {
                snapshotList
                actions
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No account selected", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Select a WeChat account on the left to see its snapshot timeline.")
        }
    }

    private var snapshotList: some View {
        List {
            Section("Snapshot timeline") {
                if model.snapshots.isEmpty {
                    Text("No snapshots yet — take the first one below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.snapshots, id: \.created_at) { snap in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prettyTime(snap.created_at))
                                .font(.body.weight(.medium))
                            Text("\(snap.file_count) files · \(snap.total_label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("#\(snap.index)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.snapshotNow() }
            } label: {
                Label("Snapshot Now", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy)

            Button {
                Task { await model.restoreLatest() }
            } label: {
                Label("Restore Latest", systemImage: "arrow.clockwise.circle")
            }
            .buttonStyle(.bordered)
            .disabled(model.busy)

            Spacer()

            Button {
                Task { await model.refreshAccounts() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Rescan account directories")
        }
        .padding(12)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.ready ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func prettyTime(_ iso: String) -> String {
        // "2026-10-09T12:00:05.000Z" → local "yyyy-MM-dd HH:mm:ss"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: iso) else { return iso }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
