import Foundation

public final class ApplicationTester {
    public let profile: CompatibilityProfile
    public init(profile: CompatibilityProfile = .sequoiaToSonoma) { self.profile = profile }
    public func test(_ app: URL, launch: Bool, observationSeconds: TimeInterval = 5) throws -> TestResult {
        let plist = try AppFiles.plist(app)
        let main = try AppFiles.executable(app, plist: plist)
        let report = try Analyzer(profile: profile).analyze(app)
        let archValid = report.binaries.allSatisfy { $0.architectures.contains(profile.architecture) }
        let missing = report.binaries.flatMap(\.missingAbsoluteDependencies)
        let deploymentValid = report.binaries.allSatisfy { binary in binary.deploymentTargets.allSatisfy { (Int($0.split(separator: ".").first ?? "") ?? 99) <= profile.targetMajor } }
        let bundleValid = !report.binaries.isEmpty && archValid && missing.isEmpty && deploymentValid
        var launched = false
        var running = false
        var exit: Int32?
        var diagnostic = "Static validation completed. Launch was not requested."
        if launch && bundleValid {
            let process = Process()
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.executableURL = main
            process.currentDirectoryURL = app.appendingPathComponent("Contents/MacOS")
            do {
                try process.run()
                launched = true
                let deadline = Date().addingTimeInterval(max(1, min(observationSeconds, 60)))
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                running = process.isRunning
                if !running { exit = process.terminationStatus }
                diagnostic = running ? "Process remained running during the observation window. User must verify functionality." : "Process exited during the observation window with status \(exit ?? -1)."
                if !running {
                    let stderr = String(decoding: stderrPipe.fileHandleForReading.availableData.prefix(16_384), as: UTF8.self)
                    if !stderr.isEmpty { diagnostic += "\nStandard error: \(stderr)" }
                    if let crash = recentCrashLog(name: app.deletingPathExtension().lastPathComponent) { diagnostic += "\nRecent crash report: \(crash)" }
                }
            } catch { diagnostic = "Launch failed: \(error.localizedDescription)" }
        }
        let status: CompatibilityStatus = !bundleValid || (launch && !launched) || (launched && !running) ? .failed : (running ? .launchSuccessful : .untested)
        return TestResult(date: Date(), appPath: app.path, bundleValid: bundleValid, architectureValid: archValid, signatureValid: report.originalSignatureValid, missingDependencies: missing, launched: launched, remainedRunning: running, exitCode: exit, status: status, diagnostic: diagnostic)
    }
    private func recentCrashLog(name: String) -> String? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let recent = files.filter { $0.lastPathComponent.hasPrefix(name + "_") && ($0.pathExtension == "crash" || $0.pathExtension == "ips") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let url = recent.first, let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(date) < 120 else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8_192)) ?? Data()
        return url.lastPathComponent + "\n" + String(decoding: data, as: UTF8.self)
    }
}
