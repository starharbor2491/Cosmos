import Testing
@testable import CosmosBlocking

@Suite struct BlockingInfoTests {
    @Test func moduleLoads() {
        #expect(CosmosBlockingInfo.name == "CosmosBlocking")
    }
}
