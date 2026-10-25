import Testing
@testable import CosmosImport

@Suite struct ImportInfoTests {
    @Test func moduleLoads() {
        #expect(CosmosImportInfo.name == "CosmosImport")
    }
}
