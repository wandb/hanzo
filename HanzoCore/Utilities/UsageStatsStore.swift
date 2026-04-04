import Foundation

struct UsageStatsSnapshot {
    let wordsAllTime: Int
    let dictatedSecondsAllTime: TimeInterval
    let autoSubmitsAllTime: Int

    var minutesDictatedAllTime: Double {
        dictatedSecondsAllTime / 60
    }

    var averageWordsPerMinute: Int {
        guard dictatedSecondsAllTime > 0 else { return 0 }
        let wordsPerMinute = Double(wordsAllTime) / minutesDictatedAllTime
        return Int(wordsPerMinute.rounded())
    }
}

enum UsageStatsStore {
    static func current(defaults: UserDefaults = .standard) -> UsageStatsSnapshot {
        return UsageStatsSnapshot(
            wordsAllTime: defaults.integer(forKey: Constants.usageStatsWordsAllTimeKey),
            dictatedSecondsAllTime: defaults.double(forKey: Constants.usageStatsDictatedSecondsAllTimeKey),
            autoSubmitsAllTime: defaults.integer(forKey: Constants.usageStatsAutoSubmitsAllTimeKey)
        )
    }

    static func recordSession(
        words: Int,
        dictatedSeconds: TimeInterval,
        autoSubmitCount: Int,
        defaults: UserDefaults = .standard
    ) {
        let safeWords = max(0, words)
        let safeDictatedSeconds = max(0, dictatedSeconds)
        let safeAutoSubmitCount = max(0, autoSubmitCount)

        let existingWords = defaults.integer(forKey: Constants.usageStatsWordsAllTimeKey)
        defaults.set(existingWords + safeWords, forKey: Constants.usageStatsWordsAllTimeKey)

        let existingDictatedSeconds = defaults.double(forKey: Constants.usageStatsDictatedSecondsAllTimeKey)
        defaults.set(
            existingDictatedSeconds + safeDictatedSeconds,
            forKey: Constants.usageStatsDictatedSecondsAllTimeKey
        )

        let existingAutoSubmits = defaults.integer(forKey: Constants.usageStatsAutoSubmitsAllTimeKey)
        defaults.set(existingAutoSubmits + safeAutoSubmitCount, forKey: Constants.usageStatsAutoSubmitsAllTimeKey)
    }
}
