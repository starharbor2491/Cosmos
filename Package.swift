// swift-tools-version:6.0
import Foundation
import PackageDescription

// Cosmos: a space-themed browser for Arc refugees.
//
// Layering (each layer only imports the ones above it):
//   CosmosCore      pure model + storage + search logic (Foundation, SQLite3). No UI, no WebKit.
//   CosmosImport    Arc / Chromium importers (reads Arc's Storable*.json, Chromium bookmarks + history)
//   CosmosBlocking  Adblock-Plus filter list -> Chromium declarativeNetRequest compiler
//   CosmosEngine    what the browser needs from a page engine (protocols only), so the engine can change
//   CosmosCEF       Chromium through CEF, in Cosmos's own process (Objective-C++; scripts/fetch-cef.sh puts CEF in Vendor/CEF)
//   CosmosChromium  the engine: Chromium's stable release through CosmosCEF, drawn in Cosmos's own windows
//   CosmosKit       the browser itself: AppKit + SwiftUI, on CosmosEngine
//   Cosmos          the app executable (a few lines; scripts/build-app.sh wraps it into Cosmos.app)
//   cosmos-cli      import / inspect / export from the terminal
//   CosmosHelper    the executable of Chromium's other processes (the helper apps in Cosmos.app/Contents/Frameworks)
//   CosmosEngineCheck  Chromium started as Cosmos.app starts it, for the tests that need a process of their own

/// CEF's headers and wrapper library (scripts/fetch-cef.sh), and the stable CEF API Cosmos is written against.
let cef = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Vendor/CEF").path
let cefCompile: [CXXSetting] = [.unsafeFlags(["-I", cef, "-DCEF_API_VERSION=15600", "-fno-rtti"])]
let cefLink: [LinkerSetting] = [.unsafeFlags(["-L", cef + "/build", "-lcef_dll_wrapper"])]

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
        .target(name: "CosmosCEF", cxxSettings: cefCompile, linkerSettings: cefLink + [.linkedFramework("AppKit")]),
        .executableTarget(name: "CosmosHelper", cxxSettings: cefCompile, linkerSettings: cefLink),
        .executableTarget(name: "CosmosEngineCheck", dependencies: ["CosmosCEF"]),
        .target(
            name: "CosmosChromium",
            dependencies: ["CosmosCore", "CosmosEngine", "CosmosCEF"],
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
        .target(name: "CosmosCEFTestSupport", dependencies: ["CosmosCEF"], path: "Tests/CosmosCEFTestSupport"),
        .testTarget(name: "CosmosKitTests", dependencies: ["CosmosKit", "CosmosCore", "CosmosEngine", "CosmosChromium", "CosmosBlocking",
                                                         "CosmosCEF", "CosmosCEFTestSupport"]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx20
)
