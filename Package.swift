// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotesExtension",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "App", targets: ["App"]),
    ],
    targets: [
        .target(name: "NotesCore"),
        .executableTarget(name: "App", dependencies: ["NotesCore"]),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"]),
    ]
)
