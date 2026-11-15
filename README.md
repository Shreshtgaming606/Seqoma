# Seqoma

Seqoma is a native SwiftUI macOS utility and command line tool for conservative, offline rebuilding of user-authorized application bundles. The implemented profile targets **macOS 15 → macOS 14 on x86_64**. It creates a separate copy and never edits the selected app.

**Beta status:** Seqoma analyzes app bundles, plans only supported changes, rebuilds an isolated copy, and records launch tests. It is not a universal macOS compatibility layer. The initial beta supports a narrow metadata path and version-specific Swift source recipes. It refuses unsupported binary targets and has no general binary patch recipes.

The app icon is generated from the user-supplied artwork preserved at `Brand/Seqoma-logo.png`. `Brand/generate_icon.sh` removes only the dark exterior connected to the image border, so the rounded corners are transparent, then regenerates every icon size and the full-resolution `AppIcon.icns` included in the Xcode target.

This is an experimental compatibility tool. Static inspection cannot prove that a new API is unused or that every feature works. A successful rebuild means that the copied bundle passed structural and signing checks; it does not mean the app is fully compatible.

## Build and run

Requirements: Intel macOS 14, Xcode 15.4 or newer, and Command Line Tools. The included Xcode project is directly openable in Xcode 15.4.

Prebuilt beta artifacts are attached to [GitHub Releases](https://github.com/Shreshtgaming606/Seqoma/releases): `Seqoma.app.zip` (native GUI) and `seqoma-cli.zip` (CLI). Unzip them locally; the GUI and CLI are ad-hoc signed, not notarized. Build from source if your Mac does not trust those local signatures.

```sh
xcodebuild -project Seqoma.xcodeproj -scheme Seqoma -configuration Debug \
  -destination 'platform=macOS,arch=x86_64' CODE_SIGNING_ALLOWED=NO build
swift test
swift build
```

Open `Seqoma.xcodeproj` and run the **Seqoma** scheme, or use the built `Seqoma.app`. If regenerating the project from `project.yml`, run `generate_project.sh` with XcodeGen installed. The script adjusts XcodeGen 2.46's project object version for Xcode 15.4.

The GUI has Dashboard, Scanner, Analyzer, Rebuild Manager, Rebuilt Applications, Testing & Diagnostics, and Settings. Drag an `.app` into the window or choose it in Finder. Review the report, create a plan, select a destination, and rebuild. Testing is a separate explicit action. The GUI accepts a source recipe JSON and source folder when available.

The CLI writes structured JSON to stdout and stores results in `~/Library/Application Support/Seqoma/compatibility.sqlite3`. Set `SEQOMA_DATABASE` to use another database path.

```sh
.build/debug/seqoma analyze /path/to/App.app --json report.json
.build/debug/seqoma plan /path/to/App.app
.build/debug/seqoma rebuild /path/to/App.app /path/to/destination
.build/debug/seqoma test /path/to/rebuilt.app
.build/debug/seqoma test /path/to/rebuilt.app --launch --seconds 5
.build/debug/seqoma list
```

`--launch` explicitly permits launching the rebuilt app. Startup observation is 1–60 seconds in the CLI, 1–30 seconds in the GUI. A process remaining alive yields “launch successful” only. The user can record basic or partial functionality and notes in the GUI.

## Source rebuilding

Source rebuilding requires a version-specific `SourceRecipe.json` and a source directory. The recipe is matched to the bundle ID, version, and compatibility profile, and lists exact Swift source files and compiler flags. It compiles for `x86_64-apple-macosx14.0`, replaces the executable in an isolated copy, updates metadata, ad-hoc signs, and validates the result.

```sh
.build/debug/seqoma rebuild /path/to/ControlledApp.app /path/to/output \
  --source Controlled --recipe Controlled/SourceRecipe.json
```

`Controlled/ControlledApp.swift` includes a macOS 15 window-sharing branch and a Sonoma fallback that copies the note to the clipboard. Its `build_fixture.sh` builds a Sequoia-minimum UI test bundle using an Xcode 15-compatible stub branch so that the actual 15.0 Mach-O target can be tested here. Building the original window-sharing branch requires the macOS 15 SDK in Xcode 16. The source recipe compiles the Sonoma branch under Xcode 15.4. This test checks source recompilation and target change, but cannot prove that the original macOS 15 API branch works on Sequoia.

An [experimental SpreadPaper 1.10.1 source port](Experimental/README.md) was also compiled for x86_64 macOS 14 and launched on the test Mac. Its welcome screen, navigation, icons, and image picker worked. This port was assembled manually from a pinned open-source tag and the official release resources, then analyzed and launched with Seqoma. It does not yet have a Seqoma Xcode-project recipe, and wallpaper application remains unverified.

## Pipeline and safety

1. **Inspect:** Validate `Info.plist` and main executable; enumerate Mach-O files; collect architectures, deployment targets, library references, imports, weak imports, Objective-C class references, signature, entitlements, and hashes. The macOS 14 SDK's `.tbd` records help distinguish libraries in the dyld shared cache from unavailable libraries.
2. **Plan:** The built-in metadata recipe is allowed only when every inspected binary supports x86_64, targets 14 or earlier, and has no missing absolute dependency. A matching source recipe can replace incompatible executable code. The binary recipe slot currently has no installed patches and refuses all requests.
3. **Rebuild:** Check source hash and free space; copy into a unique temporary workspace; apply only the selected strategy; sign the modified copy locally; re-scan it; move it to a unique output name. The temporary workspace is deleted on success, cancellation, or failure.
4. **Test:** Revalidate the bundle, then optionally launch and observe it. Capture immediate exit status, standard error, and a recent crash report excerpt when present. Save results in SQLite. Export analysis JSON through the GUI or CLI.

The original signature, notarization, and privileged entitlements are not preserved after modification. Seqoma does not alter system files, disable SIP or Gatekeeper, clear quarantine, inject into other processes, or bypass licensing. Only run it on apps you are authorized to modify.

## Compatibility decisions

| Classification | Meaning | Current action |
| --- | --- | --- |
| Metadata candidate | Declared minimum is 15+, but inspected binaries target 14 or earlier and no blocking dependency was found | Copy, adjust top-level metadata, sign, validate, then test |
| Recipe patchable | A version-specific binary recipe exists | No binary recipes installed yet |
| Source rebuildable | Matching source recipe supplied | Recompile listed Swift files for Sonoma |
| Unsupported runtime | At least one inspected target, architecture, or absolute dependency blocks Sonoma | Refuse metadata rebuild |
| Insufficient evidence | Version or binary evidence is inconclusive | Refuse rebuild |

See [TEST_REPORT.md](TEST_REPORT.md) for real release results and [LIMITATIONS.md](LIMITATIONS.md) for remaining engineering work.
