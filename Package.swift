// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Seqoma",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SeqomaCore", targets: ["SeqomaCore"]),
        .executable(name: "seqoma", targets: ["seqoma"])
    ],
    targets: [
        .target(name: "SeqomaCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "seqoma", dependencies: ["SeqomaCore"]),
        .testTarget(name: "SeqomaCoreTests", dependencies: ["SeqomaCore"])
    ]
)
