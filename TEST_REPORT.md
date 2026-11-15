# Compatibility test report — 14 November 2026

## Test machine

MacBook Air 2018 (`MacBookAir8,1`), dual-core Intel Core i5-8210Y at 1.6 GHz, 8 GB RAM, macOS Sonoma **14.8.9** (`23J631`), Xcode **15.4** with macOS 14.5 SDK. All bundle inspection and controlled-app execution below occurred on this machine.

Seqoma built as an x86_64 macOS 14 SwiftUI app. `swift test` passed **3 tests** (metadata rebuild, cancellation and cleanup, SQLite, profile serialization). The built app passed ad-hoc code-signature verification, launched on Sonoma, and its native scanner displayed the controlled bundle's unsupported 15.0 binary target. Its source rebuild pipeline was also exercised from the CLI.

## Real application releases

All three bundles were downloaded from official GitHub releases, inspected locally, and verified with `codesign --verify --deep --strict`. Each has x86_64 and arm64 slices and declares macOS 15.0 in its actual `Info.plist`. Seqoma produced full JSON reports with per-file SHA-256 manifests. Its automatic rebuild attempts stopped safely at planning. A separate manual source port of SpreadPaper was subsequently built and launched on Sonoma, as described below.

| App and official source | Download integrity | Actual binary finding | Rebuild outcome |
| --- | --- | --- | --- |
| [Vitrine 1.3.0](https://github.com/johnny4young/vitrine/releases/tag/v1.3.0) | DMG SHA-256 `b4c35b4fa80552800bd1a6aa09b5d9b5f3dc0146f0727386a301fe468dcbc350` matches [publisher checksum](https://github.com/johnny4young/vitrine/releases/download/v1.3.0/Vitrine-1.3.0.dmg.sha256); signature valid | Main app, CLI, and menu-bar helper all target 15.0; Swift libraries absent from Sonoma SDK | Refused: no version-specific source or binary recipe supplied. [Full report](Reports/Vitrine-1.3.0.json) |
| [SpreadPaper 1.10.1](https://github.com/spreadpaper/SpreadPaper/releases/tag/v1.10.1) | ZIP SHA-256 `2570275bc582021110c88c23d8734a6edee632f6b652e1dbd51ce31f77f0d77a` recorded locally; no publisher checksum asset found; signature valid | Main executable targets 15.0 and references `libswift_Builtin_float.dylib`, absent from Sonoma SDK | Seqoma refused metadata rebuild; a separate manual source port compiled and launched. [Original report](Reports/SpreadPaper-1.10.1.json) |
| [Peekaboo 4.9.5](https://github.com/openclaw/Peekaboo/releases/tag/v4.9.5) | ZIP SHA-256 `d176301b0ef4b695c11cbdb8c0bdbbc71f47f866f76c734ddad8343ab5f93e38` matches [publisher checksums](https://github.com/openclaw/Peekaboo/releases/download/v4.9.5/checksums.txt); signature valid | Main executable targets 15.0; multiple Swift libraries absent from Sonoma SDK | Refused: no verified replacement recipe. [Full report](Reports/Peekaboo-4.9.5.json) |

SpreadPaper's [open source repository](https://github.com/spreadpaper/SpreadPaper) was cloned at tag `v1.10.1` for the source port. Its original Xcode project uses project format 77 and synchronized groups that Xcode 15.4 cannot open. An isolated XcodeGen project targeting macOS 14 and Swift 5 was generated. See the source-port note below.

NeatEditor 1.0.34 was screened but excluded from the three candidates. Its current [release ZIP](https://github.com/NeatMacApps/NeatEditor/releases/tag/v1.0.34) declares **macOS 26.0**, has a Mach-O minimum of 26.0, and lacks `CFBundleExecutable` in the included `Info.plist`, despite the repository README listing 15.0 support. It is not a qualifying 15 → 14 target.

## User-supplied Gemini app

The user's `<user-downloads>/Gemini.app` is version **1.144.4.1467**. Seqoma verified its code signature, inspected 12 Mach-O files, and recorded SHA-256 hashes for 3,633 regular files. Its main executable has only an **arm64** slice and a **15.0** Mach-O deployment target; several extensions are also arm64-only and target 15.0. [Full JSON report](Reports/Gemini-1.144.4.1467.json).

Google's [official Mac requirements](https://support.google.com/gemini/answer/17011627?hl=en) specify macOS 15 or later **with Apple Silicon**. This Intel MacBook Air cannot execute the supplied app, and changing metadata cannot create an x86_64 executable or supply the newer Swift libraries. Seqoma classified it as `unsupportedRuntime`.

The requested install attempt used `seqoma rebuild <user-downloads>/Gemini.app /Applications`. It exited with status **1** during compatibility planning, citing the missing x86_64 main slice, macOS 15 binary targets, arm64-only extensions, and unavailable Swift libraries. Seqoma created no `Gemini-Seqoma-*.app` in `/Applications`, did not launch Gemini, and did not alter the original bundle. There is no technically honest version-specific binary recipe for converting this closed-source arm64 application into an Intel macOS 14 app.

## Controlled source rebuild

The included open-source fixture declares macOS 15.0 and has a real x86_64 Mach-O minimum of **15.0**. Because this machine has Xcode 15.4, the original test binary uses a stub for Apple's [macOS 15 `NSWindow.requestSharingOfWindow` API](https://developer.apple.com/documentation/macos-release-notes/macos-15-release-notes). The source file contains the actual API branch for an Xcode 16 build. Seqoma's matching source recipe compiled the **Sonoma clipboard fallback**, replacing the executable and changing the actual Mach-O minimum to **14.0**. The original and rebuilt executable SHA-256 values differ; this was a real source recompile, not a metadata-only edit.

- Original executable SHA-256: `92565a777b16413d270501e32fb65f57bce39ded8c1cd1cb6ae81f41520e887c`.
- Rebuilt executable SHA-256: `5b4c972123829e37bc8bc8d2eeb2367db6d0f777e73c2ddeaf54fe1017f9113f`.
- Rebuilt bundle: ad-hoc signature valid; x86_64 architecture valid; static bundle validation passed. [Rebuild record](Reports/Controlled-rebuild.json) · [Static test](Reports/Controlled-static.json).
- Sonoma launch: process remained running through the 3-second observation window. [Launch test](Reports/Controlled-launch.json).
- Actual UI: SwiftUI window rendered with editable text and an optional-feature button. Clicking the button changed its status to **“Sonoma fallback: note copied to clipboard.”** A separate fallback self-test passed using a named test pasteboard.

The clipboard fallback works, but macOS 15 window sharing is unavailable on Sonoma. The test does not verify the original 15-only feature or full functionality on Sequoia. The controlled fixture and rebuilt app are included under `Controlled/` as ZIPs.

## Results and next work

| Measure | Result |
| --- | --- |
| Successful rebuilds | 1 controlled source rebuild through Seqoma; 1 metadata fixture in unit tests; 1 manual SpreadPaper source port |
| Automatic real-app rebuild attempts | 4 safely refused (three release candidates plus user-supplied Gemini); the manual SpreadPaper port is separate from Seqoma's recipe engine |
| Launch tests | Controlled rebuilt app, manually ported SpreadPaper, and Seqoma itself launched on Intel Sonoma |
| Basic functionality | Controlled text UI and clipboard fallback; SpreadPaper welcome screen, navigation, icons, and image picker observed on hardware |
| Known broken or unverified functionality | Controlled Sequoia window sharing replaced by clipboard copy; SpreadPaper image import, preview, wallpaper application, scheduling, and settings remain unverified; Gemini was not run |

The next useful development step is to integrate Xcode project builds into Seqoma's source recipe engine and use SpreadPaper's pinned source port as an integration test. Its actual wallpaper behavior and scheduling need testing before marking it fully functional. See [LIMITATIONS.md](LIMITATIONS.md).

### SpreadPaper source-port note

The official release's main executable SHA-256 is `25c0f60113217ebe675d45aae76c030d07327a7907c4d6cb220d21f445a1caa1`. Its Mach-O minimum is 15.0 and it links a Swift library unavailable in Sonoma. The port compiled the tagged source using Xcode 15.4's macOS 14.5 SDK and an isolated XcodeGen project. Narrow source changes removed Swift 6-only `nonisolated` modifiers, adjusted actor isolation and a captured image array, and replaced the settings-opening action with an AppKit action. The project's generated image symbols were retained. The pinned PhosphorSwift 2.1.0 package's very large asset catalog was excluded from the code build; icons load from the original release's bundled `Assets.car` through a narrow resource lookup patch. The original resources were preserved in the test copy.

The newly compiled executable is **x86_64**, has a real Mach-O minimum of **14.0**, and has SHA-256 `505eb7db8db247d85d029cc78c01d7de1da861bf811b6991402915c765d4b720`. It replaced the main executable in an isolated copy of the official release; `LSMinimumSystemVersion` was set to 14.0, and the copy was ad-hoc signed. `codesign --verify --deep --strict` and Seqoma's static and launch tests passed. [Port analysis](Reports/SpreadPaper-Sonoma-analysis.json) · [Launch test](Reports/SpreadPaper-Sonoma-launch.json). The process remained running through the 5-second observation window. The welcome screen, Continue/Back navigation, image picker, and package icons rendered in the native UI. No wallpaper was applied to the tester's desktop, so the central feature and scheduling are **not verified**. [Source changes and build notes](Experimental/README.md) are included; the experimental app archive is not distributed with the Seqoma beta and was not installed in `/Applications`.

This source port was assembled manually and then analyzed and tested with Seqoma. Seqoma's current source recipe adapter compiles a specified Swift file set with `swiftc`; it cannot yet drive this multi-target Xcode project. The result demonstrates a credible real-app source rebuild on Sonoma while keeping that engine limitation explicit.
