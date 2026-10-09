import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    @State private var confirmingRestore: SnapshotInfo?

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
        .confirmationDialog(restoreDialogTitle,
                            isPresented: restoreDialogBinding,
                            titleVisibility: .visible) {
            Button("Restore Snapshot #\(confirmingRestore?.index ?? 0)",
                   role: .destructive) {
                Task { await model.restoreSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current directory contents are snapshotted first, so nothing can be lost by going back.")
        }
    }

    private var restoreDialogTitle: String {
        guard let snap = confirmingRestore else { return "Restore snapshot?" }
        return "Restore \(prettyTime(snap.created_at))?"
    }

    private var restoreDialogBinding: Binding<Bool> {
        Binding(get: { confirmingRestore != nil },
                set: { if !$0 { confirmingRestore = nil } })
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
                    Button {
                        confirmingRestore = snap
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(prettyTime(snap.created_at))
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("\(snap.file_count) files · \(snap.total_label)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if snap.index == model.selectedSnapshotIndex {
                                Text("selected")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Image(systemName: "arrow.clockwise.circle")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.inset)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    Task { await model.snapshotNow() }
                } label: {
                    Label("Snapshot Now", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)

                Button {
                    if let snap = model.selectedSnapshot {
                        confirmingRestore = snap
                    }
                } label: {
                    Label(model.selectedSnapshotIndex == nil
                          ? "Select a Snapshot to Restore"
                          : "Restore #\(model.selectedSnapshotIndex ?? 0)",
                          systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.bordered)
                .disabled(model.busy || model.selectedSnapshotIndex == nil)

                Spacer()

                Button {
                    Task { await model.refreshAccounts() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan account directories")
            }

            Picker("Auto snapshot", selection: Binding(
                get: { model.autoMinutes },
                set: { newValue, _ in Task { await model.setAutoMinutes(newValue) } }
            )) {
                Text("Off").tag(Int64(0))
                Text("Every 15 minutes").tag(Int64(15))
                Text("Every hour").tag(Int64(60))
                Text("Every 6 hours").tag(Int64(360))
                Text("Every day").tag(Int64(1440))
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
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
