import InputModel
import Testing
@testable import ClientInput

@Suite struct ClickCounterTests {
    @Test func quickClicksCountUpToThree() {
        var c = ClickCounter()
        let counts = (0..<4).map { c.down(1, at: Point2(10, 10), time: .milliseconds($0 * 200)) }
        #expect(counts == [1, 2, 3, 3])
    }

    @Test func slowOrMovedOrOtherButtonStartsAgain() {
        var c = ClickCounter()
        _ = c.down(1, at: Point2(10, 10), time: .zero)
        #expect(c.down(1, at: Point2(10, 10), time: .milliseconds(500)) == 1)
        #expect(c.down(1, at: Point2(30, 10), time: .milliseconds(600)) == 1)
        #expect(c.down(2, at: Point2(30, 10), time: .milliseconds(700)) == 1)
    }
}
