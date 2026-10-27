import Foundation

// Compile with the app source and -D LIFECYCLE_TESTS. Does not instantiate the
// audio engine, open a device, or terminate an application.
@main
struct TerminationTests {
    @MainActor
    static func main() async throws {
        let normal = TerminationCoordinator()
        var completions: [Bool] = []
        var normalDeadline: DispatchWorkItem?
        normal.begin(cleanup: { done in done() },
                     schedule: { normalDeadline = $0 },
                     reply: { completions.append($0) })
        try await Task.sleep(for: .milliseconds(20))
        precondition(completions == [false], "Graceful completion must reply once")
        precondition(normalDeadline?.isCancelled == true, "Completion must cancel timeout")
        normalDeadline?.perform()
        precondition(completions == [false], "Cancelled deadline must not reply again")

        let blocked = TerminationCoordinator()
        var lateCompletion: (@Sendable () -> Void)?
        var blockedDeadline: DispatchWorkItem?
        var timeouts: [Bool] = []
        var cleanupCalls = 0
        blocked.begin(cleanup: { done in
            cleanupCalls += 1
            lateCompletion = done
        }, schedule: { blockedDeadline = $0 }, reply: { timeouts.append($0) })
        blocked.begin(cleanup: { _ in cleanupCalls += 1 },
                      schedule: { _ in preconditionFailure("Duplicate deadline") },
                      reply: { _ in preconditionFailure("Duplicate reply") })
        precondition(cleanupCalls == 1, "Repeated Quit must not duplicate cleanup")
        precondition(timeouts.isEmpty, "Blocked cleanup must return without blocking main thread")
        blockedDeadline?.perform()
        precondition(timeouts == [true], "Deadline must permit exit on blocked cleanup")
        lateCompletion?()
        try await Task.sleep(for: .milliseconds(20))
        precondition(timeouts == [true], "Late completion must not reply twice")
        print("PASS: graceful cleanup, deadline cancellation, repeated Quit, blocked cleanup, late completion")
    }
}
