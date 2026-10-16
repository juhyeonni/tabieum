import Testing
@testable import NotesCore

// AC6
@Test func emptyWindowHasNoPercentiles() {
    let window = LatencyWindow()
    #expect(window.median == nil)
    #expect(window.p90 == nil)
}

@Test func windowReportsMedianAndP90() {
    var window = LatencyWindow()
    for ms in (1...10).reversed() { window.record(Double(ms)) }
    #expect(window.median == 5)
    #expect(window.p90 == 9)
}

@Test func windowKeepsOnlyTheLast100() {
    var window = LatencyWindow()
    for _ in 0..<100 { window.record(1000) }
    for ms in 1...100 { window.record(Double(ms)) }
    #expect(window.median == 50)
    #expect(window.p90 == 90)
}
