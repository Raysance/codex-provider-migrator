# Codex Provider Migrator

A native macOS utility for batch-migrating the `model_provider` metadata of local Codex sessions. It repairs historical sessions that stop opening after a custom provider is removed or the active provider is changed.

## Why This Exists

Codex stores provider information in three separate layers. Updating only the session JSONL is not enough. This app migrates all three layers together:

- `model_provider` and `model_provider_id` fields in session JSONL files
- `threads.model_provider` in `~/.codex/state_5.sqlite`, used when a session is resumed
- `local_thread_catalog.model_provider` in `~/.codex/sqlite/codex-dev.db`, used by the task list

## Features

- Scan all local Codex sessions
- Filter by source provider, project directory, title, or session ID
- Select and migrate multiple sessions at once
- Validate that the target provider exists in `config.toml`
- Include active and archived sessions
- Create a complete backup before every migration
- Attempt automatic rollback if any migration step fails
- Verify JSONL metadata and SQLite database integrity after migration
- Prevent writes while Codex is running, avoiding stale state being written back

## Requirements

- macOS 14 or later
- Apple Silicon build for the packaged release
- The built-in `openai` provider or a target provider configured under `[model_providers.<id>]` in `~/.codex/config.toml`

## Usage

1. Open **Codex Provider Migrator** and scan `~/.codex`.
2. Choose the source and target providers.
3. Optionally filter by project directory, then select the sessions to migrate.
4. Quit Codex completely and click **Check Again** in the red warning banner.
5. Click **Back Up and Migrate** and confirm the preview.
6. Reopen Codex after the migration succeeds.

Backups are stored in:

```text
~/.codex/backup/provider-migrator-YYYYMMDD-HHMMSS/
```

Each backup contains the relevant SQLite databases, original session files, `config.toml`, and a JSON manifest.

## Build

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
```

The packaged app is written to:

```text
dist/Codex Provider Migrator.app
```

Run the built-in unit and end-to-end migration checks with:

```bash
swift run CodexProviderMigrator --self-test
```

## Safety Notes

The app edits undocumented local Codex storage formats. Always keep the generated backup until you have reopened and verified the migrated sessions. The app intentionally refuses to migrate while the ChatGPT/Codex desktop process is running.

## License

MIT
