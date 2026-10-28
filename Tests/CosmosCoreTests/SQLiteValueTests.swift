import Foundation
import Testing
@testable import CosmosCore

/// Databases Cosmos reads come from other browsers: a stored number too big for an integer must read as no integer, not
/// stop the app.
@Suite struct SQLiteValueTests {
    @Test func aRealReadsAsAnIntegerOnlyWhenItFitsOne() {
        #expect(SQLiteDatabase.Value.double(3.7).int64 == 3)
        #expect(SQLiteDatabase.Value.double(-2.5).int64 == -2)
        #expect(SQLiteDatabase.Value.double(1e300).int64 == nil)
        #expect(SQLiteDatabase.Value.double(-1e300).int64 == nil)
        #expect(SQLiteDatabase.Value.double(.nan).int64 == nil)
        #expect(SQLiteDatabase.Value.int(42).int64 == 42)
    }
}
