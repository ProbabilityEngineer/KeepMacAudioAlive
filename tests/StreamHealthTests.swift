import Foundation

@main
struct StreamHealthTests {
    static func main() {
        var startup = StreamHealth(now: 0)
        precondition(startup.observe(count: 0, now: 4.9) == .waiting)
        precondition(startup.observe(count: 0, now: 5) == .stalled)
        precondition(!startup.isActive)

        var active = StreamHealth(now: 0)
        precondition(active.observe(count: 10, now: 1) == .active)
        precondition(active.observe(count: 10, now: 3.9) == .active)
        precondition(active.observe(count: 10, now: 4) == .stalled)
        precondition(!active.isActive)

        var stable = StreamHealth(now: 0)
        for tick in 1...31 {
            precondition(stable.observe(count: UInt64(tick), now: Double(tick)) == .active)
            precondition(stable.isStable(now: Double(tick)) == (tick >= 31))
        }
        // A replacement stream gets its own startup grace, not the old count/time.
        var replacement = StreamHealth(now: 100)
        precondition(replacement.observe(count: 0, now: 104) == .waiting)
        precondition(replacement.observe(count: 1, now: 104.5) == .active)
        var wrapped = StreamHealth(now: 0)
        precondition(wrapped.observe(count: UInt64.max, now: 1) == .active)
        precondition(wrapped.observe(count: 0, now: 2) == .active)

        var budget = RecoveryBudget()
        for expected in [0.5, 1, 2, 4, 8] {
            precondition(budget.nextDelay() == expected)
        }
        for _ in 0..<10 { precondition(budget.nextDelay() == nil) }
        budget.reset()
        precondition(budget.nextDelay() == 0.5)

        let heartbeat = KMAHeartbeatCreate()!
        precondition(KMAHeartbeatRead(heartbeat) == 0)
        for _ in 0..<1000 { KMAHeartbeatTick(heartbeat) }
        precondition(KMAHeartbeatRead(heartbeat) == 1000)
        KMAHeartbeatDestroy(heartbeat)
        print("PASS: startup grace, callback stall, sustained health, replacement, wraparound, retry budget, atomic heartbeat")
    }
}
