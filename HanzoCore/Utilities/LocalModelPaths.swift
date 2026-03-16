import Foundation

enum LocalModelPaths {
    static func modelsRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(Constants.bundleIdentifier)
            .appendingPathComponent(Constants.localModelsFolderName)
    }

    static func llmModelsDirectory(fileManager: FileManager = .default) -> URL {
        modelsRoot(fileManager: fileManager)
            .appendingPathComponent(Constants.localLLMModelsSubfolderName)
    }

    static func llmModelFile(fileManager: FileManager = .default) -> URL {
        llmModelsDirectory(fileManager: fileManager)
            .appendingPathComponent(Constants.localLLMModelFileName)
    }
}
