import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CosmosKit
@testable import CosmosCore

@MainActor
@Suite struct SidebarDragTests {
    private func data(_ provider: NSItemProvider, _ type: String) async -> Data? {
        await withCheckedContinuation { c in
            provider.loadDataRepresentation(forTypeIdentifier: type) { d, _ in c.resume(returning: d) }
        }
    }

    @Test func aDraggedTabCarriesItsAddressAndNoInternalText() async throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: URL(string: "https://example.com/page"), in: rig.window))
        let provider = rig.store.beginDrag(id)
        defer { rig.store.endDrag() }

        #expect(provider.registeredTypeIdentifiers.contains(SidebarDrop.itemType.identifier))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.url.identifier))
        // Whatever another app or a text field takes from the drag, it is never Cosmos's bookkeeping.
        for type in provider.registeredTypeIdentifiers where type != SidebarDrop.itemType.identifier {
            if let d = await data(provider, type), let text = String(data: d, encoding: .utf8) {
                #expect(!text.contains("cosmos"), "\(type) leaked: \(text)")
                #expect(!text.contains(id.uuidString), "\(type) leaked the item id")
            }
        }
        let own = try #require(await data(provider, SidebarDrop.itemType.identifier))
        #expect(String(data: own, encoding: .utf8) == id.uuidString)
    }

    @Test func aDraggedFolderOffersNothingToOtherApps() async throws {
        let rig = Rig()
        rig.store.newFolder(in: rig.window)
        let folder = try #require(rig.store.workspace.pinned(in: rig.space).first { $0.isFolder })
        let provider = rig.store.beginDrag(folder.id)
        defer { rig.store.endDrag() }
        #expect(provider.registeredTypeIdentifiers == [SidebarDrop.itemType.identifier])
    }

    @Test func aTabWithoutAWebAddressOffersNoLink() throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: nil, in: rig.window))
        let provider = rig.store.beginDrag(id)
        defer { rig.store.endDrag() }
        #expect(!provider.hasItemConformingToTypeIdentifier(UTType.url.identifier))
    }

    @Test func aDragThatNeverEndsClearsItself() async throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: URL(string: "https://example.com"), in: rig.window))
        _ = rig.store.beginDrag(id)
        #expect(rig.store.draggingItemID == id)
        // No button is down in a test run, so the watcher gives up after its grace period (a cancelled drag never reports back).
        try await Task.sleep(for: .milliseconds(1200))
        #expect(rig.store.draggingItemID == nil)
    }
}
