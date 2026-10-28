// swift-tools-version:6.0
import PackageDescription

// Cosmos: a space-themed browser for Arc refugees.
//
// Layering (each layer only imports the ones above it):
//   CosmosCore      pure model + storage + search logic (Foundation, SQLite3). No UI, no WebKit.
//   CosmosImport    Arc / Chromium importers (reads Arc's Storable*.json, Chromium bookmarks + history)
//   CosmosBlocking  Adblock-Plus filter list -> Chromium declarativeNetRequest compiler
//   CosmosEngine    what the browser needs from a page engine (protocols only), so the engine can change
//   CosmosChromium  the engine: regular Chromium, downloaded and kept up to date, run headless under Cosmos's interface
//   CosmosKit       the browser itself: AppKit + SwiftUI, on CosmosEngine
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
        .target(name: "CosmosEngine", dependencies: ["CosmosCore"]),
        .target(
            name: "CosmosChromium",
            dependencies: ["CosmosCore", "CosmosEngine"],
            resources: [.copy("Resources/Bridge"), .process("Resources/engine-helper.js"), .process("Resources/extension-shim.js"), .process("Resources/page-bridge.js")]
        ),
        .target(
            name: "CosmosKit",
            dependencies: ["CosmosCore", "CosmosImport", "CosmosBlocking", "CosmosEngine", "CosmosChromium"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "Cosmos", dependencies: ["CosmosKit"]),
        .executableTarget(name: "CosmosCLI", dependencies: ["CosmosCore", "CosmosImport"]),
        .testTarget(name: "CosmosCoreTests", dependencies: ["CosmosCore"]),
        .testTarget(name: "CosmosImportTests", dependencies: ["CosmosCore", "CosmosImport"]),
        .testTarget(name: "CosmosBlockingTests", dependencies: ["CosmosCore", "CosmosBlocking"]),
        .testTarget(name: "CosmosChromiumTests", dependencies: ["CosmosChromium", "CosmosEngine", "CosmosCore"]),
        .testTarget(name: "CosmosKitTests", dependencies: ["CosmosKit", "CosmosCore", "CosmosEngine", "CosmosChromium", "CosmosBlocking"]),
    ],
    swiftLanguageModes: [.v5]
)
