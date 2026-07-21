import AVFoundation
import CoreAudio
import Foundation
import os

protocol AudioCaptureLeaseCoordinating: Sendable {
    func acquire(for owner: AudioCaptureLeaseOwner) async -> AudioCaptureLeaseAcquisition

    @discardableResult
    func release(_ lease: AudioCaptureLease) async -> Bool
}

extension AudioCaptureLeaseCoordinator: AudioCaptureLeaseCoordinating {
    /// The application-wide coordinator used by production capture paths.
    /// Tests and isolated workflows can inject their own coordinator instead.
    static let applicationShared = AudioCaptureLeaseCoordinator()
}

@MainActor
class Recorder: NSObject, ObservableObject {
    var recorder: CoreAudioRecorder?
    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Recorder")
    let deviceManager = AudioDeviceManager.shared
    private var audioDeviceChangedObserver: NSObjectProtocol?
    var recordingDeviceChangeObserver: NSObjectProtocol?
    private let mediaController = MediaController.shared
    private let playbackController = PlaybackController.shared
    /// Dedicated serial queue for hardware setup.
    let audioSetupQueue = DispatchQueue(label: "com.prakashjoshipax.voiceink.audioSetup", qos: .userInitiated)
    private let recordingAudioActionDelayNanoseconds: UInt64 = 220_000_000
    private var audioMuteTask: Task<Void, Never>?
    private var mediaPauseTask: Task<Void, Never>?
    private var audioRestorationTask: Task<Void, Never>?
    private let smoothedValuesLock = NSLock()
    private var smoothedAverage: Float = 0
    private var smoothedPeak: Float = 0
    private let audioCaptureLeaseCoordinator: any AudioCaptureLeaseCoordinating
    private let audioCaptureLeaseOwner: AudioCaptureLeaseOwner?
    private var activeAudioCaptureLease: AudioCaptureLease?

    /// Audio chunk callback for streaming. Can be updated while recording;
    /// changes are forwarded to the live CoreAudioRecorder.
    var onAudioChunk: ((_ data: Data) -> Void)? {
        didSet { recorder?.onAudioChunk = onAudioChunk }
    }

    enum RecorderError: Error, Equatable {
        case couldNotStartRecording
        case noUsableMicrophone(builtInBlockedByClosedLid: Bool)
        case audioCaptureUnavailable
    }

    override convenience init() {
        self.init(
            audioCaptureLeaseCoordinator: AudioCaptureLeaseCoordinator.applicationShared
        )
    }

    init(
        audioCaptureLeaseCoordinator: any AudioCaptureLeaseCoordinating,
        audioCaptureLeaseOwner: AudioCaptureLeaseOwner? = .normalRecording,
        prepareOnInitialization: Bool = true
    ) {
        self.audioCaptureLeaseCoordinator = audioCaptureLeaseCoordinator
        self.audioCaptureLeaseOwner = audioCaptureLeaseOwner
        super.init()
        setupAudioDeviceChangedObserver()
        setupRecordingDeviceChangeObserver()
        if prepareOnInitialization {
            schedulePrepareForCurrentDevice(reason: "init")
        }
    }

    private func setupAudioDeviceChangedObserver() {
        audioDeviceChangedObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AudioDeviceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.deviceManager.isRecordingActive else { return }
                self.schedulePrepareForCurrentDevice(reason: "device-changed")
            }
        }
    }

    func startRecording(toOutputFile url: URL) async throws {
        var resolution = deviceManager.resolveCurrentRecordingDevice()
        guard var deviceID = resolution.deviceID else {
            onAudioChunk = nil
            throw RecorderError.noUsableMicrophone(
                builtInBlockedByClosedLid: resolution.builtInBlockedByClosedLid
            )
        }

        guard await acquireAudioCaptureLeaseIfNeeded() else {
            onAudioChunk = nil
            throw RecorderError.audioCaptureUnavailable
        }

        deviceManager.beginRecordingSetup(deviceID: deviceID)

        audioRestorationTask?.cancel()
        audioRestorationTask = nil
        pauseMedia()
        muteSystemAudio()

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        do {
            do {
                try await startHardwareRecording(coreAudioRecorder, to: url, deviceID: deviceID)
            } catch {
                let retryResolution = deviceManager.resolveCurrentRecordingDevice(excluding: deviceID)
                guard deviceManager.isClamshellClosed,
                    deviceManager.isBuiltInDevice(deviceID),
                    let fallbackDeviceID = retryResolution.deviceID
                else {
                    throw error
                }

                deviceID = fallbackDeviceID
                resolution = retryResolution
                deviceManager.beginRecordingSetup(deviceID: fallbackDeviceID)
                try await startHardwareRecording(coreAudioRecorder, to: url, deviceID: fallbackDeviceID)
            }

            deviceManager.recordingDidStart(deviceID: deviceID)
            showRecordingDeviceNotification(for: deviceID, resolution: resolution)
            UserDefaults.standard.set(String(deviceID), forKey: "lastUsedMicrophoneDeviceID")
            resetAudioMeter()
        } catch {
            logger.error(
                "Failed to start recording deviceID=\(deviceID, privacy: .public) file=\(url.lastPathComponent, privacy: .public) error=\(error, privacy: .public)"
            )
            await stopRecording()
            throw RecorderError.couldNotStartRecording
        }
    }

    func stopRecording() async {
        // Reserve this exact lease for release by this stop operation. Clearing
        // the property before suspension prevents overlapping stop calls from
        // releasing it more than once; the coordinator remains occupied until
        // the hardware queue has drained and cleanup below has completed.
        let audioCaptureLease = activeAudioCaptureLease
        activeAudioCaptureLease = nil

        audioMuteTask?.cancel()
        audioMuteTask = nil
        mediaPauseTask?.cancel()
        mediaPauseTask = nil
        // Capture current recorder to stop it on the serial hardware queue.
        let currentRecorder = self.recorder

        await withCheckedContinuation { continuation in
            audioSetupQueue.async {
                currentRecorder?.stopRecording()
                continuation.resume()
            }
        }
        onAudioChunk = nil

        resetAudioMeter()

        audioRestorationTask?.cancel()
        audioRestorationTask = Task {
            await mediaController.unmuteSystemAudio()
            await playbackController.resumeMedia()
        }
        deviceManager.recordingDidStop()

        if let audioCaptureLease {
            _ = await audioCaptureLeaseCoordinator.release(audioCaptureLease)
        }
    }

    private func acquireAudioCaptureLeaseIfNeeded() async -> Bool {
        guard let audioCaptureLeaseOwner else {
            return true
        }
        guard activeAudioCaptureLease == nil else {
            return false
        }

        let acquisition = await audioCaptureLeaseCoordinator.acquire(
            for: audioCaptureLeaseOwner
        )
        guard let lease = acquisition.lease else {
            return false
        }
        activeAudioCaptureLease = lease
        return true
    }

    private func muteSystemAudio() {
        audioMuteTask?.cancel()
        audioMuteTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.recordingAudioActionDelayNanoseconds)
            guard !Task.isCancelled else { return }
            _ = await self.mediaController.muteSystemAudio()
        }
    }

    private func pauseMedia() {
        mediaPauseTask?.cancel()
        mediaPauseTask = Task { [weak self] in
            guard let self else { return }
            await self.playbackController.pauseMedia()
        }
    }

    private func schedulePrepareForCurrentDevice(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return
        }

        let deviceID = deviceManager.getCurrentDevice()
        guard deviceID != 0 else {
            recorder?.teardown()
            return
        }

        let coreAudioRecorder = recorder ?? CoreAudioRecorder()
        coreAudioRecorder.onAudioChunk = onAudioChunk
        recorder = coreAudioRecorder

        audioSetupQueue.async { [logger] in
            do {
                try coreAudioRecorder.prepare(deviceID: deviceID)
            } catch {
                logger.warning(
                    "Recorder prepare failed reason=\(reason, privacy: .public) deviceID=\(deviceID, privacy: .public) error=\(error, privacy: .public)"
                )
            }
        }
    }

    func audioMeterSnapshot() -> AudioMeter {
        guard let recorder else {
            return AudioMeter(averagePower: 0, peakPower: 0)
        }

        // Sample audio levels (thread-safe read)
        let averagePower = recorder.averagePower
        let peakPower = recorder.peakPower

        // Normalize values
        let minVisibleDb: Float = -60.0
        let maxVisibleDb: Float = 0.0

        let normalizedAverage: Float
        if averagePower < minVisibleDb {
            normalizedAverage = 0.0
        } else if averagePower >= maxVisibleDb {
            normalizedAverage = 1.0
        } else {
            normalizedAverage = (averagePower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        let normalizedPeak: Float
        if peakPower < minVisibleDb {
            normalizedPeak = 0.0
        } else if peakPower >= maxVisibleDb {
            normalizedPeak = 1.0
        } else {
            normalizedPeak = (peakPower - minVisibleDb) / (maxVisibleDb - minVisibleDb)
        }

        // Apply EMA smoothing with thread-safe access
        smoothedValuesLock.lock()
        smoothedAverage = smoothedAverage * 0.6 + normalizedAverage * 0.4
        smoothedPeak = smoothedPeak * 0.6 + normalizedPeak * 0.4
        let audioMeter = AudioMeter(
            averagePower: Double(smoothedAverage),
            peakPower: Double(smoothedPeak)
        )
        smoothedValuesLock.unlock()

        return audioMeter
    }

    private func resetAudioMeter() {
        smoothedValuesLock.lock()
        smoothedAverage = 0
        smoothedPeak = 0
        smoothedValuesLock.unlock()
    }

    // MARK: - Cleanup

    deinit {
        audioMuteTask?.cancel()
        mediaPauseTask?.cancel()
        audioRestorationTask?.cancel()
        if let observer = audioDeviceChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = recordingDeviceChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        recorder?.teardown()

        if let activeAudioCaptureLease {
            let coordinator = audioCaptureLeaseCoordinator
            Task {
                _ = await coordinator.release(activeAudioCaptureLease)
            }
        }
    }
}

struct AudioMeter: Equatable {
    let averagePower: Double
    let peakPower: Double
}
