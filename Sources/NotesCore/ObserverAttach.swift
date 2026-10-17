import Foundation

/// Whether to attach the accessibility observer again: a relaunched Notes has a new process id.
public func shouldAttachObserver(attachedPID: Int32?, runningPID: Int32?, lastRegistrationFailed: Bool) -> Bool {
    guard let runningPID else { return false }
    return attachedPID != runningPID || lastRegistrationFailed
}

public enum ObserverRetryPlan {
    public static let interval: TimeInterval = 0.5
    public static let maxTries = 20

    public static func shouldRetry(tries: Int, succeeded: Bool) -> Bool {
        !succeeded && tries < maxTries
    }
}
