// swift-tools-version: 6.2
import PackageDescription

let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "LecternKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
        .library(name: "PDFSave", targets: ["PDFSave"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "ReaderKit", targets: ["ReaderKit"]),
        .library(name: "ReaderUI", targets: ["ReaderUI"]),
    ],
    targets: [
        // Pure Swift, no PDFKit, nonisolated.
        .target(name: "ReaderCore"),
        // Incremental writer and save verification, nonisolated.
        .target(name: "PDFSave"),
        .target(name: "Persistence", dependencies: ["ReaderCore"]),
        // PDFView layer: main-actor by default.
        .target(name: "ReaderKit", dependencies: ["ReaderCore"], swiftSettings: mainActorByDefault),
        .target(name: "ReaderUI", dependencies: ["ReaderCore", "ReaderKit"], swiftSettings: mainActorByDefault),
        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
        .testTarget(name: "PDFSaveTests", dependencies: ["PDFSave"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
    ]
)
