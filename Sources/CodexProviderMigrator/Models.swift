import Foundation

struct SessionRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let rolloutPath: String
    let cwd: String
    let title: String
    let provider: String
    let model: String
    let isArchived: Bool
    let updatedAt: Int64
}

struct MigrationRequest: Sendable {
    let codexHome: URL
    let sourceProvider: String
    let targetProvider: String
    let sessions: [SessionRecord]
}

struct MigrationResult: Sendable {
    let migratedCount: Int
    let jsonReplacementCount: Int
    let backupDirectory: URL
}

struct BackupManifest: Codable, Sendable {
    let createdAt: Date
    let sourceProvider: String
    let targetProvider: String
    let sessions: [SessionRecord]
}

enum MigratorError: LocalizedError {
    case missingFile(String)
    case commandFailed(command: String, output: String)
    case invalidDatabaseOutput
    case noSessionsSelected
    case sameProvider
    case targetProviderNotConfigured(String)
    case codexIsRunning
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            return "File not found: \(path)"
        case .commandFailed(let command, let output):
            return "Command failed: \(command)\n\(output)"
        case .invalidDatabaseOutput:
            return "Could not parse the Codex session database."
        case .noSessionsSelected:
            return "Select at least one session."
        case .sameProvider:
            return "The source and target providers must be different."
        case .targetProviderNotConfigured(let provider):
            return "The target provider “\(provider)” is not configured in config.toml."
        case .codexIsRunning:
            return "Codex is running. Quit Codex completely before migrating to prevent stale state from being written back."
        case .verificationFailed(let detail):
            return "Post-migration verification failed: \(detail)"
        }
    }
}
