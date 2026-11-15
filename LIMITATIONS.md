# Known limitations and roadmap

- Symbol inventory does not map every import to its first supported macOS release. An imported symbol may be weak or never executed. Objective-C selector coverage is partial. Availability confidence is deliberately low.
- `@rpath`, `@loader_path`, `dlopen`, Swift runtime ABI, plug-ins, helper activation, app extensions, and private entitlements need deeper resolution and runtime tests. Missing system libraries are checked against the installed Sonoma SDK; SDK absence is reported conservatively.
- Binary patch recipes are intentionally empty. No general machine-code rewriting or guessed function substitution is implemented. Adding a recipe requires exact app ID/version, binary hash, architecture, offset or symbol proof, patch bytes, validation, and rollback tests.
- Source recipes compile listed Swift files with `swiftc` and can install hash-pinned replacements for multiple incompatible components. Seqoma verifies their hashes and final Mach-O targets, but it does not build those replacement frameworks or extensions automatically. Xcode, SwiftPM, and Objective-C project detection and automated source edits are future work. A manual XcodeGen source port of SpreadPaper 1.10.1 compiled and launched on Intel Sonoma, but Seqoma cannot yet repeat that multi-target build from its own recipe engine. Its wallpaper and scheduling functions remain unverified.
- Ad-hoc signing does not restore Developer ID, notarization, original entitlements, or original distribution trust. Some protected apps cannot be rebuilt.
- Launch monitoring detects startup and immediate exit, not correct user workflows. User verification is stored separately. A process may fail later.
- Cancellation is checked between inspection and rebuild stages; an individual `otool`, `nm`, compiler, or signing command runs to completion. A future runner should enforce timeouts and terminate child processes on cancellation.
- Large apps can incur many subprocesses. The scanner streams SHA-256 and reads only Mach-O headers before invoking tooling, but `nm` output is capped for reporting and command output memory can reach 2 MB per process.
- The only enabled profile is macOS 15 → 14 x86_64. ARM and other version pairs remain disabled.
- An arm64-only executable cannot be rebuilt into an Intel executable by changing metadata or Mach-O load commands. Gemini's supplied macOS app has this blocker; without x86_64 source or a vendor Intel build, Seqoma must refuse it. A future Apple Silicon profile would be a separate target and would still need to resolve macOS 15 APIs for Sonoma.
- Sketch 2026.3.1 includes Intel code, but many app components target macOS 15 and import libraries missing on Sonoma. A component recipe could install compatible replacements if Sketch's publisher supplied them or an authorized source build produced them. Seqoma cannot derive those binaries from the closed-source release itself.

## Next steps

1. Resolve per-architecture load commands and dyld paths using Mach-O parsing, including `@rpath` and weak libraries.
2. Add an OS availability database from SDK interfaces and symbol exports, with confidence levels for weak imports and selectors.
3. Implement signed, reviewed, hash-pinned binary recipes for selected open-source apps where a narrow patch can be proved safe.
4. Add Xcode and SwiftPM source adapters, starting with the pinned SpreadPaper source port, and a macOS 15 SDK CI lane for the controlled Sequoia feature.
5. Expand integration tests to helper apps, extensions, hardened runtime, damaged signatures, cancellation during subprocesses, and disk-space failures.
6. Add arm64 and subsequent version profiles only with separate test fixtures and hardware validation.
