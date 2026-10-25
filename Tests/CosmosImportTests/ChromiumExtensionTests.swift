import Foundation
import Testing
@testable import CosmosCore
@testable import CosmosImport

@Suite struct ChromiumExtensionTests {
    let id = "abcdefghijklmnopabcdefghijklmnop"

    func makeProfile(_ extensions: [(id: String, version: String, manifest: String)], messages: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-ext-\(UUID().uuidString)", isDirectory: true)
        for e in extensions {
            let dir = root.appendingPathComponent("\(e.id)/\(e.version)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try e.manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            if !messages.isEmpty {
                let locales = dir.appendingPathComponent("_locales/en", isDirectory: true)
                try FileManager.default.createDirectory(at: locales, withIntermediateDirectories: true)
                let json = try JSONSerialization.data(withJSONObject: messages.mapValues { ["message": $0] })
                try json.write(to: locales.appendingPathComponent("messages.json"))
            }
        }
        return root
    }

    @Test func idsAndLinks() {
        #expect(ChromeWebStore.isExtensionID(id))
        #expect(!ChromeWebStore.isExtensionID("short"))
        #expect(!ChromeWebStore.isExtensionID(String(repeating: "z", count: 32)))
        #expect(ChromeWebStore.extensionID(from: "  \(id)  ") == id)
        #expect(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/some-name/\(id)?hl=en") == id)
        #expect(ChromeWebStore.extensionID(from: "https://chrome.google.com/webstore/detail/\(id)") == id)
        #expect(ChromeWebStore.extensionID(from: "https://example.com/detail/\(id)") == nil)
        #expect(ChromeWebStore.extensionID(from: "not a link") == nil)
        let url = ChromeWebStore.downloadURL(for: id)?.absoluteString
        #expect(url?.hasPrefix("https://clients2.google.com/service/update2/crx?") == true)
        #expect(url?.contains("id%3D\(id)") == true || url?.contains("id=\(id)") == true)
    }

    @Test func crxContainersUnwrapToTheirZip() throws {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4])
        func le(_ n: UInt32) -> [UInt8] { [UInt8(n & 255), UInt8(n >> 8 & 255), UInt8(n >> 16 & 255), UInt8(n >> 24 & 255)] }
        func crx(_ parts: [[UInt8]]) -> Data {
            var d = Data("Cr24".utf8)
            for p in parts { d.append(contentsOf: p) }
            return d
        }
        var crx3 = crx([le(3), le(5), [9, 9, 9, 9, 9]])
        crx3.append(zip)
        #expect(try ChromeWebStore.zipPayload(fromCRX: crx3) == zip)
        var crx2 = crx([le(2), le(3), le(2), [1, 1, 1], [2, 2]])
        crx2.append(zip)
        #expect(try ChromeWebStore.zipPayload(fromCRX: crx2) == zip)
        #expect(try ChromeWebStore.zipPayload(fromCRX: zip) == zip)
        #expect(throws: ChromeWebStore.CRXError.notAPackage) { try ChromeWebStore.zipPayload(fromCRX: Data("hello".utf8)) }
        #expect(throws: ChromeWebStore.CRXError.truncated) { try ChromeWebStore.zipPayload(fromCRX: crx([le(3), le(500)])) }
        #expect(throws: ChromeWebStore.CRXError.unsupportedVersion(9)) { try ChromeWebStore.zipPayload(fromCRX: crx([le(9), le(0)])) }
    }

    @Test func scanFindsTheNewestVersionAndSplitsPermissions() throws {
        let manifest = #"""
        {"manifest_version":3,"name":"Handy","version":"2.0","permissions":["storage","tabs","https://*.example.com/*"],
         "host_permissions":["<all_urls>"],"content_scripts":[{"matches":["https://news.example/*"],"js":["a.js"]}]}
        """#
        let root = try makeProfile([(id, "1.0_0", #"{"manifest_version":2,"name":"Old","version":"1.0"}"#), (id, "2.0_0", manifest)])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = ChromiumExtensionScanner.scan(extensionsDirectory: root, browser: .chrome, profileName: "Profile 1")
        let ext = try #require(found.first)
        #expect(found.count == 1)
        #expect(ext.name == "Handy")
        #expect(ext.version == "2.0")
        #expect(ext.manifestVersion == 3)
        #expect(ext.permissions == ["storage", "tabs"])
        #expect(Set(ext.hostAccess) == ["https://*.example.com/*", "<all_urls>", "https://news.example/*"])
        #expect(ext.source == "Google Chrome (Profile 1)")
        #expect(ext.directory.lastPathComponent == "2.0_0")
    }

    @Test func localisedNamesResolveAndThemesAreSkipped() throws {
        let other = "ponmlkjihgfedcbaponmlkjihgfedcba"
        let root = try makeProfile([
            (id, "1.0_0", #"{"manifest_version":3,"name":"__MSG_appName__","version":"1","default_locale":"en"}"#),
            (other, "1.0_0", #"{"manifest_version":3,"name":"A Theme","version":"1","theme":{}}"#),
            ("junk-folder", "1", #"{"manifest_version":3,"name":"Not an id","version":"1"}"#),
        ], messages: ["appName": "Pretty Name"])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = ChromiumExtensionScanner.scan(extensionsDirectory: root, browser: .arc, profileName: "Default")
        #expect(found.map(\.name) == ["Pretty Name"])
        #expect(found.first?.source == "Arc")
    }

    @Test func aMissingFolderIsNotAnError() {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        #expect(ChromiumExtensionScanner.scan(extensionsDirectory: nowhere, browser: .arc, profileName: "").isEmpty)
    }
}

@Suite struct ArcBoostNoteTests {
    @Test func aBoostImageCacheWithoutDefinitionsIsExplainedNotIgnored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cosmos-boost-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("BoostsImageCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let none = ImportNotes()
        #expect(ArcBoosts.load(directory: root, notes: none).isEmpty)
        #expect(none.warnings.isEmpty)                      // an empty cache says nothing

        try Data([1]).write(to: cache.appendingPathComponent("abc"))
        let some = ImportNotes()
        #expect(ArcBoosts.load(directory: root, notes: some).isEmpty)
        #expect(some.warnings.count == 1)
        #expect(some.warnings.first?.contains("Arc account") == true)
    }
}
