import Testing
import Foundation
@testable import UpdateKit

/// The quit at the end of an install, against an app that defers its own.
///
/// `installUpdate` runs in a main-actor Task, and a main-actor job is a block on the
/// main dispatch queue. An app whose `applicationShouldTerminate` returns
/// `.terminateLater` and replies from another main-actor Task never got that reply when
/// `terminate` was called from inside the job: `terminate` spins the run loop waiting,
/// but the main queue is serial and won't start its next block until the current one
/// returns. Browsium 0.1.0 sat at "Relaunching…" until it was killed. These tests do
/// what `terminate` does — spin a nested run loop until a main-actor Task has run —
/// without quitting the test process.
@MainActor
@Suite("quitting after the hand-off", .serialized)
// Serialized: the deadlock test holds the main queue for its whole wait, which starves
// any main-actor test running beside it.
struct QuitTests {
    /// Spin the run loop, as `terminate` does while a reply is pending, until a
    /// main-actor Task has run or `seconds` pass. Returns whether it ran.
    private static func waitForMainActorTask(seconds: TimeInterval = 2) -> Bool {
        var ran = false
        Task { @MainActor in ran = true }
        let deadline = Date().addingTimeInterval(seconds)
        while !ran, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return ran
    }

    @Test("a quit asked for inside a main-actor job runs where the main queue can still drain")
    func quitOutsideTheMainQueue() async {
        let ran: Bool = await withCheckedContinuation { finished in
            AppUpdater.quitSoon { finished.resume(returning: Self.waitForMainActorTask()) }
        }
        #expect(ran)
    }

    @Test("the same wait run inside the main-actor job itself is the deadlock")
    func theDeadlockItself() async {
        // Holds the diagnosis in place: if this ever passes, the test above proves nothing.
        #expect(!Self.waitForMainActorTask(seconds: 0.3))
    }
}
