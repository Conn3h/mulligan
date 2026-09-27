import Testing
@testable import Mulligan

/// Inserts and erases take turns on one lane (§6.16).
@MainActor
@Suite(.serialized)
struct MutationLaneTests {
    private func pause(_ duration: Duration) async {
        do {
            try await Task.sleep(for: duration)
        } catch {
            Issue.record("pause cancelled")
        }
    }

    @Test func mutationsRunOneAtATimeInOrder() async {
        let log = LaneLog()
        let gate = Gate(open: false)
        let first = Task { @MainActor in
            await MutationLane.run { () -> (Int, Task<Void, Never>?) in
                log.entries.append("first start")
                await gate.pass()
                log.entries.append("first end")
                return (1, nil)
            }
        }
        await gate.waitForArrival()
        let second = Task { @MainActor in
            await MutationLane.run { () -> (Int, Task<Void, Never>?) in
                log.entries.append("second")
                return (2, nil)
            }
        }
        await pause(.milliseconds(20))
        #expect(log.entries == ["first start"])
        await gate.open()
        #expect(await first.value == 1)
        #expect(await second.value == 2)
        #expect(log.entries == ["first start", "first end", "second"])
    }

    @Test func theNextMutationWaitsForTheSettleButTheCallerDoesNot() async {
        let log = LaneLog()
        let settleGate = Gate(open: false)
        let value = await MutationLane.run { () -> (Int, Task<Void, Never>?) in
            log.entries.append("paste")
            let settle = Task { @MainActor in
                await settleGate.pass()
                log.entries.append("settled")
            }
            return (1, settle)
        }
        #expect(value == 1)
        let next = Task { @MainActor in
            await MutationLane.run { () -> (Int, Task<Void, Never>?) in
                log.entries.append("erase")
                return (2, nil)
            }
        }
        await settleGate.waitForArrival()
        await pause(.milliseconds(20))
        #expect(log.entries == ["paste"])
        await settleGate.open()
        #expect(await next.value == 2)
        #expect(log.entries == ["paste", "settled", "erase"])
    }
}

@MainActor
private final class LaneLog {
    var entries: [String] = []
}
