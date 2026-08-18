import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var codexHomePath = NSString(string: "~/.codex").expandingTildeInPath
    @Published var sessions: [SessionRecord] = []
    @Published var selectedIDs: Set<String> = []
    @Published var sourceProvider = ""
    @Published var targetProvider = "openai"
    @Published var projectFilter = ""
    @Published var searchText = ""
    @Published var configuredProviders: Set<String> = ["openai"]
    @Published var isWorking = false
    @Published var statusMessage = "Ready to scan sessions"
    @Published var errorMessage: String?
    @Published var lastBackupDirectory: URL?
    @Published var codexRunning = false
    @Published var showConfirmation = false

    var sourceProviders: [String] {
        Array(Set(sessions.map(\.provider))).sorted()
    }

    var filteredSessions: [SessionRecord] {
        sessions.filter { session in
            let providerMatches = sourceProvider.isEmpty || session.provider == sourceProvider
            let projectMatches = projectFilter.isEmpty || session.cwd == projectFilter
            let searchMatches = searchText.isEmpty ||
                session.title.localizedCaseInsensitiveContains(searchText) ||
                session.cwd.localizedCaseInsensitiveContains(searchText) ||
                session.id.localizedCaseInsensitiveContains(searchText)
            return providerMatches && projectMatches && searchMatches
        }
    }

    var selectedSessions: [SessionRecord] {
        sessions.filter { selectedIDs.contains($0.id) && $0.provider == sourceProvider }
    }

    var canMigrate: Bool {
        !isWorking && !selectedSessions.isEmpty &&
            !sourceProvider.isEmpty && sourceProvider != targetProvider &&
            configuredProviders.contains(targetProvider) && !codexRunning
    }

    func scan() {
        isWorking = true
        errorMessage = nil
        statusMessage = "Reading the Codex state database…"
        let path = codexHomePath

        Task {
            do {
                let home = URL(fileURLWithPath: path, isDirectory: true)
                let result = try await Task.detached {
                    let sessions = try CodexStore.scan(codexHome: home)
                    let providers = try CodexStore.configuredProviders(codexHome: home)
                    let running = CodexStore.isCodexRunning()
                    return (sessions, providers, running)
                }.value
                sessions = result.0
                configuredProviders = result.1
                codexRunning = result.2
                if sourceProvider.isEmpty || !sourceProviders.contains(sourceProvider) {
                    sourceProvider = sourceProviders.first(where: { $0 != "openai" }) ?? sourceProviders.first ?? ""
                }
                selectedIDs = selectedIDs.intersection(Set(sessions.map(\.id)))
                statusMessage = "Found \(sessions.count) sessions across \(sourceProviders.count) providers"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Scan failed"
            }
            isWorking = false
        }
    }

    func selectAllFiltered() {
        selectedIDs.formUnion(filteredSessions.map(\.id))
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func chooseCodexHome() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: codexHomePath)
        if panel.runModal() == .OK, let url = panel.url {
            codexHomePath = url.path
            scan()
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            projectFilter = url.path
        }
    }

    func migrate() {
        let chosen = selectedSessions
        guard !chosen.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = "Backing up and migrating \(chosen.count) sessions…"
        let request = MigrationRequest(
            codexHome: URL(fileURLWithPath: codexHomePath, isDirectory: true),
            sourceProvider: sourceProvider,
            targetProvider: targetProvider,
            sessions: chosen
        )

        Task {
            do {
                let result = try await Task.detached { try CodexStore.migrate(request) }.value
                lastBackupDirectory = result.backupDirectory
                statusMessage = "Migration complete: \(result.migratedCount) sessions and \(result.jsonReplacementCount) log fields updated"
                selectedIDs.removeAll()
                scan()
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Migration failed; automatic backup restoration was attempted"
                codexRunning = CodexStore.isCodexRunning()
                isWorking = false
            }
        }
    }

    func revealBackup() {
        guard let lastBackupDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastBackupDirectory])
    }
}
