import Foundation
import FluidAudio
import AppKit
import os

struct FluidAudioDownloadStatus {
    let fractionCompleted: Double
    let message: String
    let isIndeterminate: Bool

    init(fractionCompleted: Double, message: String, isIndeterminate: Bool = false) {
        self.fractionCompleted = fractionCompleted
        self.message = message
        self.isIndeterminate = isIndeterminate
    }
}

@MainActor
class FluidAudioModelManager: ObservableObject {
    @Published private var downloadStatuses: [String: FluidAudioDownloadStatus] = [:]
    @Published private var modelStateRevision = 0
    private var activeDownloadIDs: [String: UUID] = [:]

    var onModelDeleted: ((String) -> Void)?
    var onModelsChanged: (() -> Void)?

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioModelManager")

    // Add new Fluid Audio models here when support is added.
    nonisolated private static let modelVersionMap: [String: AsrModelVersion] = [
        "parakeet-tdt-0.6b-v2": .v2,
        "parakeet-tdt-0.6b-v3": .v3,
    ]

    nonisolated static func asrVersion(for modelName: String) -> AsrModelVersion {
        modelVersionMap[modelName] ?? .v3
    }

    nonisolated static func isParakeetUnifiedModel(named modelName: String) -> Bool {
        false
    }

    nonisolated static func isNemotronModel(named modelName: String) -> Bool {
        false
    }

    nonisolated static func requiresRealtime(named modelName: String) -> Bool {
        false
    }

    init() {}

    // MARK: - Query helpers

    func isFluidAudioModelDownloaded(named modelName: String) -> Bool {
        let version = Self.asrVersion(for: modelName)
        return AsrModels.modelsExist(at: cacheDirectory(for: version), version: version)
    }

    func isFluidAudioModelDownloaded(_ model: FluidAudioModel) -> Bool {
        isFluidAudioModelDownloaded(named: model.name)
    }

    func isFluidAudioModelDownloading(_ model: FluidAudioModel) -> Bool {
        downloadStatuses[model.name] != nil
    }

    func downloadStatus(for model: FluidAudioModel) -> FluidAudioDownloadStatus? {
        downloadStatuses[model.name]
    }

    // MARK: - Download

    func downloadFluidAudioModel(_ model: FluidAudioModel) async {
        if isFluidAudioModelDownloaded(model) || isFluidAudioModelDownloading(model) {
            return
        }

        let modelName = model.name
        let downloadID = UUID()
        activeDownloadIDs[modelName] = downloadID
        downloadStatuses[modelName] = FluidAudioDownloadStatus(
            fractionCompleted: 0.0,
            message: "Preparing FluidAudio download..."
        )
        defer {
            clearDownloadStatus(for: modelName, downloadID: downloadID)
            onModelsChanged?()
        }

        do {
            updateDownloadProgress(0.1, for: modelName, downloadID: downloadID)
            _ = try await AsrModels.downloadAndLoad(version: Self.asrVersion(for: modelName))
            updateDownloadProgress(1.0, for: modelName, downloadID: downloadID)
            modelStateRevision += 1
        } catch {
            logger.error("❌ FluidAudio download failed for \(modelName, privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: - Delete

    func deleteFluidAudioModel(_ model: FluidAudioModel) {
        let cacheDirectory = cacheDirectory(for: model)

        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
        } catch {
            // Silently ignore removal errors
        }

        // Notify TranscriptionModelManager to clear currentTranscriptionModel if it matches
        modelStateRevision += 1
        onModelDeleted?(model.name)
    }

    // MARK: - Finder

    func showFluidAudioModelInFinder(_ model: FluidAudioModel) {
        let cacheDirectory = cacheDirectory(for: model)

        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            NSWorkspace.shared.selectFile(cacheDirectory.path, inFileViewerRootedAtPath: "")
        }
    }

    // MARK: - Private helpers

    private func cacheDirectory(for model: FluidAudioModel) -> URL {
        cacheDirectory(for: Self.asrVersion(for: model.name))
    }

    private func cacheDirectory(for version: AsrModelVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    private func clearDownloadStatus(for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID else { return }
        activeDownloadIDs[modelName] = nil
        downloadStatuses[modelName] = nil
    }

    private func updateDownloadProgress(_ fraction: Double, for modelName: String, downloadID: UUID) {
        guard activeDownloadIDs[modelName] == downloadID else { return }

        downloadStatuses[modelName] = FluidAudioDownloadStatus(
            fractionCompleted: min(max(fraction, 0.0), 1.0),
            message: fraction < 1.0
                ? String(localized: "Downloading models...")
                : String(localized: "Finalizing models...")
        )
    }
}
