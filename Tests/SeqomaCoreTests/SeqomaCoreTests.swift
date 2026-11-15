import XCTest
@testable import SeqomaCore

final class SeqomaCoreTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SeqomaTests-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/Fixture"))
        let plist: [String: Any] = ["CFBundleExecutable": "Fixture", "CFBundleIdentifier": "dev.seqoma.fixture", "CFBundleName": "Fixture", "CFBundleShortVersionString": "1.0", "LSMinimumSystemVersion": "15.0", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    func testProfileAndJSON() throws {
        XCTAssertEqual(CompatibilityProfile.sequoiaToSonoma.targetVersion, "14.0")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("profile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONFile.write(CompatibilityProfile.sequoiaToSonoma, to: url)
        XCTAssertEqual(try JSONFile.read(CompatibilityProfile.self, from: url), .sequoiaToSonoma)
    }
    func testAnalyzeAndMetadataRebuild() throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let report = try Analyzer().analyze(app)
        XCTAssertEqual(report.declaredMinimum, "15.0")
        XCTAssertEqual(report.classification, .metadataCandidate)
        let plan = try Rebuilder().plan(report)
        let destination = app.deletingLastPathComponent().appendingPathComponent("output")
        XCTAssertThrowsError(try Rebuilder().rebuild(report, plan: plan, destination: destination, cancelled: { true }))
        let afterCancel = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        XCTAssertTrue(afterCancel.isEmpty, "Cancelled rebuild must clean its workspace")
        let result = try Rebuilder().rebuild(report, plan: plan, destination: destination)
        let output = URL(fileURLWithPath: result.outputPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertEqual(try AppFiles.plist(output)["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(try AppFiles.plist(app)["LSMinimumSystemVersion"] as? String, "15.0")
        XCTAssertTrue(result.signatureValid)
        let test = try ApplicationTester().test(output, launch: false)
        XCTAssertTrue(test.bundleValid)
        XCTAssertEqual(test.status, .untested)
    }
    func testCancellationAndDatabase() throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        XCTAssertThrowsError(try Analyzer().analyze(app, cancelled: { true }))
        let report = try Analyzer().analyze(app)
        let dbURL = app.deletingLastPathComponent().appendingPathComponent("test.sqlite3")
        let db = try CompatibilityDatabase(url: dbURL)
        try db.save(report)
        XCTAssertEqual(try db.list().count, 1)
    }

    func testSourceRecipeRejectsIncompatibleCompanion() throws {
        let app = try fixture()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let base = try Analyzer().analyze(app)
        let incompatible = BinaryRecord(path: "Contents/Frameworks/New.framework/New",
                                        architectures: ["x86_64"], deploymentTargets: ["15.0"],
                                        dependencies: [], missingAbsoluteDependencies: [],
                                        imports: [], weakImports: [], objcReferences: [])
        let report = AnalysisReport(id: base.id, date: base.date, sourcePath: base.sourcePath,
                                    appName: base.appName, bundleID: base.bundleID, version: base.version,
                                    declaredMinimum: base.declaredMinimum, profile: base.profile,
                                    binaries: base.binaries + [incompatible],
                                    originalSignatureValid: base.originalSignatureValid,
                                    signatureDetail: base.signatureDetail, entitlements: base.entitlements,
                                    hardenedRuntime: base.hardenedRuntime, classification: .unsupportedRuntime,
                                    confidence: base.confidence, issues: ["Companion needs macOS 15"],
                                    limitations: base.limitations, originalMainSHA256: base.originalMainSHA256,
                                    originalFileSHA256: base.originalFileSHA256)
        let recipe = SourceRecipe(id: "fixture-source", bundleID: base.bundleID,
                                  version: base.version, targetProfile: base.profile.id,
                                  executable: "Fixture", requiredArchitectures: ["x86_64"],
                                  sourceFiles: ["Fixture.swift"], replacementBinaries: nil, compilationFlags: [],
                                  modifications: [], limitations: [], validationProcedures: [],
                                  rollbackBehavior: "Delete generated copy")
        XCTAssertThrowsError(try Rebuilder().plan(report, sourceRecipe: recipe)) { error in
            XCTAssertTrue(error.localizedDescription.contains("incompatible components"))
        }
    }

    func testHashPinnedComponentRebuild() throws {
        let app = try fixture()
        let root = app.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = app.appendingPathComponent("Contents/MacOS/Helper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: helper)
        let base = try Analyzer().analyze(app)
        let oldHash = try AppFiles.sha256(helper)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let replacementFile = source.appendingPathComponent("Helper-Sonoma")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: replacementFile)
        let newHash = try AppFiles.sha256(replacementFile)
        XCTAssertNotEqual(oldHash, newHash)
        XCTAssertEqual(base.originalFileSHA256["Contents/MacOS/Helper"], oldHash)
        XCTAssertTrue(base.binaries.contains(where: { $0.path == "Contents/MacOS/Helper" }),
                      "Binary paths: \(base.binaries.map(\.path))")
        let binaries = base.binaries.map { binary in
            binary.path == "Contents/MacOS/Helper"
                ? BinaryRecord(path: binary.path, architectures: binary.architectures,
                               deploymentTargets: ["15.0"], dependencies: binary.dependencies,
                               missingAbsoluteDependencies: binary.missingAbsoluteDependencies,
                               imports: binary.imports, weakImports: binary.weakImports,
                               objcReferences: binary.objcReferences)
                : binary
        }
        let report = AnalysisReport(id: base.id, date: base.date, sourcePath: base.sourcePath,
                                    appName: base.appName, bundleID: base.bundleID, version: base.version,
                                    declaredMinimum: base.declaredMinimum, profile: base.profile,
                                    binaries: binaries, originalSignatureValid: base.originalSignatureValid,
                                    signatureDetail: base.signatureDetail, entitlements: base.entitlements,
                                    hardenedRuntime: base.hardenedRuntime, classification: .unsupportedRuntime,
                                    confidence: base.confidence, issues: ["Helper needs macOS 15"],
                                    limitations: base.limitations, originalMainSHA256: base.originalMainSHA256,
                                    originalFileSHA256: base.originalFileSHA256)
        let replacement = BinaryReplacement(bundlePath: "Contents/MacOS/Helper", sourcePath: "Helper-Sonoma",
                                            originalSHA256: oldHash, replacementSHA256: newHash)
        let recipe = SourceRecipe(id: "fixture-components", bundleID: base.bundleID,
                                  version: base.version, targetProfile: base.profile.id,
                                  executable: "Fixture", requiredArchitectures: ["x86_64"],
                                  sourceFiles: [], replacementBinaries: [replacement], compilationFlags: [],
                                  modifications: [], limitations: [], validationProcedures: [],
                                  rollbackBehavior: "Delete generated copy")
        let plan = try Rebuilder().plan(report, sourceRecipe: recipe)
        let result = try Rebuilder().rebuild(report, plan: plan,
                                            destination: root.appendingPathComponent("output"),
                                            sourceDirectory: source, recipe: recipe)
        let rebuiltHelper = URL(fileURLWithPath: result.outputPath).appendingPathComponent("Contents/MacOS/Helper")
        XCTAssertNotEqual(try AppFiles.sha256(rebuiltHelper), oldHash)
        XCTAssertEqual(try AppFiles.sha256(helper), oldHash)
        XCTAssertTrue(result.signatureValid)
    }
}
