import Testing
@testable import SidetoneCore

@Suite("Grid")
struct GridTests {
    @Test("canonical case")
    func canonicalCase() {
        #expect(Grid("fn30aq")?.value == "FN30aq")
        #expect(Grid("FN30AQ")?.value == "FN30aq")
        #expect(Grid("fn30")?.value == "FN30")
    }

    @Test("valid precisions")
    func precisions() {
        #expect(Grid("FN")?.precisionChars == 2)
        #expect(Grid("FN30")?.precisionChars == 4)
        #expect(Grid("FN30AQ")?.precisionChars == 6)
        #expect(Grid("FN30AQ55")?.precisionChars == 8)
    }

    @Test("rejects out-of-range fields and bad lengths")
    func rejections() {
        #expect(Grid("") == nil)
        #expect(Grid("FN3") == nil)            // length 3
        #expect(Grid("ZZ30") == nil)           // field Z > R
        #expect(Grid("FNAA") == nil)           // digits expected in positions 2,3
        #expect(Grid("FN30ZZ") == nil)         // subsquare Z > X
        #expect(Grid("FN30AQ55ZZ") == nil)     // length 10
    }
}
