import InputModel
import Testing
@testable import ClientInput

@Suite struct CursorPredictorTests {
    func ms(_ v: Int) -> Duration { .milliseconds(v) }

    @Test func localMovesShowAtOnce() {
        var p = CursorPredictor()
        p.localMove(to: Point2(0.3, 0.4), seq: 1, at: .zero)
        #expect(p.position == Point2(0.3, 0.4))
    }

    /// A report that trails the iPad's newer moves is ignored.
    @Test func olderReportsAreIgnored() {
        var p = CursorPredictor()
        p.localMove(to: Point2(0.5, 0.5), seq: 10, at: .zero)
        let changed1 = p.report(Point2(0.1, 0.1), lastInputSeq: 9, onDisplay: true, at: ms(500))
        #expect(!changed1)
        let changed2 = p.report(Point2(0.1, 0.1), lastInputSeq: 9, onDisplay: true, at: ms(700))
        #expect(!changed2)
        #expect(p.position == Point2(0.5, 0.5))
    }

    /// While the finger moves, its position wins even over a current report: the report is a few
    /// milliseconds behind and would drag the cursor back.
    @Test func movingIPadWins() {
        var p = CursorPredictor()
        for t in stride(from: 0, through: 300, by: 8) {
            p.localMove(to: Point2(Double(t) / 1000, 0.5), seq: UInt32(t + 1), at: ms(t))
            p.report(Point2(Double(t) / 1000 - 0.01, 0.5), lastInputSeq: UInt32(t + 1), onDisplay: true, at: ms(t + 2))
        }
        #expect(p.position == Point2(0.296, 0.5))  // the last local move, 296 ms
    }

    /// Someone moves the Mac's own mouse: once the iPad is still and the reports have disagreed
    /// for 100 ms, the iPad snaps to the Mac.
    @Test func snapsToTheMacAfterPersistentDisagreement() {
        var p = CursorPredictor()
        p.localMove(to: Point2(0.5, 0.5), seq: 5, at: .zero)
        let changed3 = p.report(Point2(0.8, 0.2), lastInputSeq: 5, onDisplay: true, at: ms(150))
        #expect(!changed3)
        let changed4 = p.report(Point2(0.8, 0.2), lastInputSeq: 5, onDisplay: true, at: ms(200))
        #expect(!changed4)
        let changed5 = p.report(Point2(0.8, 0.2), lastInputSeq: 5, onDisplay: true, at: ms(250))
        #expect(changed5)
        #expect(p.position == Point2(0.8, 0.2))
    }

    /// A single stray report that is gone by the next one does not move the cursor.
    @Test func agreementResetsTheTimer() {
        var p = CursorPredictor()
        p.localMove(to: Point2(0.5, 0.5), seq: 5, at: .zero)
        p.report(Point2(0.8, 0.2), lastInputSeq: 5, onDisplay: true, at: ms(150))
        p.report(Point2(0.5005, 0.5), lastInputSeq: 5, onDisplay: true, at: ms(200))
        let changed6 = p.report(Point2(0.8, 0.2), lastInputSeq: 5, onDisplay: true, at: ms(260))
        #expect(!changed6)
        #expect(p.position == Point2(0.5, 0.5))
    }

    /// Slow moves, one every 60 ms, each restart the wait: a disagreeing report never gets 100 ms.
    @Test func slowLocalMovesKeepRestartingTheWait() {
        var p = CursorPredictor()
        for step in 0..<10 {
            let t = step * 60
            p.localMove(to: Point2(0.5, 0.5), seq: UInt32(step + 1), at: ms(t))
            _ = p.report(Point2(0.9, 0.9), lastInputSeq: UInt32(step + 1), onDisplay: true, at: ms(t + 10))
            _ = p.report(Point2(0.9, 0.9), lastInputSeq: UInt32(step + 1), onDisplay: true, at: ms(t + 55))
        }
        #expect(p.position == Point2(0.5, 0.5))
    }

    @Test func firstReportPlacesTheCursor() {
        var p = CursorPredictor()
        let changed7 = p.report(Point2(0.25, 0.75), lastInputSeq: 0, onDisplay: true, at: .zero)
        #expect(changed7)
        #expect(p.position == Point2(0.25, 0.75))
    }

    @Test func otherDisplayHidesTheCursor() {
        var p = CursorPredictor()
        p.localMove(to: Point2(0.5, 0.5), seq: 1, at: .zero)
        let changed8 = p.report(Point2(0, 0), lastInputSeq: 1, onDisplay: false, at: ms(10))
        #expect(changed8)
        #expect(p.position == nil)
    }

    @Test func sequenceComparisonWraps() {
        #expect(CursorPredictor.isOlder(UInt32.max, than: 2))
        #expect(!CursorPredictor.isOlder(2, than: UInt32.max))
        #expect(!CursorPredictor.isOlder(7, than: 7))
    }
}
