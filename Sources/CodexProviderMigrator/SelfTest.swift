import Foundation

enum SelfTest {
    static func run() -> Int32 {
        do {
            try testProviderFields()
            try testJSONStringIsolation()
            try testProviderEscaping()
            try testEndToEndMigration()
            print("Self-test passed: 4 checks")
            return 0
        } catch {
            fputs("Self-test failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func testProviderFields() throws {
        let input = """
        {"type":"session_meta","payload":{"model_provider":"codebyai"}}
        {"type":"event_msg","payload":{"thread_settings":{"model_provider_id":"codebyai"}}}
        """
        let result = try CodexStore.providerFieldReplacements(
            in: input,
            source: "codebyai",
            target: "openai"
        )
        try require(result.count == 2, "expected two provider replacements")
        try require(!result.text.contains("\"model_provider\":\"codebyai\""), "old provider remained")
        try require(result.text.contains("\"model_provider_id\":\"openai\""), "settings provider was not updated")
    }

    private static func testJSONStringIsolation() throws {
        let input = #"{"message":"example: \"model_provider\":\"codebyai\""}"#
        let result = try CodexStore.providerFieldReplacements(
            in: input,
            source: "codebyai",
            target: "openai"
        )
        try require(result.count == 0 && result.text == input, "rewrote provider text inside a JSON string")
    }

    private static func testProviderEscaping() throws {
        let input = #"{"model_provider":"old\"provider"}"#
        let result = try CodexStore.providerFieldReplacements(
            in: input,
            source: #"old"provider"#,
            target: #"new\provider"#
        )
        try require(result.count == 1, "escaped provider name was not replaced")
        try require(result.text.contains(#""model_provider":"new\\provider""#), "target provider was not JSON escaped")
    }

    private static func testEndToEndMigration() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "codex-provider-migrator-self-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "sqlite"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
        try "".write(to: root.appending(path: "config.toml"), atomically: true, encoding: .utf8)

        let rollout = root.appending(path: "sessions/test-session.jsonl")
        let jsonl = """
        {"type":"session_meta","payload":{"model_provider":"codebyai"}}
        {"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model_provider_id":"codebyai","model":"gpt-5.5"}}}

        """
        try jsonl.write(to: rollout, atomically: true, encoding: .utf8)

        let state = root.appending(path: "state_5.sqlite")
        try sqlite(state, """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, cwd TEXT NOT NULL,
            title TEXT, model_provider TEXT NOT NULL, model TEXT, archived INTEGER NOT NULL,
            updated_at_ms INTEGER, recency_at_ms INTEGER
        );
        INSERT INTO threads VALUES (
            'test-session', '\(sqlEscaped(rollout.path))', '/tmp/project', 'Test session',
            'codebyai', 'gpt-5.5', 0, 10, 10
        );
        """)

        let catalog = root.appending(path: "sqlite/codex-dev.db")
        try sqlite(catalog, """
        CREATE TABLE local_thread_catalog (
            thread_id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, observation_sequence INTEGER NOT NULL
        );
        CREATE TABLE local_thread_catalog_metadata (
            id INTEGER PRIMARY KEY, catalog_revision INTEGER NOT NULL
        );
        INSERT INTO local_thread_catalog VALUES ('test-session', 'codebyai', 1);
        INSERT INTO local_thread_catalog_metadata VALUES (1, 1);
        """)

        let sessions = try CodexStore.scan(codexHome: root)
        try require(sessions.count == 1 && sessions[0].provider == "codebyai", "fixture scan failed")
        let result = try CodexStore.migrate(
            MigrationRequest(
                codexHome: root,
                sourceProvider: "codebyai",
                targetProvider: "openai",
                sessions: sessions
            ),
            requireCodexStopped: false
        )

        try require(result.migratedCount == 1, "migration count was incorrect")
        try require(FileManager.default.fileExists(atPath: result.backupDirectory.path), "backup was not created")
        let migratedSessions = try CodexStore.scan(codexHome: root)
        try require(migratedSessions[0].provider == "openai", "state database was not migrated")
        let migratedJSONL = try String(contentsOf: rollout, encoding: .utf8)
        try require(!migratedJSONL.contains("codebyai"), "JSONL was not migrated")
        let catalogProvider = try sqliteOutput(catalog, "SELECT model_provider FROM local_thread_catalog;")
        try require(catalogProvider.trimmingCharacters(in: .whitespacesAndNewlines) == "openai", "catalog database was not migrated")
    }

    private static func sqlite(_ database: URL, _ sql: String) throws {
        _ = try run("/usr/bin/sqlite3", [database.path, sql])
    }

    private static func sqliteOutput(_ database: URL, _ sql: String) throws -> String {
        try run("/usr/bin/sqlite3", [database.path, sql])
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 {
            throw SelfTestError.failed(output)
        }
        return output
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw SelfTestError.failed(message)
        }
    }

    private enum SelfTestError: Error {
        case failed(String)
    }
}
