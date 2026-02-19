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

**Swift Importer** (`importer/`) — A command-line tool (`lrphotosimporter`) that uses PhotoKit to import photos into Apple Photos, delete them, and open them. The plugin spawns this binary as a subprocess and communicates via XML 🫠.

## Building

Debug build:

```sh
script/build.sh
```

Release build (universal binary, arm64 + x86_64):

```sh
script/build.sh --release
```

Build and install the binary into the plugin's `bin/` directory:

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

Build and install without signing:

```sh
script/release.sh --skip-sign --install
```

This builds a universal binary and copies the plugin to `~/Library/Application Support/Adobe/Lightroom/Modules/`. Restart Lightroom Classic to pick up changes.

## Debugging

Logs are written to `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/ApplePhotosPublisher.log`.

The Swift binary writes errors to stderr, which the Lua plugin captures and logs.

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
4. Sign the binary with your Developer ID
5. Submit to Apple for notarization and wait for approval
6. Package the plugin as a ZIP in `tmp/build/`

Upload to GitHub:

```sh
gh release create v1.0.0 'tmp/build/ApplePhotosPublisher-v1.0.0.zip' --title 'v1.0.0' --notes 'Release notes here'
```

