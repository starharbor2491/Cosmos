import AppKit
import Testing
@testable import CosmosKit

/// A click on a sidebar row selects it and, on a pinned tab, a second click renames it. The row asks the application what
/// event it is handling to tell a second click from a first, and that is not always a mouse event: asking any other event
/// for its click count raises an Objective-C exception, which ended the app on the first click that reached the row.
@MainActor
@Suite struct SidebarClickTests {
    private func mouse(_ type: NSEvent.EventType, clicks: Int) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }

    @Test func aSecondClickIsOneWhoseCountIsTwo() {
        #expect(TabRow.isSecondClick(mouse(.leftMouseUp, clicks: 2)))
        #expect(!TabRow.isSecondClick(mouse(.leftMouseUp, clicks: 1)))
        #expect(!TabRow.isSecondClick(mouse(.leftMouseUp, clicks: 3)))
    }

    @Test(arguments: [NSEvent.EventType.appKitDefined, .systemDefined, .applicationDefined, .periodic, .mouseMoved, .keyDown])
    func anEventThatIsNotAClickIsNotAsked(type: NSEvent.EventType) throws {
        let event: NSEvent?
        switch type {
        case .mouseMoved: event = mouse(type, clicks: 0)
        case .keyDown: event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
        default: event = NSEvent.otherEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
        }
        #expect(!TabRow.isSecondClick(event))
    }

    @Test func noEventIsNoSecondClick() {
        #expect(!TabRow.isSecondClick(nil))
    }
}
