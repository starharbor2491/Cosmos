import Foundation
import Testing
import CosmosCore
@testable import CosmosImport

@Suite struct BrowserTimestampTests {
    @Test func chromiumEpochShiftIsExactForWholeSeconds() {
        // 13_300_000_000 s since 1601 - 11_644_473_600 = 1_655_526_400 s since 1970
        #expect(BrowserTimestamp.chromium(microseconds: 13_300_000_000_000_000).timeIntervalSince1970 == 1_655_526_400)
        #expect(BrowserTimestamp.chromium(microseconds: 11_644_473_600_000_000) == Date(timeIntervalSince1970: 0))
        #expect(BrowserTimestamp.chromium(microseconds: 0).timeIntervalSince1970 == -11_644_473_600)
    }

    @Test func chromiumKeepsMicrosecondsAndRoundTrips() {
        let micros = BrowserEpoch.chromiumMicros(unix: 1_700_000_000, micros: 123_456)
        let d = BrowserTimestamp.chromium(microseconds: micros)
        #expect(abs(d.timeIntervalSince1970 - 1_700_000_000.123456) < 1e-6)
        #expect(BrowserTimestamp.chromiumMicroseconds(from: d) == micros)
    }

    @Test func firefoxAndSafariEpochs() {
        #expect(BrowserTimestamp.unix(microseconds: 1_700_000_000_000_000).timeIntervalSince1970 == 1_700_000_000)
        let f = BrowserTimestamp.unix(microseconds: BrowserEpoch.firefoxMicros(unix: 1_700_000_000, micros: 250_000))
        #expect(abs(f.timeIntervalSince1970 - 1_700_000_000.25) < 1e-6)
        #expect(BrowserTimestamp.unixMicroseconds(from: f) == 1_700_000_000_250_000)
        // Core Data: 0 is 2001-01-01T00:00:00Z
        #expect(BrowserTimestamp.coreData(seconds: 0).timeIntervalSince1970 == 978_307_200)
        #expect(BrowserTimestamp.coreData(seconds: 700_000_000.5).timeIntervalSince1970 == 1_678_307_200.5)
        #expect(BrowserTimestamp.coreData(seconds: .nan) == .distantPast)
    }

    @Test func implausibleDatesAreDroppedAndFutureDatesClamped() {
        let now = browserDate(1_750_000_000)
        #expect(BrowserTimestamp.sanitized(BrowserTimestamp.chromium(microseconds: 0), now: now) == nil)   // 1601: "never"
        #expect(BrowserTimestamp.sanitized(browserDate(315_532_800), now: now) == nil)                              // 1980
        #expect(BrowserTimestamp.sanitized(browserDate(1_700_000_000), now: now) == browserDate(1_700_000_000))
        #expect(BrowserTimestamp.sanitized(browserDate(4_000_000_000), now: now) == now)
        #expect(BrowserTimestamp.sanitized(nil, now: now) == nil)
        // Garbage in the database must not trap.
        #expect(BrowserTimestamp.chromium(microseconds: .min) == .distantPast)
        #expect(BrowserTimestamp.sanitized(BrowserTimestamp.chromium(microseconds: .max), now: now) == now)
    }
}

@Suite struct BrowserKindTests {
    @Test func defaultRootsMatchTheMacLayout() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let expected: [BrowserKind: String] = [
            .arc: "/Users/test/Library/Application Support/Arc/User Data",
            .chrome: "/Users/test/Library/Application Support/Google/Chrome",
            .brave: "/Users/test/Library/Application Support/BraveSoftware/Brave-Browser",
            .edge: "/Users/test/Library/Application Support/Microsoft Edge",
            .vivaldi: "/Users/test/Library/Application Support/Vivaldi",
            .opera: "/Users/test/Library/Application Support/com.operasoftware.Opera",
            .chromium: "/Users/test/Library/Application Support/Chromium",
            .firefox: "/Users/test/Library/Application Support/Firefox/Profiles",
            .safari: "/Users/test/Library/Safari",
        ]
        for kind in BrowserKind.allCases { #expect(kind.dataRoot(home: home).path == expected[kind]) }
        #expect(expected.count == BrowserKind.allCases.count)
    }

    @Test func familiesAndNames() {
        let chromium: [BrowserKind] = [.arc, .chrome, .brave, .edge, .vivaldi, .opera, .chromium]
        for k in chromium { #expect(k.family == .chromium) }
        #expect(BrowserKind.firefox.family == .firefox)
        #expect(BrowserKind.safari.family == .safari)
        #expect(BrowserKind.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(BrowserKind.chrome.displayName == "Google Chrome")
    }
}

@Suite struct BrowserErrorTests {
    @Test func permissionMessageSaysHowToFixIt() throws {
        let message = try #require(BrowserImportError.permissionDenied(path: "/Users/test/Library/Safari/History.db").errorDescription)
        #expect(message.contains("Full Disk Access"))
        #expect(message.contains("Privacy & Security"))
        #expect(message.contains("/Users/test/Library/Safari/History.db"))
    }

    @Test func mapsPosixAndCocoaErrors() {
        let eperm = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(BrowserFileAccess.map(eperm, path: "/x") == .permissionDenied(path: "/x"))
        #expect(BrowserFileAccess.map(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError), path: "/x") == .permissionDenied(path: "/x"))
        #expect(BrowserFileAccess.map(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError), path: "/x") == .fileNotFound(path: "/x"))
        #expect(BrowserFileAccess.map(NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError), path: "/x") != .permissionDenied(path: "/x"))
    }

    @Test func fileStatesDistinguishMissingDeniedAndReadable() throws {
        let tmp = try BrowserTempDir()
        defer { tmp.remove() }
        let file = tmp.sub("f.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(BrowserFileAccess.state(of: file) == .readable)
        #expect(BrowserFileAccess.state(of: tmp.sub("nope")) == .missing)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        #expect(BrowserFileAccess.state(of: file) == .denied)
        #expect(throws: BrowserImportError.permissionDenied(path: file.path)) { try BrowserFileAccess.readData(file) }
        #expect(BrowserFileAccess.directoryState(of: tmp.url) == .readable)
        #expect(BrowserFileAccess.directoryState(of: file) == .missing)
    }
}
