import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

/// Arc's files are not ours to keep tidy: a profile from a different Arc version, a half-synced one or a damaged one
/// must be refused with an error or imported into something healthy, never crash the importer.
@Suite struct ImporterFuzzTests {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func randomValue(_ rng: inout SplitMix64) -> Any {
        switch Int.random(in: 0..<9, using: &rng) {
        case 0: return NSNull()
        case 1: return Int.random(in: -3...100, using: &rng)
        case 2: return Double.random(in: -1e12...1e12, using: &rng)
        case 3: return ""
        case 4: return "AAAAAAAA-0000-4000-8000-\(String(format: "%012X", Int.random(in: 0...40, using: &rng)))"
        case 5: return [Any]()
        case 6: return [String: Any]()
        case 7: return String(repeating: "x", count: 100_000)
        default: return Bool.random(using: &rng)
        }
    }

    /// Replaces, deletes or truncates one randomly chosen place somewhere in the tree.
    static func mutate(_ value: Any, _ rng: inout SplitMix64) -> Any {
        if var dict = value as? [String: Any], !dict.isEmpty {
            let key = dict.keys.sorted().randomElement(using: &rng)!
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: dict[key] = randomValue(&rng)
            case 1: dict[key] = nil
            default: dict[key] = mutate(dict[key]!, &rng)
            }
            return dict
        }
        if var array = value as? [Any], !array.isEmpty {
            let i = Int.random(in: 0..<array.count, using: &rng)
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: array[i] = randomValue(&rng)
            case 1: array.remove(at: i)
            case 2: array = Array(array.prefix(i))
            case 3: array.append(array[i])
            default: array[i] = mutate(array[i], &rng)
            }
            return array
        }
        return randomValue(&rng)
    }

    @Test(arguments: Array(1...60) as [UInt64]) func aMutatedSidebarImportsHealthyOrIsRefused(seed: UInt64) throws {
        var rng = SplitMix64(state: seed &* 0xA076_1D64_78BD_642F)
        var sidebar: Any = ArcFixture.sidebar()
        for _ in 0..<Int.random(in: 1...8, using: &rng) { sidebar = Self.mutate(sidebar, &rng) }
        let dir = try ArcFixture.makeProfile(sidebar: sidebar as? [String: Any] ?? [:])
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let result = try ArcImporter.importProfile(at: dir, now: Date(timeIntervalSince1970: 1_800_000_000))
            #expect(result.workspace.problems().isEmpty, "\(result.workspace.problems().prefix(3))")
            #expect(!result.workspace.spaces.isEmpty)
        } catch is ArcImportError {
            // A refusal is fine.
        }
    }

    @Test(arguments: Array(1...30) as [UInt64]) func damagedBytesInAnyFileDoNotCrash(seed: UInt64) throws {
        var rng = SplitMix64(state: seed &* 0xE703_7ED1_A0B4_28DB)
        let dir = try ArcFixture.makeProfile()
        defer { try? FileManager.default.removeItem(at: dir) }
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            var bytes = [UInt8](try Data(contentsOf: file))
            guard !bytes.isEmpty, Bool.random(using: &rng) else { continue }
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: bytes = Array(bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng)))
            case 1: for _ in 0..<Int.random(in: 1...20, using: &rng) { bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            default: bytes = Array(repeating: UInt8(ascii: "["), count: 100_000)
            }
            try Data(bytes).write(to: file)
        }
        do {
            let result = try ArcImporter.importProfile(at: dir, now: Date(timeIntervalSince1970: 1_800_000_000))
            #expect(result.workspace.problems().isEmpty)
        } catch is ArcImportError {
        }
    }
}
