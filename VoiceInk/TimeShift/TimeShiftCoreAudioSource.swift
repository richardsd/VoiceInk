import CoreAudio
import Foundation

/// The deliberately small hardware boundary used by Time-Shift.
///
/// Unlike `Recorder`, this protocol has no file URL, media-pause, system-mute,
/// sound, or application-recording-state operations. A conforming source can
/// only stream canonical in-memory PCM and stop.
protocol TimeShiftMemoryAudioCapturing: AnyObject, Sendable {
    var onAudioChunk: ((Data) -> Void)? { get set }

    func startMemoryCapture(deviceID: AudioDeviceID) throws
    func stopRecording()
}

extension CoreAudioRecorder: TimeShiftMemoryAudioCapturing {}

enum TimeShiftCoreAudioSourceError: Error, Equatable {
    case alreadyCapturing
}

private final class TimeShiftCaptureGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeGeneration: UUID?

    func activate() -> UUID {
        let generation = UUID()
        lock.lock()
        activeGeneration = generation
        lock.unlock()
        return generation
    }

    func deactivate(_ generation: UUID?) {
        lock.lock()
        if activeGeneration == generation {
            activeGeneration = nil
        }
        lock.unlock()
    }

    func accepts(_ generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }
}

/// Owns one memory-only CoreAudio capture and its fixed 15-second ring.
///
/// All AUHAL operations run on a private serial queue. Stop drains the hardware
/// while the current generation remains valid, then closes the generation
/// before detaching and snapshotting. A backend-retained stale callback can
/// therefore never append to a later session.
final class TimeShiftCoreAudioSource: @unchecked Sendable {
    private let capture: any TimeShiftMemoryAudioCapturing
    private let ring: PCM16RingBuffer
    private let generationGate = TimeShiftCaptureGenerationGate()
    private let hardwareQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.timeshift.memory-audio"
    )
    private let hardwareQueueKey = DispatchSpecificKey<Void>()

    // Access only on hardwareQueue.
    private var isCapturingStorage = false
    private var activeGeneration: UUID?

    init(
        capture: any TimeShiftMemoryAudioCapturing = CoreAudioRecorder(),
        ring: PCM16RingBuffer = PCM16RingBuffer()
    ) {
        self.capture = capture
        self.ring = ring
        hardwareQueue.setSpecific(key: hardwareQueueKey, value: ())
    }

    deinit {
        performHardwareSync {
            stopAndClearSynchronous()
        }
    }

    var isCapturing: Bool {
        performHardwareSync { isCapturingStorage }
    }

    var bufferedSampleCount: Int {
        ring.bufferedSampleCount
    }

    func start(deviceID: AudioDeviceID) async throws {
        try await withCheckedThrowingContinuation { continuation in
            hardwareQueue.async { [self] in
                do {
                    try startSynchronous(deviceID: deviceID)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopAndSnapshot() async -> PCM16Snapshot {
        await withCheckedContinuation { continuation in
            hardwareQueue.async { [self] in
                continuation.resume(returning: stopAndSnapshotSynchronous())
            }
        }
    }

    func stopAndClear() async {
        await withCheckedContinuation { continuation in
            hardwareQueue.async { [self] in
                stopAndClearSynchronous()
                continuation.resume()
            }
        }
    }

    private func startSynchronous(deviceID: AudioDeviceID) throws {
        guard !isCapturingStorage else {
            throw TimeShiftCoreAudioSourceError.alreadyCapturing
        }

        ring.clear()
        let generation = generationGate.activate()
        activeGeneration = generation
        capture.onAudioChunk = { [ring, generationGate] data in
            guard generationGate.accepts(generation) else { return }
            ring.append(data)
        }

        do {
            try capture.startMemoryCapture(deviceID: deviceID)
            isCapturingStorage = true
        } catch {
            // A backend may fail after partially starting. Its stop contract
            // drains any final callback before the generation is invalidated.
            capture.stopRecording()
            generationGate.deactivate(generation)
            activeGeneration = nil
            capture.onAudioChunk = nil
            ring.clear()
            throw error
        }
    }

    private func stopAndSnapshotSynchronous() -> PCM16Snapshot {
        capture.stopRecording()
        generationGate.deactivate(activeGeneration)
        activeGeneration = nil
        capture.onAudioChunk = nil
        isCapturingStorage = false
        return ring.snapshotAndClear()
    }

    private func stopAndClearSynchronous() {
        capture.stopRecording()
        generationGate.deactivate(activeGeneration)
        activeGeneration = nil
        capture.onAudioChunk = nil
        isCapturingStorage = false
        ring.clear()
    }

    private func performHardwareSync<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: hardwareQueueKey) != nil {
            return operation()
        }
        return hardwareQueue.sync(execute: operation)
    }
}
