import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            configuration
            Divider()
            sessionList
            Divider()
            footer
        }
        .frame(minWidth: 920, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { model.scan() }
        .alert("Confirm Batch Migration", isPresented: $model.showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Back Up and Migrate") { model.migrate() }
        } message: {
            Text("This will migrate \(model.selectedSessions.count) sessions from \(model.sourceProvider) to \(model.targetProvider), updating their JSONL files and both SQLite state databases.")
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Provider Migrator")
                    .font(.title2.weight(.semibold))
                Text("Repair historical sessions after switching model providers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isWorking {
                ProgressView().controlSize(.small)
            }
            Button {
                model.scan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.isWorking)
        }
        .padding(20)
    }

    private var configuration: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Text("Codex Home")
                    .frame(width: 92, alignment: .leading)
                TextField("~/.codex", text: $model.codexHomePath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { model.chooseCodexHome() }
            }

            HStack(spacing: 10) {
                Text("Migration")
                    .frame(width: 92, alignment: .leading)
                Picker("Source", selection: $model.sourceProvider) {
                    ForEach(model.sourceProviders, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Target provider", text: $model.targetProvider)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                if model.configuredProviders.contains(model.targetProvider) {
                    Label("Configured", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Label("Missing from config.toml", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Text("Project Filter")
                    .frame(width: 92, alignment: .leading)
                TextField("Leave blank for all projects; selected folders use an exact match", text: $model.projectFilter)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { model.chooseProject() }
                if !model.projectFilter.isEmpty {
                    Button("Clear") { model.projectFilter = "" }
                }
            }

            if model.codexRunning {
                HStack {
                    Label("Codex is running. Scanning is available, but Codex must be fully quit before migration.", systemImage: "exclamationmark.octagon.fill")
                    Spacer()
                    Button("Check Again") {
                        model.codexRunning = CodexStore.isCodexRunning()
                    }
                }
                .foregroundStyle(.red)
                .padding(10)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(20)
    }

    private var sessionList: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("Search title, directory, or session ID", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Text("Showing \(model.filteredSessions.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select All Results") { model.selectAllFiltered() }
                Button("Clear Selection") { model.clearSelection() }
                    .disabled(model.selectedIDs.isEmpty)
            }

            List(model.filteredSessions) { session in
                SessionRow(
                    session: session,
                    isSelected: Binding(
                        get: { model.selectedIDs.contains(session.id) },
                        set: { selected in
                            if selected { model.selectedIDs.insert(session.id) }
                            else { model.selectedIDs.remove(session.id) }
                        }
                    )
                )
            }
            .listStyle(.inset)
            .overlay {
                if model.filteredSessions.isEmpty && !model.isWorking {
                    ContentUnavailableView(
                        "No Matching Sessions",
                        systemImage: "text.magnifyingglass",
                        description: Text("Adjust the provider or project filters.")
                    )
                }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Image(systemName: model.errorMessage == nil ? "info.circle" : "xmark.circle.fill")
                .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
            Text(model.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if model.lastBackupDirectory != nil {
                Button("Show Latest Backup") { model.revealBackup() }
                    .buttonStyle(.link)
            }
            Spacer()
            Text("\(model.selectedSessions.count) selected")
                .foregroundStyle(.secondary)
            Button {
                model.codexRunning = CodexStore.isCodexRunning()
                if model.canMigrate { model.showConfirmation = true }
            } label: {
                Label("Back Up and Migrate", systemImage: "externaldrive.badge.checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canMigrate)
            .help(migrationHelp)
        }
        .padding(16)
    }

    private var migrationHelp: String {
        if model.codexRunning { return "Quit Codex completely first" }
        if !model.configuredProviders.contains(model.targetProvider) { return "Target provider is not configured" }
        if model.selectedSessions.isEmpty { return "Select one or more sessions" }
        return "Create a full backup, then migrate"
    }
}

private struct SessionRow: View {
    let session: SessionRecord
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(session.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if session.isArchived {
                        Text("Archived")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(session.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    Label(session.provider, systemImage: "network")
                    Label(session.model, systemImage: "cpu")
                    Text(session.id)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
    }
}
