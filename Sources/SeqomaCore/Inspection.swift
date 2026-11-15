import Foundation
import CryptoKit

public enum CommandRunner {
    @discardableResult public static func run(_ executable: String, _ arguments: [String], limit: Int = 2_000_000) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        var bytes = Data()
        while true {
            let part = pipe.fileHandleForReading.availableData
            if part.isEmpty { break }
            if bytes.count < limit { bytes.append(part.prefix(limit - bytes.count)) }
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }
}

public enum AppFiles {
    public static func plist(_ app: URL) throws -> [String: Any] {
        guard app.pathExtension == "app", FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
            throw SeqomaError.invalidApp("Select an application bundle containing Contents/Info.plist")
        }
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SeqomaError.invalidApp("Invalid Info.plist")
        }
        return value
    }
    public static func executable(_ app: URL, plist: [String: Any]) throws -> URL {
        guard let name = plist["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw SeqomaError.invalidApp("Missing or invalid CFBundleExecutable")
        }
        let url = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw SeqomaError.invalidApp("Main executable is missing or not executable") }
        return url
    }
    public static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let known: Set<UInt32> = [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca]
        return known.contains(magic)
    }
    public static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func bundleBytes(_ app: URL) throws -> Int64 {
        guard let en = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return 0 }
        var sum: Int64 = 0
        for case let url as URL in en {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { sum += Int64(values.fileSize ?? 0) }
        }
        return sum
    }
    public static func hashManifest(_ app: URL, cancelled: () -> Bool = { false }) throws -> [String: String] {
        guard let en = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { throw SeqomaError.invalidApp("Cannot enumerate application files") }
        var hashes: [String: String] = [:]
        for case let url as URL in en {
            if cancelled() { throw SeqomaError.cancelled }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                let relative = String(url.path.dropFirst(app.path.count + 1))
                hashes[relative] = try sha256(url)
            }
        }
        return hashes
    }
}

public final class Analyzer {
    public let profile: CompatibilityProfile
    public init(profile: CompatibilityProfile = .sequoiaToSonoma) { self.profile = profile }
    public func analyze(_ app: URL, cancelled: () -> Bool = { false }) throws -> AnalysisReport {
        let app = app.standardizedFileURL
        let plist = try AppFiles.plist(app)
        let main = try AppFiles.executable(app, plist: plist)
        guard AppFiles.isMachO(main) else { throw SeqomaError.invalidApp("Main executable is not Mach-O") }
        let declared = plist["LSMinimumSystemVersion"] as? String ?? "unknown"
        let bundleID = plist["CFBundleIdentifier"] as? String ?? "unknown"
        let version = plist["CFBundleShortVersionString"] as? String ?? (plist["CFBundleVersion"] as? String ?? "unknown")
        var urls = [main]
        var seenPaths: Set<String> = [main.resolvingSymlinksInPath().path]
        if let en = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: { _, _ in true }) {
            for case let url as URL in en {
                if cancelled() { throw SeqomaError.cancelled }
                let path = url.resolvingSymlinksInPath().path
                if !seenPaths.contains(path) && AppFiles.isMachO(url) { urls.append(url); seenPaths.insert(path) }
            }
        }
        let sdkRoot = (try? CommandRunner.run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"]).1.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        var binaries: [BinaryRecord] = []
        for url in urls {
            if cancelled() { throw SeqomaError.cancelled }
            binaries.append(try inspectBinary(url, root: app, sdkRoot: sdkRoot))
        }
        let signature = try CommandRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", app.path])
        let details = try CommandRunner.run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path]).1
        let entitlements = (try? CommandRunner.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", app.path]).1) ?? ""
        var issues: [String] = []
        var limitations: [String] = []
        if !binaries[0].architectures.contains(profile.architecture) { issues.append("Main executable has no \(profile.architecture) slice") }
        for binary in binaries {
            if binary.deploymentTargets.isEmpty { issues.append("Cannot establish Mach-O deployment target: \(binary.path)") }
            if !binary.architectures.contains(profile.architecture) { issues.append("Embedded binary lacks \(profile.architecture): \(binary.path)") }
            if binary.deploymentTargets.contains(where: { major($0) > profile.targetMajor }) { issues.append("Binary deployment target exceeds Sonoma: \(binary.path)") }
            if !binary.missingAbsoluteDependencies.isEmpty { issues.append("Missing absolute dependencies: \(binary.missingAbsoluteDependencies.joined(separator: ", "))") }
        }
        if !signature.0.equalsZero { limitations.append("Original signature verification failed: \(signature.1.trimmingCharacters(in: .whitespacesAndNewlines))") }
        if entitlements.contains("com.apple.developer") || entitlements.contains("com.apple.private") { limitations.append("Special or private entitlements may not survive local signing") }
        limitations.append("Imported symbols and Objective-C selectors are inventoried; OS availability and runtime execution are not proven")
        limitations.append("@rpath and dlopen dependencies need runtime validation")
        let classification: Classification
        let confidence: Double
        if !issues.isEmpty { classification = .unsupportedRuntime; confidence = 0.1 }
        else if declared != "unknown" && major(declared) >= profile.sourceMajor {
            classification = .metadataCandidate; confidence = 0.45
        } else { classification = .insufficientEvidence; confidence = 0.25 }
        return AnalysisReport(id: UUID(), date: Date(), sourcePath: app.path, appName: (plist["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent), bundleID: bundleID, version: version, declaredMinimum: declared, profile: profile, binaries: binaries, originalSignatureValid: signature.0 == 0, signatureDetail: details + signature.1, entitlements: entitlements, hardenedRuntime: details.contains("runtime"), classification: classification, confidence: confidence, issues: issues, limitations: limitations, originalMainSHA256: try AppFiles.sha256(main), originalFileSHA256: try AppFiles.hashManifest(app, cancelled: cancelled))
    }
    private func inspectBinary(_ url: URL, root: URL, sdkRoot: String) throws -> BinaryRecord {
        let lipoOutput = try CommandRunner.run("/usr/bin/lipo", ["-archs", url.path]).1
        let words = lipoOutput.split(whereSeparator: \.isWhitespace).map(String.init)
        let arches = words.filter { $0 == "x86_64" || $0 == "arm64" || $0 == "arm64e" || $0 == "i386" }
        let load = try CommandRunner.run("/usr/bin/otool", ["-l", url.path]).1
        var deployments: [String] = []
        let lines = load.components(separatedBy: .newlines)
        for i in lines.indices {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line == "cmd LC_BUILD_VERSION" || line == "cmd LC_VERSION_MIN_MACOSX" {
                for next in lines.dropFirst(i+1).prefix(7) {
                    let s = next.trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("minos ") || s.hasPrefix("version ") { deployments.append(String(s.split(separator: " ").last ?? "")); break }
                }
            }
        }
        let dylibLines = try CommandRunner.run("/usr/bin/otool", ["-L", url.path]).1.components(separatedBy: .newlines).dropFirst()
        let deps = dylibLines.map { $0.trimmingCharacters(in: .whitespaces).components(separatedBy: " (").first ?? "" }.filter { !$0.isEmpty }
        let missing = deps.filter { dependency in
            guard dependency.hasPrefix("/") else { return false }
            if FileManager.default.fileExists(atPath: dependency) { return false }
            if sdkRoot.isEmpty { return true }
            let sdkPath = sdkRoot + dependency
            if FileManager.default.fileExists(atPath: sdkPath) { return false }
            let tbd = (sdkPath as NSString).deletingPathExtension + ".tbd"
            return !FileManager.default.fileExists(atPath: tbd)
        }
        let nm = (try? CommandRunner.run("/usr/bin/nm", ["-u", "-m", url.path]).1) ?? ""
        let nmLines = nm.components(separatedBy: .newlines)
        let trimmed = nmLines.map { $0.trimmingCharacters(in: .whitespaces) }
        let imports = Array(trimmed.filter { !$0.isEmpty }.prefix(3000))
        let weak = imports.filter { $0.localizedCaseInsensitiveContains("weak") }
        let objc = imports.filter { $0.contains("OBJC_CLASS_$_") || $0.contains("OBJC_SELECTOR_REFERENCES") }
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        return BinaryRecord(path: relative, architectures: arches, deploymentTargets: deployments, dependencies: deps, missingAbsoluteDependencies: missing, imports: imports, weakImports: weak, objcReferences: objc)
    }
}

private func major(_ version: String) -> Int { Int(version.split(separator: ".").first ?? "") ?? 0 }
private extension Int32 { var equalsZero: Bool { self == 0 } }
