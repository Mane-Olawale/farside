import os

/// Distribution summary for one measured quantity.
public struct SampleSummary: Sendable, Codable, Equatable {
    public var count: Int
    public var min: Double
    public var median: Double
    public var p95: Double
    public var p99: Double
    public var max: Double
    public var mean: Double
}

/// Collects raw samples and summarizes them with nearest-rank percentiles.
public struct SampleSet: Sendable {
    public private(set) var values: [Double] = []

    public init() {}

    public mutating func add(_ value: Double) { values.append(value) }
    public mutating func add(contentsOf other: SampleSet) { values.append(contentsOf: other.values) }

    public var summary: SampleSummary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func rank(_ p: Double) -> Double {
            let index = Int((p * Double(sorted.count)).rounded(.up)) - 1
            return sorted[Swift.max(0, Swift.min(sorted.count - 1, index))]
        }
        return SampleSummary(
            count: sorted.count,
            min: sorted[0],
            median: rank(0.5),
            p95: rank(0.95),
            p99: rank(0.99),
            max: sorted[sorted.count - 1],
            mean: sorted.reduce(0, +) / Double(sorted.count)
        )
    }
}

/// Signpost intervals for the media pipeline, visible in Instruments (plan section 16).
public enum Signposts {
    public static let pipeline = OSSignposter(subsystem: "app.farside", category: "pipeline")
}
