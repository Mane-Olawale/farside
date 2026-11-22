import Testing
@testable import Telemetry

@Suite struct FrameCodeTests {
    @Test(arguments: [0, 1, 2, 3, 59, 60, 119, 120, 4_095, 1_000_000, FrameCode.modulus - 1])
    func roundTrips(_ counter: UInt32) {
        let cells = FrameCode.encode(counter)
        #expect(cells.count == FrameCode.cellCount)
        #expect(FrameCode.decode(cells) == counter)
    }

    @Test func wrapsAtModulus() {
        #expect(FrameCode.decode(FrameCode.encode(FrameCode.modulus)) == 0)
        #expect(FrameCode.decode(FrameCode.encode(FrameCode.modulus + 5)) == 5)
    }

    @Test func neighboursDifferInOneDataCell() {
        for counter in UInt32(0)..<2_000 {
            let a = FrameCode.encode(counter)
            let b = FrameCode.encode(counter + 1)
            let dataDiffs = (2..<(2 + FrameCode.dataBits)).filter { a[$0] != b[$0] }
            #expect(dataDiffs.count == 1)
        }
    }

    @Test func rejectsFlippedDataCell() {
        var cells = FrameCode.encode(12_345)
        cells[10].toggle()
        #expect(FrameCode.decode(cells) == nil)
    }

    @Test func rejectsBrokenGuards() {
        var cells = FrameCode.encode(7)
        cells[0] = false
        #expect(FrameCode.decode(cells) == nil)
        #expect(FrameCode.decode(Array(cells.dropLast())) == nil)
    }
}
