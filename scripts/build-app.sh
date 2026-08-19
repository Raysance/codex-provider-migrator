#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
output_dir="$project_dir/dist"
app_dir="$output_dir/Codex Provider Migrator.app"
archive_path="$output_dir/CodexProviderMigrator-v1.0.1-macOS-arm64.zip"

cd "$project_dir"
swift build -c release

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/release/CodexProviderMigrator" "$app_dir/Contents/MacOS/CodexProviderMigrator"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_dir"
rm -f "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive_path"

printf '%s\n' "$app_dir"
printf '%s\n' "$archive_path"
