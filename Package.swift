// swift-tools-version:6.0
import PackageDescription

// Cosmos: a space-themed browser for Arc refugees.
//
// Layering (each layer only imports the ones above it):
//   CosmosCore      pure model + storage + search logic (Foundation, SQLite3). No UI, no WebKit.
//   CosmosImport    Arc / Chromium importers (reads Arc's Storable*.json, Chromium bookmarks + history)
//   CosmosBlocking  Adblock-Plus filter list -> WebKit content-rule-list compiler
//   CosmosKit       the browser itself: AppKit + SwiftUI + WKWebView
//   Cosmos          the app executable (a few lines; scripts/build-app.sh wraps it into Cosmos.app)
//   cosmos-cli      import / inspect / export from the terminal
let package = Package(
    name: "Cosmos",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Cosmos", targets: ["Cosmos"]),
        .executable(name: "cosmos-cli", targets: ["CosmosCLI"]),
    ],
    targets: [
        .target(
            name: "CosmosCore",
            resources: [.process("Resources")]
        ),
        .target(name: "CosmosImport", dependencies: ["CosmosCore"]),
        .target(name: "CosmosBlocking", dependencies: ["CosmosCore"], resources: [.process("Resources")]),
        .target(
            name: "CosmosKit",
            dependencies: ["CosmosCore", "CosmosImport", "CosmosBlocking"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "Cosmos", dependencies: ["CosmosKit"]),
        .executableTarget(name: "CosmosCLI", dependencies: ["CosmosCore", "CosmosImport"]),
        .testTarget(name: "CosmosCoreTests", dependencies: ["CosmosCore"]),
        .testTarget(name: "CosmosImportTests", dependencies: ["CosmosCore", "CosmosImport"]),
        .testTarget(name: "CosmosBlockingTests", dependencies: ["CosmosCore", "CosmosBlocking"]),
        .testTarget(name: "CosmosKitTests", dependencies: ["CosmosKit", "CosmosCore"]),
    ],
    swiftLanguageModes: [.v5]
)
