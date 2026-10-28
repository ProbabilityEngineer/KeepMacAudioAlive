import Foundation

@main
struct StreamHealthTests {
    static func main() {
        let configurations = [
            OutputConfiguration(uid: "anker", enabled: true),
            OutputConfiguration(uid: "usb-dac", enabled: false),
            OutputConfiguration(uid: "anker", enabled: false),
            OutputConfiguration(uid: nil, enabled: true),
        ]
        let unique = OutputConfiguration.unique(configurations)
        precondition(unique.count == 3)
        precondition(unique[0].enabled && !unique[1].enabled)
        precondition(unique[2].uid == nil)
        let encoded = try! JSONEncoder().encode(unique)
        precondition(try! JSONDecoder().decode([OutputConfiguration].self, from: encoded) == unique)
        precondition(OutputConfiguration.unique([]).isEmpty)
        var sleep = SleepState()
        sleep.willSleep()
        precondition(sleep.sleeping)
        precondition(sleep.explicitStart())
        precondition(!sleep.sleeping)
        precondition(!sleep.explicitStart(), "Repeated Start must preserve late-wake marker")
        precondition(!sleep.didWake(), "Late wake must not recreate manually resumed stream")
        sleep.willSleep()
        precondition(sleep.didWake(), "Next sleep cycle must recover normally")
        precondition(!sleep.sleeping)
        sleep.willSleep()
        _ = sleep.explicitStart()
        sleep.willSleep()
        precondition(sleep.didWake(), "A new sleep must invalidate the manual-resume marker")
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
        print("PASS: sleep/manual-start/late-wake policy, startup grace, callback stall, sustained health, replacement, wraparound, retry budget, atomic heartbeat")
    }
}
