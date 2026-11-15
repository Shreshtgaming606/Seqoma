import Foundation
import SeqomaCore

func usage() -> Never {
    fputs("Usage: seqoma analyze APP [--json FILE] | plan APP [--recipe FILE] | rebuild APP DESTINATION [--source DIR --recipe FILE] | test APP [--launch] [--seconds N] | list\n", stderr)
    exit(2)
}
func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}
func show<T: Encodable>(_ object: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(object), as: UTF8.self))
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { usage() }
    let databaseURL = ProcessInfo.processInfo.environment["SEQOMA_DATABASE"].map { URL(fileURLWithPath: $0) } ?? CompatibilityDatabase.defaultURL
    let db = try CompatibilityDatabase(url: databaseURL)
    let analyzer = Analyzer()
    let rebuilder = Rebuilder()
    switch command {
    case "analyze":
        guard args.count >= 2 else { usage() }
        let report = try analyzer.analyze(URL(fileURLWithPath: args[1]))
        try db.save(report)
        if let path = option("--json", in: args) { try JSONFile.write(report, to: URL(fileURLWithPath: path)) }
        try show(report)
    case "plan":
        guard args.count >= 2 else { usage() }
        let report = try analyzer.analyze(URL(fileURLWithPath: args[1]))
        let recipe = try option("--recipe", in: args).map { try JSONFile.read(SourceRecipe.self, from: URL(fileURLWithPath: $0)) }
        try show(rebuilder.plan(report, sourceRecipe: recipe))
    case "rebuild":
        guard args.count >= 3 else { usage() }
        let app = URL(fileURLWithPath: args[1])
        let report = try analyzer.analyze(app)
        try db.save(report)
        let recipe = try option("--recipe", in: args).map { try JSONFile.read(SourceRecipe.self, from: URL(fileURLWithPath: $0)) }
        let plan = try rebuilder.plan(report, sourceRecipe: recipe)
        let source = option("--source", in: args).map { URL(fileURLWithPath: $0) }
        let result = try rebuilder.rebuild(report, plan: plan, destination: URL(fileURLWithPath: args[2]), sourceDirectory: source, recipe: recipe)
        try db.save(result, report: report)
        try show(result)
    case "test":
        guard args.count >= 2 else { usage() }
        let app = URL(fileURLWithPath: args[1])
        let report = try analyzer.analyze(app)
        let result = try ApplicationTester().test(app, launch: args.contains("--launch"), observationSeconds: Double(option("--seconds", in: args) ?? "5") ?? 5)
        try db.save(result, report: report)
        try show(result)
    case "list": try show(db.list())
    default: usage()
    }
} catch {
    fputs("seqoma: \(error.localizedDescription)\n", stderr)
    exit(1)
}
