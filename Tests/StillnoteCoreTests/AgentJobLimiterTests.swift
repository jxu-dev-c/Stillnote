import Foundation
import Testing

@testable import StillnoteCore

/// Counts how many jobs overlap, and the order they started in.
private actor Tracker {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var started: [Int] = []

    func begin(_ job: Int) {
        active += 1
        peak = max(peak, active)
        started.append(job)
    }

    func end() { active -= 1 }
}

/// A gate the test opens once, so jobs can be held mid-run.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private func until(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for a condition.")
}

@Suite struct AgentJobLimiterTests {
    @Test func runsUpToTheLimitAtOnceAndStartsWaitersInArrivalOrder() async throws {
        let limiter = AgentJobLimiter(limit: 2)
        let tracker = Tracker()
        let gate = Gate()
        var tasks: [Task<Void, Never>] = []
        for job in 0..<5 {
            tasks.append(Task {
                await limiter.run {
                    await tracker.begin(job)
                    await gate.wait()
                    await tracker.end()
                }
            })
            // Each job reaches the limiter before the next is created, so arrival order is fixed.
            try await until { await limiter.running + limiter.waiting == job + 1 }
        }
        #expect(await limiter.running == 2)
        #expect(await limiter.waiting == 3)
        await gate.release()
        for task in tasks { await task.value }
        #expect(await tracker.peak == 2)
        #expect(await tracker.started == [0, 1, 2, 3, 4])
        #expect(await limiter.running == 0)
    }

    @Test func raisingTheLimitStartsWaitingJobsAtOnce() async throws {
        let limiter = AgentJobLimiter(limit: 1)
        let gate = Gate()
        let tasks = (0..<3).map { _ in Task { await limiter.run { await gate.wait() } } }
        try await until { await limiter.waiting == 2 }
        #expect(await limiter.running == 1)
        await limiter.setLimit(3)
        #expect(await limiter.running == 3)
        #expect(await limiter.waiting == 0)
        await gate.release()
        for task in tasks { await task.value }
    }

    @Test func aThrowingJobFreesItsSlot() async throws {
        struct Failure: Error {}
        let limiter = AgentJobLimiter(limit: 1)
        await #expect(throws: Failure.self) { try await limiter.run { throw Failure() } }
        #expect(await limiter.running == 0)
        #expect(await limiter.run { 7 } == 7)
    }

    @Test func limitIsClamped() async {
        #expect(await AgentJobLimiter(limit: 0).limit == 1)
        #expect(await AgentJobLimiter(limit: 99).limit == AgentJobLimiter.limits.upperBound)
        #expect(await AgentJobLimiter().limit == 3)
    }

    @Test func summaryConcurrencyDefaultsToThreeAndRoundTrips() throws {
        #expect(SummarySettings().concurrency == 3)
        #expect(SummarySettings(concurrency: 0).concurrency == 1)

        let stored = Data(#"{"provider":"codex","model":"m","reasoning_effort":"low"}"#.utf8)
        #expect(try JSONDecoder().decode(SummarySettings.self, from: stored).concurrency == 3)
        let encoded = try JSONEncoder().encode(SummarySettings(concurrency: 5))
        #expect(try JSONDecoder().decode(SummarySettings.self, from: encoded).concurrency == 5)

        // Settings saved before the option existed load with the default and aren't rewritten for it.
        let old: [String: Any] = ["summary": [
            "provider": "codex", "model": "m", "reasoning_effort": "low", "agent_prompt": "Be brief.",
        ]]
        #expect(AppSettings.migrating(from: old).settings.summary.concurrency == 3)
        var withValue = old
        withValue["summary"] = (old["summary"] as! [String: Any]).merging(["concurrency": 5]) { $1 }
        let migrated = AppSettings.migrating(from: withValue)
        #expect(migrated.settings.summary.concurrency == 5)
        // A known key isn't a reason to rewrite: the record is as "changed" as one without it.
        #expect(migrated.changed == AppSettings.migrating(from: old).changed)
        var clamped = withValue
        clamped["summary"] = (old["summary"] as! [String: Any]).merging(["concurrency": 50]) { $1 }
        let fixed = AppSettings.migrating(from: clamped)
        #expect(fixed.settings.summary.concurrency == AgentJobLimiter.limits.upperBound)
        #expect(fixed.changed)
    }
}
