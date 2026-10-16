/// The last 100 timings, in milliseconds. Percentiles use the nearest-rank method.
public struct LatencyWindow: Sendable {
    public static let capacity = 100
    private var samples: [Double] = []

    public init() {}

    public mutating func record(_ milliseconds: Double) {
        samples.append(milliseconds)
        if samples.count > Self.capacity { samples.removeFirst() }
    }

    public var median: Double? { percentile(0.5) }
    public var p90: Double? { percentile(0.9) }

    private func percentile(_ p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let rank = Int((p * Double(samples.count)).rounded(.up))
        return samples.sorted()[max(rank, 1) - 1]
    }
}
