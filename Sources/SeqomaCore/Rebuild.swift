import Foundation

public final class Rebuilder {
    public let profile: CompatibilityProfile
    public init(profile: CompatibilityProfile = .sequoiaToSonoma) { self.profile = profile }

    public func plan(_ report: AnalysisReport, sourceRecipe: SourceRecipe? = nil) throws -> RebuildPlan {
        guard report.profile == profile, profile == .sequoiaToSonoma else { throw SeqomaError.unsupported("Compatibility profile is not implemented") }
        if let recipe = sourceRecipe {
            guard recipe.bundleID == report.bundleID, recipe.version == report.version, recipe.targetProfile == profile.id, recipe.requiredArchitectures.contains(profile.architecture) else {
                throw SeqomaError.unsupported("Source recipe does not match this exact app, version, and profile")
            }
            return RebuildPlan(reportID: report.id, strategy: .source, recipeID: recipe.id, modifications: recipe.modifications + ["Compile specified source files for macOS \(profile.targetVersion) and \(profile.architecture)", "Replace executable in isolated copy", "Update deployment metadata", "Ad-hoc sign rebuilt bundle"], limitations: recipe.limitations, validationProcedures: recipe.validationProcedures, rollbackBehavior: recipe.rollbackBehavior)
        }
        guard report.classification == .metadataCandidate, report.issues.isEmpty else {
            throw SeqomaError.unsupported("No verified recipe for required binary or dependency changes: \(report.issues.joined(separator: "; "))")
        }
        if report.entitlements.contains("com.apple.private") || report.entitlements.contains("com.apple.developer") {
            throw SeqomaError.unsupported("Protected entitlements cannot be recreated by local signing")
        }
        return RebuildPlan(reportID: report.id, strategy: .metadata, recipeID: "metadata-v1", modifications: ["Change only top-level LSMinimumSystemVersion in copied bundle to \(profile.targetVersion)", "Ad-hoc sign rebuilt bundle"], limitations: ["Binary target was not changed", "Runtime compatibility remains unverified", "Original signature and notarization are not preserved"], validationProcedures: ["Re-scan every Mach-O target and architecture", "Verify dynamic dependencies and ad-hoc signature", "Offer explicit launch test"], rollbackBehavior: "Delete the generated application copy")
    }

    public func rebuild(_ report: AnalysisReport, plan: RebuildPlan, destination: URL, sourceDirectory: URL? = nil, recipe: SourceRecipe? = nil, cancelled: () -> Bool = { false }) throws -> RebuildResult {
        guard plan.reportID == report.id, report.profile == profile else { throw SeqomaError.unsupported("Plan and analysis report do not match") }
        let original = URL(fileURLWithPath: report.sourcePath).standardizedFileURL
        let originalPlist = try AppFiles.plist(original)
        let originalExecutable = try AppFiles.executable(original, plist: originalPlist)
        guard try AppFiles.sha256(originalExecutable) == report.originalMainSHA256 else { throw SeqomaError.unsupported("Original executable changed since analysis") }
        guard try AppFiles.hashManifest(original, cancelled: cancelled) == report.originalFileSHA256 else { throw SeqomaError.unsupported("Original application files changed since analysis") }
        guard destination.isFileURL else { throw SeqomaError.unsupported("Destination must be local") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let originalResolved = original.resolvingSymlinksInPath().path
        let destinationResolved = destination.resolvingSymlinksInPath().path
        guard !destinationResolved.hasPrefix(originalResolved + "/"), destinationResolved != originalResolved else { throw SeqomaError.unsupported("Destination cannot be inside the original application") }
        let size = try AppFiles.bundleBytes(original)
        let free = (try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
        guard free > size * 2 + 100_000_000 else { throw SeqomaError.unsupported("Insufficient free disk space for safe rebuild") }
        let workspace = destination.appendingPathComponent(".seqoma-work-\(UUID().uuidString)", isDirectory: true)
        let workingApp = workspace.appendingPathComponent(original.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if cancelled() { throw SeqomaError.cancelled }
        try FileManager.default.copyItem(at: original, to: workingApp)
        if cancelled() { throw SeqomaError.cancelled }
        guard try AppFiles.hashManifest(workingApp, cancelled: cancelled) == report.originalFileSHA256 else { throw SeqomaError.unsupported("Working copy does not match analyzed original files") }
        switch plan.strategy {
        case .metadata:
            guard report.classification == .metadataCandidate else { throw SeqomaError.unsupported("Metadata strategy not allowed by analysis") }
        case .source:
            guard let sourceDirectory = sourceDirectory, let recipe = recipe, recipe.id == plan.recipeID else { throw SeqomaError.unsupported("Matching source recipe and source directory required") }
            try compileSource(recipe: recipe, from: sourceDirectory, into: workingApp, executableName: originalPlist["CFBundleExecutable"] as? String ?? "")
        case .binaryRecipe:
            throw SeqomaError.unsupported("No version-specific binary patch recipe is installed")
        }
        if cancelled() { throw SeqomaError.cancelled }
        var plist = try AppFiles.plist(workingApp)
        plist["LSMinimumSystemVersion"] = profile.targetVersion
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: workingApp.appendingPathComponent("Contents/Info.plist"), options: .atomic)
        let sign = try CommandRunner.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", workingApp.path])
        guard sign.0 == 0 else { throw SeqomaError.command("Ad-hoc signing failed: \(sign.1)") }
        let verify = try CommandRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", workingApp.path])
        guard verify.0 == 0 else { throw SeqomaError.command("Rebuilt signature failed validation: \(verify.1)") }
        let rebuilt = try Analyzer(profile: profile).analyze(workingApp, cancelled: cancelled)
        guard rebuilt.binaries.allSatisfy({ $0.architectures.contains(profile.architecture) && !$0.deploymentTargets.contains(where: { (Int($0.split(separator: ".").first ?? "") ?? 0) > profile.targetMajor }) && $0.missingAbsoluteDependencies.isEmpty }) else {
            throw SeqomaError.unsupported("Rebuilt bundle still has incompatible binary targets, architecture, or missing absolute libraries")
        }
        if cancelled() { throw SeqomaError.cancelled }
        let stem = original.deletingPathExtension().lastPathComponent
        let output = destination.appendingPathComponent("\(stem)-Seqoma-\(UUID().uuidString.prefix(8)).app")
        try FileManager.default.moveItem(at: workingApp, to: output)
        let main = try AppFiles.executable(output, plist: AppFiles.plist(output))
        return RebuildResult(id: UUID(), date: Date(), originalPath: original.path, outputPath: output.path, strategy: plan.strategy, recipeID: plan.recipeID, originalMainSHA256: report.originalMainSHA256, rebuiltMainSHA256: try AppFiles.sha256(main), signatureValid: true, status: .rebuildSuccessful, notes: ["Local ad-hoc signature replaces the original developer signature", "Original notarization and private entitlements are not preserved", "Runtime functionality is untested"])
    }

    private func compileSource(recipe: SourceRecipe, from sourceDirectory: URL, into app: URL, executableName: String) throws {
        guard !executableName.isEmpty, executableName == recipe.executable else { throw SeqomaError.unsupported("Recipe executable does not match bundle") }
        guard !recipe.sourceFiles.isEmpty else { throw SeqomaError.unsupported("Recipe lists no source files") }
        let root = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let files = try recipe.sourceFiles.map { relative -> URL in
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw SeqomaError.unsupported("Source recipe path escapes source directory") }
            let url = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { throw SeqomaError.unsupported("Missing source file: \(relative)") }
            return url
        }
        let sdk = try CommandRunner.run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"])
        guard sdk.0 == 0 else { throw SeqomaError.command("macOS SDK not found") }
        let swiftc = try CommandRunner.run("/usr/bin/xcrun", ["--find", "swiftc"])
        guard swiftc.0 == 0 else { throw SeqomaError.command("Swift compiler not found") }
        let output = app.appendingPathComponent("Contents/MacOS/\(executableName)")
        let flags = recipe.compilationFlags
        guard flags.allSatisfy({ !$0.contains("@") && !$0.contains("-o") }) else { throw SeqomaError.unsupported("Unsafe compiler flags in recipe") }
        let args = ["-target", "x86_64-apple-macosx\(profile.targetVersion)", "-sdk", sdk.1.trimmingCharacters(in: .whitespacesAndNewlines), "-DSEQOMA_SONOMA", "-o", output.path] + flags + files.map(\.path)
        let build = try CommandRunner.run(swiftc.1.trimmingCharacters(in: .whitespacesAndNewlines), args)
        guard build.0 == 0 else { throw SeqomaError.command("Source build failed: \(build.1)") }
    }
}
