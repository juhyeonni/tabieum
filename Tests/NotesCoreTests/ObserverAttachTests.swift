import Testing
@testable import NotesCore

// AC1
@Test func attachesWhenNothingIsHeld() {
    #expect(shouldAttachObserver(attachedPID: nil, runningPID: 10, lastRegistrationFailed: false))
}

@Test func attachesWhenProcessChanged() {
    #expect(shouldAttachObserver(attachedPID: 10, runningPID: 11, lastRegistrationFailed: false))
}

@Test func attachesAfterFailedRegistration() {
    #expect(shouldAttachObserver(attachedPID: 10, runningPID: 10, lastRegistrationFailed: true))
}

@Test func keepsSameRegisteredProcess() {
    #expect(!shouldAttachObserver(attachedPID: 10, runningPID: 10, lastRegistrationFailed: false))
}

@Test func doesNotAttachWhenNotesIsNotRunning() {
    #expect(!shouldAttachObserver(attachedPID: nil, runningPID: nil, lastRegistrationFailed: false))
}

// AC2
@Test func retryStopsAfterMaxTriesAndOnSuccess() {
    #expect(ObserverRetryPlan.shouldRetry(tries: 19, succeeded: false))
    #expect(!ObserverRetryPlan.shouldRetry(tries: 20, succeeded: false))
    #expect(!ObserverRetryPlan.shouldRetry(tries: 1, succeeded: true))
}
