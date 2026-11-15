import Foundation

public enum SeqomaError: Error, LocalizedError {
    case invalidApp(String), unsupported(String), command(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidApp(let s), .unsupported(let s), .command(let s): return s
        case .cancelled: return "Operation cancelled"
        }
    }
}

public struct CompatibilityProfile: Codable, Equatable {
    public let id: String
    public let sourceMajor: Int
    public let targetMajor: Int
    public let targetMinor: Int
    public let architecture: String
    public static let sequoiaToSonoma = CompatibilityProfile(id: "macos15-to-14-x86_64", sourceMajor: 15, targetMajor: 14, targetMinor: 0, architecture: "x86_64")
    public var targetVersion: String { "\(targetMajor).\(targetMinor)" }
}

public enum Classification: String, Codable {
    case metadataCandidate, recipePatchable, sourceRebuildable, unsupportedRuntime, insufficientEvidence
}
public enum CompatibilityStatus: String, Codable {
    case rebuildSuccessful, launchSuccessful, basicFunctionalityVerified, partiallyFunctional, failed, untested
}
public enum Strategy: String, Codable { case metadata, source, binaryRecipe }

public struct BinaryRecord: Codable {
    public let path: String
    public let architectures: [String]
    public let deploymentTargets: [String]
    public let dependencies: [String]
    public let missingAbsoluteDependencies: [String]
    public let imports: [String]
    public let weakImports: [String]
    public let objcReferences: [String]
}

public struct AnalysisReport: Codable {
    public let id: UUID
    public let date: Date
    public let sourcePath: String
    public let appName: String
    public let bundleID: String
    public let version: String
    public let declaredMinimum: String
    public let profile: CompatibilityProfile
    public let binaries: [BinaryRecord]
    public let originalSignatureValid: Bool
    public let signatureDetail: String
    public let entitlements: String
    public let hardenedRuntime: Bool
    public let classification: Classification
    public let confidence: Double
    public let issues: [String]
    public let limitations: [String]
    public let originalMainSHA256: String
    public let originalFileSHA256: [String: String]
}

public struct RebuildPlan: Codable {
    public let reportID: UUID
    public let strategy: Strategy
    public let recipeID: String
    public let modifications: [String]
    public let limitations: [String]
    public let validationProcedures: [String]
    public let rollbackBehavior: String
}

public struct RebuildResult: Codable {
    public let id: UUID
    public let date: Date
    public let originalPath: String
    public let outputPath: String
    public let strategy: Strategy
    public let recipeID: String
    public let originalMainSHA256: String
    public let rebuiltMainSHA256: String
    public let signatureValid: Bool
    public let status: CompatibilityStatus
    public let notes: [String]
}

public struct TestResult: Codable {
    public let date: Date
    public let appPath: String
    public let bundleValid: Bool
    public let architectureValid: Bool
    public let signatureValid: Bool
    public let missingDependencies: [String]
    public let launched: Bool
    public let remainedRunning: Bool
    public let exitCode: Int32?
    public let status: CompatibilityStatus
    public let diagnostic: String
}

public struct SourceRecipe: Codable {
    public let id: String
    public let bundleID: String
    public let version: String
    public let targetProfile: String
    public let executable: String
    public let requiredArchitectures: [String]
    public let sourceFiles: [String]
    public let compilationFlags: [String]
    public let modifications: [String]
    public let limitations: [String]
    public let validationProcedures: [String]
    public let rollbackBehavior: String
}

public enum JSONFile {
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
}
