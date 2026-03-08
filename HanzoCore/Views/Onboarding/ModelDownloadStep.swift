import SwiftUI

struct ModelDownloadStep: View {
    var onDownloaded: () -> Void

    @State private var progress: Double = 0
    @State private var statusText: String = "Preparing downloads..."
    @State private var errorText: String?
    @State private var downloadTask: Task<Void, Never>?
    @State private var completedModelCount: Int = 0
    @State private var totalModelCount: Int = LocalASRModelPreset.allCases.count

    private static let requiredModelFiles: [String] = [
        "config.json",
        "model.safetensors",
        "preprocessor_config.json",
        "tokenizer_config.json",
        "vocab.json",
        "merges.txt",
        "chat_template.json",
        "generation_config.json",
    ]
    private static let requiredModelFileSet = Set(requiredModelFiles)

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.primary)

            Text("Downloading local model")
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text("Hanzo is setting up all on-device ASR models. This may take a while depending on your connection.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)

                Text("\(completedModelCount)/\(max(totalModelCount, 1)) models downloaded")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(errorText ?? statusText)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(errorText == nil ? .secondary : .red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if errorText != nil {
                Button("Retry download") {
                    startFlow()
                }
                .buttonStyle(HUDButtonStyle())
            }
        }
        .onAppear {
            startFlow()
        }
        .onDisappear {
            downloadTask?.cancel()
            downloadTask = nil
        }
    }

    private func startFlow() {
        downloadTask?.cancel()
        errorText = nil
        progress = max(progress, 0.01)
        statusText = "Preparing downloads..."
        completedModelCount = 0
        totalModelCount = LocalASRModelPreset.allCases.count

        downloadTask = Task {
            do {
                try await downloadAllModelPresets()
            } catch {
                if error is CancellationError {
                    return
                }
                await MainActor.run {
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func downloadAllModelPresets() async throws {
        let presets = LocalASRModelPreset.allCases
        let modelsRoot = modelsRootDirectoryURL()

        // If all models are already downloaded, skip immediately
        let missing = missingModelPresets(from: presets, modelsRoot: modelsRoot)
        if missing.isEmpty {
            await MainActor.run { onDownloaded() }
            return
        }

        await MainActor.run {
            totalModelCount = presets.count
            statusText = "Checking downloaded model files..."
        }

        let plan = try await Self.buildDownloadPlan(
            for: presets,
            requiredFiles: Self.requiredModelFiles,
            modelsRoot: modelsRoot
        )

        try await executeDownloadPlan(
            plan,
            totalPresetCount: presets.count
        )

        try await verifyAllModelFilesDownloaded(
            presets: presets,
            modelsRoot: modelsRoot
        )

        await MainActor.run {
            progress = 1.0
            completedModelCount = presets.count
            statusText = "All local models downloaded"
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        await MainActor.run {
            onDownloaded()
        }
    }

    private func executeDownloadPlan(
        _ plan: DownloadPlan,
        totalPresetCount: Int
    ) async throws {
        let tracker = DownloadProgressTracker(
            totalWorkUnits: max(plan.totalWorkUnits, 1),
            completedWorkUnits: plan.completedWorkUnits,
            completedPresetCount: plan.completedPresetCount
        )

        let initialSnapshot = await tracker.snapshot()
        await MainActor.run {
            completedModelCount = initialSnapshot.completedPresetCount
            progress = max(progress, min(initialSnapshot.fraction, 0.99))
            if initialSnapshot.completedPresetCount == totalPresetCount {
                statusText = "Downloads complete. Verifying files..."
            } else {
                statusText = "Downloading local models in sequence... (\(initialSnapshot.completedPresetCount)/\(totalPresetCount) downloaded)"
            }
        }

        for preset in LocalASRModelPreset.allCases {
            try Task.checkCancellation()

            let items = plan.itemsByPreset[preset] ?? []
            if items.isEmpty {
                let presetSnapshot = await tracker.markPresetCompleted()
                await MainActor.run {
                    completedModelCount = presetSnapshot.completedPresetCount
                    progress = max(progress, min(presetSnapshot.fraction, 0.99))
                    if presetSnapshot.completedPresetCount == totalPresetCount {
                        statusText = "Downloads complete. Verifying files..."
                    } else {
                        statusText = "Downloaded \(preset.displayName) (\(presetSnapshot.completedPresetCount)/\(totalPresetCount) downloaded)..."
                    }
                }
                continue
            }

            for item in items {
                try Task.checkCancellation()

                let before = await tracker.snapshot()
                await MainActor.run {
                    completedModelCount = before.completedPresetCount
                    statusText = onboardingModelName(for: preset)
                }

                try await Self.downloadFile(item: item)

                let fileSnapshot = await tracker.markDownloaded(units: item.workUnits)
                await MainActor.run {
                    completedModelCount = fileSnapshot.completedPresetCount
                    progress = max(progress, min(fileSnapshot.fraction, 0.99))
                    statusText = onboardingModelName(for: preset)
                }
            }

            let presetSnapshot = await tracker.markPresetCompleted()
            await MainActor.run {
                completedModelCount = presetSnapshot.completedPresetCount
                progress = max(progress, min(presetSnapshot.fraction, 0.99))
                if presetSnapshot.completedPresetCount == totalPresetCount {
                    statusText = "Downloads complete. Verifying files..."
                } else {
                    statusText = "Downloaded \(preset.displayName) (\(presetSnapshot.completedPresetCount)/\(totalPresetCount) downloaded)..."
                }
            }
        }
    }

    private func verifyAllModelFilesDownloaded(
        presets: [LocalASRModelPreset],
        modelsRoot: URL
    ) async throws {
        await MainActor.run {
            statusText = "Verifying downloaded model files..."
        }

        var missing = missingModelPresets(from: presets, modelsRoot: modelsRoot)
        if missing.isEmpty {
            return
        }

        let repairPlan = try await Self.buildDownloadPlan(
            for: missing,
            requiredFiles: Self.requiredModelFiles,
            modelsRoot: modelsRoot
        )

        try await executeDownloadPlan(
            repairPlan,
            totalPresetCount: presets.count
        )

        missing = missingModelPresets(from: presets, modelsRoot: modelsRoot)
        if !missing.isEmpty {
            throw ASRError.localRuntimeUnavailable(
                detail: "Missing required files for: \(missing.map(\.displayName).joined(separator: ", "))"
            )
        }
    }

    private func missingModelPresets(
        from presets: [LocalASRModelPreset],
        modelsRoot: URL
    ) -> [LocalASRModelPreset] {
        presets.filter { preset in
            let modelDirectory = modelDirectoryURL(for: preset, modelsRoot: modelsRoot)
            return Self.requiredModelFileSet.contains { fileName in
                !FileManager.default.fileExists(
                    atPath: modelDirectory.appendingPathComponent(fileName).path
                )
            }
        }
    }

    private func modelDirectoryURL(
        for preset: LocalASRModelPreset,
        modelsRoot: URL
    ) -> URL {
        modelsRoot
            .appendingPathComponent(preset.modelRepository.replacingOccurrences(of: "/", with: "--"))
    }

    private func modelsRootDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(Constants.bundleIdentifier)
            .appendingPathComponent(Constants.localModelsFolderName)
    }

    private func onboardingModelName(for preset: LocalASRModelPreset) -> String {
        switch preset {
        case .fast:
            return "Fast - Qwen3-ASR-0.6B 8-bit"
        case .balanced:
            return "Balanced - Qwen3-ASR-1.7B 4-bit"
        }
    }
}

private extension ModelDownloadStep {
    nonisolated static func buildDownloadPlan(
        for presets: [LocalASRModelPreset],
        requiredFiles: [String],
        modelsRoot: URL
    ) async throws -> DownloadPlan {
        try await withThrowingTaskGroup(of: FileDownloadPlan.self) { group in
            for preset in presets {
                for fileName in requiredFiles {
                    group.addTask {
                        try await buildFileDownloadPlan(
                            preset: preset,
                            fileName: fileName,
                            modelsRoot: modelsRoot
                        )
                    }
                }
            }

            var itemsByPreset: [LocalASRModelPreset: [ModelFileDownloadItem]] = [:]
            var totalWorkUnits: Int64 = 0
            var completedWorkUnits: Int64 = 0

            for preset in presets {
                itemsByPreset[preset] = []
            }

            for try await filePlan in group {
                totalWorkUnits += filePlan.workUnits
                if filePlan.isComplete {
                    completedWorkUnits += filePlan.workUnits
                } else {
                    itemsByPreset[filePlan.preset, default: []].append(filePlan.item)
                }
            }

            for preset in presets {
                itemsByPreset[preset]?.sort {
                    requiredFiles.firstIndex(of: $0.fileName) ?? .max
                        < requiredFiles.firstIndex(of: $1.fileName) ?? .max
                }
            }

            let completedPresetCount = presets
                .filter { (itemsByPreset[$0] ?? []).isEmpty }
                .count

            return DownloadPlan(
                itemsByPreset: itemsByPreset,
                totalWorkUnits: totalWorkUnits,
                completedWorkUnits: completedWorkUnits,
                completedPresetCount: completedPresetCount
            )
        }
    }

    nonisolated static func buildFileDownloadPlan(
        preset: LocalASRModelPreset,
        fileName: String,
        modelsRoot: URL
    ) async throws -> FileDownloadPlan {
        let remoteURL = try remoteFileURL(for: preset, fileName: fileName)
        let expectedBytes = try await fetchRemoteFileSize(remoteURL: remoteURL)
        let workUnits = max(expectedBytes, 1)

        let localURL = modelsRoot
            .appendingPathComponent(preset.modelRepository.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent(fileName)
        let existingBytes = fileSize(at: localURL)
        let isComplete = expectedBytes > 0 ? (existingBytes == expectedBytes) : (existingBytes > 0)

        return FileDownloadPlan(
            preset: preset,
            item: ModelFileDownloadItem(
                preset: preset,
                fileName: fileName,
                remoteURL: remoteURL,
                localURL: localURL,
                expectedBytes: expectedBytes,
                workUnits: workUnits
            ),
            isComplete: isComplete,
            workUnits: workUnits
        )
    }

    nonisolated static func remoteFileURL(
        for preset: LocalASRModelPreset,
        fileName: String
    ) throws -> URL {
        guard var components = URLComponents(string: "https://huggingface.co") else {
            throw ASRError.invalidURL
        }
        components.path = "/\(preset.modelRepository)/resolve/main/\(fileName)"
        guard let url = components.url else {
            throw ASRError.invalidURL
        }
        return url
    }

    nonisolated static func fetchRemoteFileSize(remoteURL: URL) async throws -> Int64 {
        var headRequest = URLRequest(url: remoteURL)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 60

        let (_, headResponse) = try await URLSession.shared.data(for: headRequest)
        if let http = headResponse as? HTTPURLResponse,
           (200...399).contains(http.statusCode),
           let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
           let size = Int64(contentLength),
           size > 0 {
            return size
        }

        var rangeRequest = URLRequest(url: remoteURL)
        rangeRequest.httpMethod = "GET"
        rangeRequest.timeoutInterval = 60
        rangeRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let (_, rangeResponse) = try await URLSession.shared.data(for: rangeRequest)
        if let http = rangeResponse as? HTTPURLResponse,
           (200...399).contains(http.statusCode),
           let size = parseTotalBytesFromContentRange(http.value(forHTTPHeaderField: "Content-Range")),
           size > 0 {
            return size
        }

        return 0
    }

    nonisolated static func parseTotalBytesFromContentRange(_ contentRange: String?) -> Int64? {
        guard let contentRange else { return nil }
        let parts = contentRange.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return Int64(parts[1])
    }

    nonisolated static func downloadFile(item: ModelFileDownloadItem) async throws {
        var request = URLRequest(url: item.remoteURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 300

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw ASRError.localRuntimeUnavailable(
                detail: "Failed to download \(item.fileName)"
            )
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: item.localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: item.localURL.path) {
            try fileManager.removeItem(at: item.localURL)
        }

        try fileManager.moveItem(at: tempURL, to: item.localURL)

        if item.expectedBytes > 0 {
            let finalBytes = fileSize(at: item.localURL)
            if finalBytes != item.expectedBytes {
                throw ASRError.localRuntimeUnavailable(
                    detail: "Size mismatch for \(item.fileName): expected \(item.expectedBytes), got \(finalBytes)"
                )
            }
        }
    }

    nonisolated static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber else {
            return 0
        }
        return number.int64Value
    }
}
