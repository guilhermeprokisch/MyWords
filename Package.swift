// swift-tools-version: 6.0
import PackageDescription

// SQLCipher is provided by Homebrew (`brew install sqlcipher`). On Apple
// Silicon it lives under /opt/homebrew. If you're on Intel or a custom prefix,
// adjust these two paths (or symlink).
let sqlcipherPrefix = "/opt/homebrew/opt/sqlcipher"
let sqlcipherInclude = "\(sqlcipherPrefix)/include/sqlcipher"
let sqlcipherLib = "\(sqlcipherPrefix)/lib"

// Flags every target that touches SQLCipher needs: header search path for the
// compiler, and library search path + link for the linker.
let sqlcipherSwift: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(["-Xcc", "-I\(sqlcipherInclude)"])
]
let sqlcipherLink: [LinkerSetting] = [
    .unsafeFlags(["-L\(sqlcipherLib)", "-lsqlcipher"])
]

let package = Package(
    name: "MyWords",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Binds Homebrew's SQLCipher (drop-in SQLite with encryption).
        .systemLibrary(name: "CSQLCipher", path: "Sources/CSQLCipher"),

        // Shared data layer (encrypted storage + keychain), used by the tools.
        .target(
            name: "MyWordsCore",
            dependencies: ["CSQLCipher"],
            path: "Sources/MyWordsCore",
            swiftSettings: sqlcipherSwift,
            linkerSettings: sqlcipherLink
        ),
        // The menu-bar logger app.
        .executableTarget(
            name: "MyWords",
            dependencies: ["MyWordsCore"],
            path: "Sources/MyWords",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: sqlcipherLink
        ),
        // CLI to decrypt and export the database for model training.
        .executableTarget(
            name: "mywords-export",
            dependencies: ["MyWordsCore"],
            path: "Sources/mywords-export",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: sqlcipherLink
        ),
        // OPTIONAL, not part of the core app: language & vocabulary statistics
        // (per-language detection, vocab size). Lives under examples/ because
        // it's a language-learning tool, not part of the generic capture core.
        // `build.sh` does not ship it; build it explicitly with
        // `swift build --product mywords-stats`. (It stays an in-repo target
        // because SPM can't consume MyWordsCore from a separate package — the
        // core uses unsafe linker flags, disallowed across package boundaries.)
        .executableTarget(
            name: "mywords-stats",
            dependencies: ["MyWordsCore"],
            path: "examples/mywords-stats",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: sqlcipherLink
        ),
        .testTarget(
            name: "MyWordsCoreTests",
            dependencies: ["MyWordsCore"],
            path: "Tests/MyWordsCoreTests",
            swiftSettings: sqlcipherSwift,
            linkerSettings: sqlcipherLink
        )
    ]
)
