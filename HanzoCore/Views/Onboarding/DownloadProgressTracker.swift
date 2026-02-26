import Foundation

struct ModelFileDownloadItem: Sendable {
    let preset: LocalASRModelPreset
    let fileName: String
    let remoteURL: URL
    let localURL: URL
    let expectedBytes: Int64
    let workUnits: Int64
}

struct FileDownloadPlan: Sendable {
    let preset: LocalASRModelPreset
    let item: ModelFileDownloadItem
    let isComplete: Bool
    let workUnits: Int64
}

struct DownloadPlan: Sendable {
    let itemsByPreset: [LocalASRModelPreset: [ModelFileDownloadItem]]
    let totalWorkUnits: Int64
    let completedWorkUnits: Int64
    let completedPresetCount: Int
}

struct DownloadProgressSnapshot: Sendable {
    let fraction: Double
    let completedPresetCount: Int
}

actor DownloadProgressTracker {
    private let totalWorkUnits: Int64
    private var completedWorkUnits: Int64
    private var completedPresetCount: Int

    init(
        totalWorkUnits: Int64,
        completedWorkUnits: Int64,
        completedPresetCount: Int
    ) {
        self.totalWorkUnits = max(totalWorkUnits, 1)
        self.completedWorkUnits = completedWorkUnits
        self.completedPresetCount = completedPresetCount
    }

    func snapshot() -> DownloadProgressSnapshot {
        DownloadProgressSnapshot(
            fraction: min(1.0, Double(completedWorkUnits) / Double(totalWorkUnits)),
            completedPresetCount: completedPresetCount
        )
    }

    func markDownloaded(units: Int64) -> DownloadProgressSnapshot {
        completedWorkUnits += max(units, 0)
        return snapshot()
    }

    func markPresetCompleted() -> DownloadProgressSnapshot {
        completedPresetCount += 1
        return snapshot()
    }
}
