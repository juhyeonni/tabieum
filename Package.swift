// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotesExtension",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "App", targets: ["App"]),
        .executable(name: "notes-export", targets: ["notes-export"]),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.5"),
    ],
    targets: [
        .target(name: "NotesCore", dependencies: [.product(name: "Tokenizers", package: "swift-transformers")]),
        .target(name: "NotesAI", dependencies: ["NotesCore"]),
        .executableTarget(name: "App", dependencies: ["NotesCore", "NotesAI"]),
        .executableTarget(name: "notes-export", dependencies: ["NotesCore"], path: "Sources/NotesExport"),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"], exclude: ["Fixtures"]),
        .testTarget(name: "NotesAITests", dependencies: ["NotesAI", "NotesCore"]),
    ]
)
