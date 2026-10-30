# Development

## Prerequisites

- Xcode (Swift 5.9+)
- macOS 12+
- Lightroom Classic 6.0+

Optional tools for linting:

```sh
brew install shellcheck lua-language-server
```

## Project Structure

The project has two main components:

**Lightroom Plugin** (`ApplePhotosPublisher.lrplugin/`) — Lua code that integrates with Lightroom Classic's publish service API. Handles photo rendering, metadata tracking, and orchestration.

**Swift Importer** (`importer/`) — A Swift executable (`lrphotosimporter`) packaged as `bin/Apple Photos Publisher for Lightroom Classic.app`. It uses PhotoKit to import photos into Apple Photos, delete them, and open them. The plugin invokes the bundled `lrphotoslauncher`, which starts the app through Launch Services (`open -n`) and monitors its actual termination with `kqueue`. XML, stderr, launcher diagnostics, and the kernel exit status are captured separately.

Launching through Launch Services is essential: executing the binary directly, even inside the `.app`, attributes Photos access to Lightroom. Lightroom lacks `NSPhotoLibraryUsageDescription`, so macOS aborts the request before showing a prompt. The helper app carries its own usage description and owns its own Photos permission.

The launcher never accesses Photos. It creates a private directory for each operation and passes it to the helper. Before parsing its command, the helper writes its PID and waits. The launcher registers `NOTE_EXIT | NOTE_EXITSTATUS` for that PID, then acknowledges the handshake. This prevents fast commands from exiting before monitoring starts. The kernel reports normal exit codes and terminating signals separately, including `SIGKILL`. Lightroom accepts success XML only after a confirmed exit code 0; a crash after writing XML is still reported as a crash.

Startup is bounded to 30 seconds. If the helper fails before the monitor attaches, the result explicitly says its exit status is unavailable. If the launcher disappears before acknowledging, the helper exits without starting a Photos operation. After acknowledgment, the monitor waits for the operation to finish, including time spent in permission or deletion dialogs.

## Building

Debug build:

```sh
script/build.sh
```

Release build (universal binary, arm64 + x86_64):

```sh
script/build.sh --release
```

Build and package the helper app into the plugin's `bin/` directory:

```sh
script/build.sh --install
script/build.sh --release --install
```

## Testing

Tests use Apple's Testing framework (`@Test`, `@Suite`).

```sh
cd importer && swift test
```

## Linting

```sh
script/lint.sh
```

Lints shell scripts with `shellcheck` and Lua code with `lua-language-server` (using `.luarc.json` for config). Both tools are optional; linting is skipped if they're not installed.

## Installing for Local Testing

Build and install with an ad-hoc signature (no Developer ID required):

```sh
script/release.sh --skip-sign --install
```

This builds a universal binary and copies the plugin to `~/Library/Application Support/Adobe/Lightroom/Modules/`. Restart Lightroom Classic to pick up changes.

Both build paths sign the entire helper app locally, including its Info.plist. The executable's linker signature alone is insufficient for TCC to validate the app. Ad-hoc grants can be invalidated by rebuilds; use Developer ID signing for distributed releases and stable identity across updates.

The helper uses the hardened runtime with the Photos Library entitlement in `importer/Entitlements.plist`. This entitlement permits requesting access; the user must still grant Full Access. Run `bash tests/package-helper-tests.sh` after building to check the bundle signature, entitlement, and Info.plist tamper detection.

## Debugging

Logs are written to `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/ApplePhotosPublisher.log`.

The Swift binary writes errors to stderr, which the Lua plugin captures and logs. Each monitored operation logs the helper PID, exit code or signal, and raw kernel wait status. For crashes before the startup handshake, look for `lrphotosimporter*.ips` in `~/Library/Logs/DiagnosticReports/`.

Check permission without importing or deleting photos (omit `--status-only` to request Full Access):

```sh
helper="$HOME/Library/Application Support/Adobe/Lightroom/Modules/ApplePhotosPublisher.lrplugin/bin/Apple Photos Publisher for Lightroom Classic.app"
capture_dir=$(mktemp -d)
"$helper/Contents/MacOS/lrphotoslauncher" --app "$helper" --stdout "$capture_dir/stdout" --stderr "$capture_dir/stderr" --status "$capture_dir/status" -- authorize --status-only
cat "$capture_dir/stdout" "$capture_dir/stderr" "$capture_dir/status"
rm -r "$capture_dir"
```

Use `authorize --check-library` to also validate the Photos service connection with an empty change transaction. This changes no photos and detects code-identity failures that the initial permission callback alone does not catch.

Test the Lua launch/capture behavior with `lua tests/launch-tests.lua`. These tests simulate the launcher and do not access Photos. After building a release, use `lua tests/launch-tests.lua --integration` to also exercise Launch Services with the built helper and an empty import manifest.

Run `python3 tests/monitor-tests.py <path-to-lrphotoslauncher>` to test real Launch Services launches, exit codes, fatal signals, crashes after XML, startup failures, and repeated fast commands. The test builds a disposable app with the production handshake code and never accesses Photos. `swift test` also checks wait-status decoding and failure when the launcher never acknowledges.

## Releasing

### Credential Setup

Set environment variables (e.g. in `.envrc`):

```sh
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export TEAM_ID="TEAMID"
```

Store notarization credentials in the keychain:

```sh
xcrun notarytool store-credentials "notarytool" --apple-id <your-apple-id> --team-id <your-team-id>
```

Generate an App Specific password at https://account.apple.com/account/manage and enter it when prompted.

### Creating a Release

Tag the commit with a version number:

```sh
git tag v1.0.0
```

Run the release script:

```sh
script/release.sh
```

This will:

1. Determine version from the git tag (falls back to `<latest-tag>-<short-sha>`)
2. Generate `BuildInfo.swift` and `BuildInfo.lua` with version metadata
3. Build a universal binary (arm64 + x86_64)
4. Package and sign the helper app with your Developer ID (including its Info.plist)
5. Submit the helper app to Apple for notarization and staple the approval ticket
6. Package the plugin as a ZIP in `tmp/build/`

Upload to GitHub:

```sh
gh release create v1.0.0 'tmp/build/ApplePhotosPublisher-v1.0.0.zip' --title 'v1.0.0' --notes 'Release notes here'
```

