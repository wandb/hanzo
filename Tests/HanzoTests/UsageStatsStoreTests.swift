import Foundation
import Testing
@testable import HanzoCore

@Suite("UsageStatsStore")
struct UsageStatsStoreTests {
    private func withDefaults<T>(_ body: (UserDefaults) -> T) -> T {
        let suiteName = "UsageStatsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return body(defaults)
    }

    @Test("recordSession accumulates all-time counters")
    func recordSessionAccumulatesAllTimeCounters() {
        withDefaults { defaults in
            UsageStatsStore.recordSession(
                words: 40,
                dictatedSeconds: 90,
                autoSubmitCount: 1,
                defaults: defaults
            )
            UsageStatsStore.recordSession(
                words: 10,
                dictatedSeconds: 30,
                autoSubmitCount: 0,
                defaults: defaults
            )

            let snapshot = UsageStatsStore.current(defaults: defaults)

            #expect(snapshot.wordsAllTime == 50)
            #expect(abs(snapshot.dictatedSecondsAllTime - 120) < 0.001)
            #expect(snapshot.autoSubmitsAllTime == 1)
        }
    }

    @Test("average words per minute is derived from words and dictated minutes")
    func averageWordsPerMinuteIsDerived() {
        withDefaults { defaults in
            UsageStatsStore.recordSession(
                words: 120,
                dictatedSeconds: 60,
                autoSubmitCount: 0,
                defaults: defaults
            )

            let snapshot = UsageStatsStore.current(defaults: defaults)

            #expect(snapshot.averageWordsPerMinute == 120)
        }
    }

    @Test("current returns zero values when no stats were recorded")
    func currentReturnsZeroValuesByDefault() {
        withDefaults { defaults in
            let snapshot = UsageStatsStore.current(defaults: defaults)

            #expect(snapshot.wordsAllTime == 0)
            #expect(snapshot.dictatedSecondsAllTime == 0)
            #expect(snapshot.autoSubmitsAllTime == 0)
        }
    }
}
