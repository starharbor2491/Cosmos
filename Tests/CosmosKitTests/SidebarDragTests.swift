import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CosmosKit
@testable import CosmosCore

/// Just enough of a drag for a drop target to look at.
private final class StubDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@MainActor
@Suite struct SidebarDragTests {
    /// A tab carries its address as a link so other apps accept it. Over the page that would navigate the tab to it.
    @Test func aSidebarTabDroppedOnThePageIsRefused() throws {
        let rig = Rig()
        let id = try #require(rig.store.newTab(url: URL(string: "https://example.com/page"), in: rig.window))
        let runtime = try #require(rig.store.currentRuntime(in: rig.window))
        let board = NSPasteboard(name: NSPasteboard.Name("cosmos.test.\(UUID().uuidString)"))
        board.clearContents()
        board.setString("https://example.com/page", forType: .URL)
        let drag = StubDrag(pasteboard: board)

        _ = rig.store.beginDrag(id)
        #expect(runtime.webView.draggingEntered(drag) == [])
        #expect(runtime.webView.draggingUpdated(drag) == [])
        #expect(runtime.webView.prepareForDragOperation(drag) == false)
        #expect(runtime.webView.performDragOperation(drag) == false)
        rig.store.endDrag()
    }

    @Test func aDragCarryingThePrivateTypeIsRefusedEvenAfterTheStoreForgetsIt() throws {
        let rig = Rig()
        let runtime = try #require(rig.store.newTab(url: URL(string: "https://example.com/"), in: rig.window).flatMap { _ in rig.store.currentRuntime(in: rig.window) })
        let board = NSPasteboard(name: NSPasteboard.Name("cosmos.test.\(UUID().uuidString)"))
        board.clearContents()
        board.declareTypes([NSPasteboard.PasteboardType(SidebarDrop.itemType.identifier), .URL], owner: nil)
        let drag = StubDrag(pasteboard: board)
        #expect(runtime.webView.draggingEntered(drag) == [])
        #expect(runtime.webView.performDragOperation(drag) == false)
    }

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
        // Poll instead of sleeping a fixed time: a loaded machine delays the watcher's timer.
        for _ in 0..<120 where rig.store.draggingItemID != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(rig.store.draggingItemID == nil)
    }
}
