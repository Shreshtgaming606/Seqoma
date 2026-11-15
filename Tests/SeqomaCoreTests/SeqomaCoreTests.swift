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
}
