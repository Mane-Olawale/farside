import Testing
@testable import Telemetry

@Suite struct SampleSetTests {
    @Test func emptyHasNoSummary() {
        #expect(SampleSet().summary == nil)
    }

    @Test func nearestRankPercentiles() {
        var set = SampleSet()
        for value in (1...100).reversed() { set.add(Double(value)) }
        let summary = set.summary!
        #expect(summary.count == 100)
        #expect(summary.min == 1)
        #expect(summary.median == 50)
        #expect(summary.p95 == 95)
        #expect(summary.p99 == 99)
        #expect(summary.max == 100)
        #expect(summary.mean == 50.5)
    }

    @Test func singleValue() {
        var set = SampleSet()
        set.add(7)
        #expect(set.summary == SampleSummary(count: 1, min: 7, median: 7, p95: 7, p99: 7, max: 7, mean: 7))
    }
}
