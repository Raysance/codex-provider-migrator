import Foundation

struct CodexStore: Sendable {
    private struct DatabaseSession: Decodable {
        let id: String
        let rollout_path: String
        let cwd: String
        let title: String?
        let model_provider: String
        let model: String?
        let archived: Int
        let updated_at_ms: Int64?
    }

    private static var fileManager: FileManager { FileManager.default }

    static func scan(codexHome: URL) throws -> [SessionRecord] {
        let stateDatabase = codexHome.appending(path: "state_5.sqlite")
        guard fileManager.fileExists(atPath: stateDatabase.path) else {
            throw MigratorError.missingFile(stateDatabase.path)
        }

        let sql = """
        SELECT id, rollout_path, cwd, title, model_provider, model, archived, updated_at_ms
        FROM threads
        ORDER BY recency_at_ms DESC, updated_at_ms DESC;
        """
        let data = try runSQLiteJSON(database: stateDatabase, sql: sql)
        let rows: [DatabaseSession]
        do {
            rows = try JSONDecoder().decode([DatabaseSession].self, from: data)
        } catch {
            throw MigratorError.invalidDatabaseOutput
        }

        return rows.map {
            SessionRecord(
                id: $0.id,
                rolloutPath: $0.rollout_path,
                cwd: $0.cwd,
                title: normalizedTitle($0.title),
                provider: $0.model_provider,
                model: $0.model ?? "Unknown model",
                isArchived: $0.archived != 0,
                updatedAt: $0.updated_at_ms ?? 0
            )
        }
    }

    static func configuredProviders(codexHome: URL) throws -> Set<String> {
        var providers: Set<String> = ["openai"]
        let config = codexHome.appending(path: "config.toml")
        guard fileManager.fileExists(atPath: config.path) else { return providers }

        let contents = try String(contentsOf: config, encoding: .utf8)
        let pattern = #"(?m)^\s*\[model_providers\.(?:\"([^\"]+)\"|([^\].\s]+))\]\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(contents.startIndex..., in: contents)
        for match in regex.matches(in: contents, range: range) {
            for index in [1, 2] where match.range(at: index).location != NSNotFound {
                if let range = Range(match.range(at: index), in: contents) {
                    providers.insert(String(contents[range]))
                }
            }
        }
        return providers
    }

    static func isCodexRunning() -> Bool {
        for processName in ["Codex", "ChatGPT"] {
            let result = try? runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
                arguments: ["-x", processName]
            )
            if result?.status == 0 { return true }
        }
        return false
    }

    static func migrate(
        _ request: MigrationRequest,
        requireCodexStopped: Bool = true
    ) throws -> MigrationResult {
        guard !request.sessions.isEmpty else { throw MigratorError.noSessionsSelected }
        guard request.sourceProvider != request.targetProvider else { throw MigratorError.sameProvider }
        if requireCodexStopped, isCodexRunning() {
            throw MigratorError.codexIsRunning
        }

        let configured = try configuredProviders(codexHome: request.codexHome)
        guard configured.contains(request.targetProvider) else {
            throw MigratorError.targetProviderNotConfigured(request.targetProvider)
        }

        let backupDirectory = try createBackup(for: request)
        var replacementCount = 0

        do {
            for session in request.sessions {
                replacementCount += try rewriteSession(
                    at: URL(fileURLWithPath: session.rolloutPath),
                    source: request.sourceProvider,
                    target: request.targetProvider
                )
            }
            try updateDatabases(request)
            try verify(request)
        } catch {
            try? restoreBackup(backupDirectory, codexHome: request.codexHome)
            throw error
        }

        return MigrationResult(
            migratedCount: request.sessions.count,
            jsonReplacementCount: replacementCount,
            backupDirectory: backupDirectory
        )
    }

    static func providerFieldReplacements(
        in input: String,
        source: String,
        target: String
    ) throws -> (text: String, count: Int) {
        let sourceLiteral = try jsonStringLiteral(source)
        let targetLiteral = try jsonStringLiteral(target)
        var output = input
        var count = 0

        for key in ["model_provider", "model_provider_id"] {
            let needle = "\"\(key)\":\(sourceLiteral)"
            let replacement = "\"\(key)\":\(targetLiteral)"
            let matches = output.components(separatedBy: needle).count - 1
            if matches > 0 {
                output = output.replacingOccurrences(of: needle, with: replacement)
                count += matches
            }
        }
        return (output, count)
    }

    private static func normalizedTitle(_ title: String?) -> String {
        let compact = (title ?? "Untitled session")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? "Untitled session" : compact
    }

    private static func createBackup(for request: MigrationRequest) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = request.codexHome
            .appending(path: "backup")
            .appending(path: "provider-migrator-\(formatter.string(from: Date()))")
        let sessionBackup = root.appending(path: "sessions")
        try fileManager.createDirectory(at: sessionBackup, withIntermediateDirectories: true)

        for databaseName in ["state_5.sqlite", "sqlite/codex-dev.db"] {
            let source = request.codexHome.appending(path: databaseName)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = root.appending(path: source.lastPathComponent)
            try backupSQLite(source: source, destination: destination)
        }

        let config = request.codexHome.appending(path: "config.toml")
        if fileManager.fileExists(atPath: config.path) {
            try fileManager.copyItem(at: config, to: root.appending(path: "config.toml"))
        }

        for session in request.sessions {
            let source = URL(fileURLWithPath: session.rolloutPath)
            guard fileManager.fileExists(atPath: source.path) else {
                throw MigratorError.missingFile(source.path)
            }
            let destination = sessionBackup.appending(path: "\(session.id).jsonl")
            try fileManager.copyItem(at: source, to: destination)
        }

        let manifest = BackupManifest(
            createdAt: Date(),
            sourceProvider: request.sourceProvider,
            targetProvider: request.targetProvider,
            sessions: request.sessions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appending(path: "manifest.json"), options: .atomic)
        return root
    }

    private static func restoreBackup(_ backup: URL, codexHome: URL) throws {
        let stateBackup = backup.appending(path: "state_5.sqlite")
        if fileManager.fileExists(atPath: stateBackup.path) {
            try replaceFile(at: codexHome.appending(path: "state_5.sqlite"), with: stateBackup)
        }
        let catalogBackup = backup.appending(path: "codex-dev.db")
        if fileManager.fileExists(atPath: catalogBackup.path) {
            try replaceFile(at: codexHome.appending(path: "sqlite/codex-dev.db"), with: catalogBackup)
        }

        let manifestURL = backup.appending(path: "manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        for session in manifest.sessions {
            let saved = backup.appending(path: "sessions/\(session.id).jsonl")
            try replaceFile(at: URL(fileURLWithPath: session.rolloutPath), with: saved)
        }
    }

    private static func replaceFile(at destination: URL, with source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func rewriteSession(at url: URL, source: String, target: String) throws -> Int {
        guard fileManager.fileExists(atPath: url.path) else {
            throw MigratorError.missingFile(url.path)
        }
        let input = try String(contentsOf: url, encoding: .utf8)
        let rewritten = try providerFieldReplacements(in: input, source: source, target: target)
        if rewritten.count > 0 {
            try rewritten.text.write(to: url, atomically: true, encoding: .utf8)
        }
        return rewritten.count
    }

    private static func updateDatabases(_ request: MigrationRequest) throws {
        let ids = request.sessions.map { sqlQuote($0.id) }.joined(separator: ",")
        let source = sqlQuote(request.sourceProvider)
        let target = sqlQuote(request.targetProvider)

        let stateDatabase = request.codexHome.appending(path: "state_5.sqlite")
        let stateSQL = """
        BEGIN IMMEDIATE;
        UPDATE threads SET model_provider=\(target)
        WHERE id IN (\(ids)) AND model_provider=\(source);
        COMMIT;
        """
        try runSQLite(database: stateDatabase, sql: stateSQL)

        let catalog = request.codexHome.appending(path: "sqlite/codex-dev.db")
        if fileManager.fileExists(atPath: catalog.path) {
            let catalogSQL = """
            BEGIN IMMEDIATE;
            UPDATE local_thread_catalog SET model_provider=\(target), observation_sequence=observation_sequence+1
            WHERE thread_id IN (\(ids)) AND model_provider=\(source);
            UPDATE local_thread_catalog_metadata SET catalog_revision=catalog_revision+1 WHERE id=1;
            COMMIT;
            """
            try runSQLite(database: catalog, sql: catalogSQL)
        }
    }

    private static func verify(_ request: MigrationRequest) throws {
        let ids = request.sessions.map { sqlQuote($0.id) }.joined(separator: ",")
        let target = sqlQuote(request.targetProvider)
        let stateDatabase = request.codexHome.appending(path: "state_5.sqlite")
        let sql = "SELECT COUNT(*) AS count FROM threads WHERE id IN (\(ids)) AND model_provider=\(target);"
        let data = try runSQLiteJSON(database: stateDatabase, sql: sql)
        struct CountRow: Decodable { let count: Int }
        let rows = try JSONDecoder().decode([CountRow].self, from: data)
        guard rows.first?.count == request.sessions.count else {
            throw MigratorError.verificationFailed("Not every row in the recovery state database was updated.")
        }

        let sourceLiteral = try jsonStringLiteral(request.sourceProvider)
        for session in request.sessions {
            let text = try String(contentsOfFile: session.rolloutPath, encoding: .utf8)
            if text.contains("\"model_provider\":\(sourceLiteral)") ||
                text.contains("\"model_provider_id\":\(sourceLiteral)") {
                throw MigratorError.verificationFailed("Session \(session.id) still contains the old provider.")
            }
        }

        for database in [stateDatabase, request.codexHome.appending(path: "sqlite/codex-dev.db")]
            where fileManager.fileExists(atPath: database.path) {
            let result = try runSQLiteText(database: database, sql: "PRAGMA integrity_check;")
            guard result.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
                throw MigratorError.verificationFailed("Database integrity check failed for \(database.lastPathComponent).")
            }
        }
    }

    private static func backupSQLite(source: URL, destination: URL) throws {
        let escaped = destination.path.replacingOccurrences(of: "'", with: "''")
        try runSQLite(database: source, sql: ".backup '\(escaped)'")
    }

    private static func runSQLite(database: URL, sql: String) throws {
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [database.path, sql]
        )
        guard result.status == 0 else {
            throw MigratorError.commandFailed(command: "sqlite3", output: result.output)
        }
    }

    private static func runSQLiteText(database: URL, sql: String) throws -> String {
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [database.path, sql]
        )
        guard result.status == 0 else {
            throw MigratorError.commandFailed(command: "sqlite3", output: result.output)
        }
        return result.output
    }

    private static func runSQLiteJSON(database: URL, sql: String) throws -> Data {
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-json", database.path, sql]
        )
        guard result.status == 0 else {
            throw MigratorError.commandFailed(command: "sqlite3", output: result.output)
        }
        return result.data.isEmpty ? Data("[]".utf8) : result.data
    }

    private struct ProcessResult {
        let status: Int32
        let data: Data
        var output: String { String(decoding: data, as: UTF8.self) }
    }

    private static func runProcess(executable: URL, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, data: data)
    }

    private static func jsonStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func sqlQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
