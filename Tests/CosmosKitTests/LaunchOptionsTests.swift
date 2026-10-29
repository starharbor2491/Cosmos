import Foundation
import Testing
@testable import CosmosKit

@Suite struct LaunchOptionsTests {
    /// A demo makes up its keys only in a data folder that is its own: pointed at one with someone's data in it, it would
    /// lock away the passwords there and garble the cookies.
    @Test func aDemoMakesUpItsKeysOnlyInAFolderOfItsOwn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-options-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(LaunchOptions.parse(["Cosmos", "--demo"], env: [:]).usesThrowawayKeys)
        #expect(LaunchOptions.parse(["Cosmos", "--demo", "--data-dir", folder.path], env: [:]).usesThrowawayKeys, "a folder not made yet")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(LaunchOptions.parse(["Cosmos", "--demo", "--data-dir", folder.path], env: [:]).usesThrowawayKeys, "an empty one")
        try Data().write(to: folder.appendingPathComponent("Passwords.vault"))
        #expect(!LaunchOptions.parse(["Cosmos", "--demo", "--data-dir", folder.path], env: [:]).usesThrowawayKeys)
        #expect(!LaunchOptions.parse(["Cosmos", "--data-dir", folder.path], env: [:]).usesThrowawayKeys)
        #expect(!LaunchOptions.parse(["Cosmos"], env: [:]).usesThrowawayKeys)
    }
}
