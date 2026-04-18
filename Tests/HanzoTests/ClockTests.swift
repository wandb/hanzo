import Testing
import Foundation
@testable import HanzoCore

@Suite("Clock")
struct ClockTests {

    @Test("SystemClock.now advances with wall-clock time")
    func systemClockAdvances() async throws {
        let clock = SystemClock()
        let first = clock.now()
        try await Task.sleep(nanoseconds: 5_000_000)
        let second = clock.now()

        #expect(second > first)
    }

    @Test("TestClock starts at the provided date and advances deterministically")
    func clockAdvances() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start: start)

        #expect(clock.now() == start)

        clock.advance(by: 2.5)
        #expect(clock.now() == start.addingTimeInterval(2.5))

        clock.advance(by: 0.5)
        #expect(clock.now() == start.addingTimeInterval(3.0))
    }

    @Test("TestClock.set jumps to an absolute date")
    func clockSet() {
        let clock = TestClock(start: Date(timeIntervalSince1970: 0))
        let target = Date(timeIntervalSince1970: 1_800_000_000)

        clock.set(to: target)
        #expect(clock.now() == target)
    }
}
