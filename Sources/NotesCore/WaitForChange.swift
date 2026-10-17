/// Polls `read` until it returns something other than `first`; false if `attempts` polls pass without a change.
public func waitForChange<T: Equatable>(
    isolation: isolated (any Actor)? = #isolation,
    from first: T, attempts: Int, read: () -> T, sleep: () async -> Void
) async -> Bool {
    for _ in 0..<attempts {
        if read() != first { return true }
        await sleep()
    }
    return false
}
