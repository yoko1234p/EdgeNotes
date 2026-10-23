// swift-tools-version: 6.0
import PackageDescription

// Keep the package name stable: compiled resource bundle names depend on it.
let package = Package(
    name: "DeskTools", defaultLocalization: "en", platforms: [.macOS(.v14)],
    products: [.executable(name: "EdgeNotes", targets: ["EdgeNotes"])],
    dependencies: [.package(path: "../Shared/LocalWorkflowKit"), .package(path: "../Shared/AppLocalizationKit")],
    targets: [
        .target(name: "DeskCore", dependencies: [.product(name: "LocalWorkflowKit", package: "LocalWorkflowKit"), .product(name: "AppLocalizationKit", package: "AppLocalizationKit")], resources: [.process("Resources/Localization")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "DeskUI", dependencies: ["DeskCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "NotesCore", dependencies: ["DeskCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "EdgeNotes", dependencies: ["NotesCore", "DeskUI"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DeskToolsTests", dependencies: ["NotesCore", "EdgeNotes", "DeskCore", .product(name: "LocalWorkflowKit", package: "LocalWorkflowKit")]),
    ]
)
