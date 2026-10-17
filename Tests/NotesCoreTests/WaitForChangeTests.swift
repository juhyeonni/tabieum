import Testing
@testable import NotesCore

// AC1
@Test func returnsAtOnceWhenContentChangesButLengthDoesNot() async {
    var reads = ["가", "각"].makeIterator()
    var sleeps = 0
    let changed = await waitForChange(
        from: "가", attempts: 150, read: { reads.next() ?? "각" }, sleep: { sleeps += 1 })
    #expect(changed)
    #expect(sleeps == 1)
}

// AC2
@Test func givesUpAfterTheLimitWhenNothingChanges() async {
    var sleeps = 0
    let changed = await waitForChange(from: "abc", attempts: 5, read: { "abc" }, sleep: { sleeps += 1 })
    #expect(!changed)
    #expect(sleeps == 5)
}
