import Foundation
import Testing
@testable import CosmosCore

@Suite struct ConnectionTests {
    @Test func onlyWebAddressesMakeAClaimAboutTheConnection() {
        #expect(URLInput.connection(of: URL(string: "https://example.com/a")) == .secure)
        #expect(URLInput.connection(of: URL(string: "HTTPS://example.com")) == .secure)
        #expect(URLInput.connection(of: URL(string: "http://example.com")) == .notSecure)
    }

    @Test(arguments: ["about:blank", "about:blank?x", "file:///Users/me/a.html", "data:text/html,hi", "cosmos://welcome", "view-source:https://example.com", "mailto:a@b.c", "blob:https://example.com/1"])
    func pagesThatAreNotOnTheWebSayNothing(address: String) {
        #expect(URLInput.connection(of: URL(string: address)) == .none, "\(address)")
    }

    @Test func noAddressSaysNothing() {
        #expect(URLInput.connection(of: nil) == .none)
    }
}
