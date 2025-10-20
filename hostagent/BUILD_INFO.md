# Build Info

This project uses an automatically generated build ID to help track which version of the binary you're running during development.

## How It Works

When you run `swift build`, a build plugin automatically generates a `BuildInfo.swift` file in the HavenCore module containing:
- `BuildInfo.version` - The semantic version (e.g., "1.0.0")
- `BuildInfo.buildID` - A timestamp in format `YYYYMMDD.HHMM` (UTC)
- `BuildInfo.versionWithBuildID` - Combined version string (e.g., `1.0.0+20251020.2003`)

## Where It Appears

The build ID is appended to the version number in:
- `hostagent --version` output
- The startup banner when the agent launches
- The `/v1/health` endpoint response
- Any other place that displays the version

## Example

```bash
$ .build/debug/hostagent --version
1.0.0+20251020.2003

$ curl http://localhost:8080/v1/health | jq .version
"1.0.0+20251020.2003"
```

## Forcing a New Build ID

The build ID is only regenerated when you do a clean build:

```bash
swift package clean && swift build
```

Or when the build plugin detects source changes that require recompilation of the HavenCore module.

## Implementation Details

- **Script**: `Scripts/generate-build-info.sh` - Shell script that generates the BuildInfo.swift file
- **Plugin**: `Plugins/GenerateBuildInfo/plugin.swift` - Swift Package Manager build plugin
- **Generated File**: `.build/.../HavenCore-GenerateBuildInfo/BuildInfo.swift` - Auto-generated, don't edit
- **Version Source**: Currently hardcoded as "1.0.0" in the generation script
