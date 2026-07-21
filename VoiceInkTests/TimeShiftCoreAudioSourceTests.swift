import CoreAudio
import Foundation
import Testing
@testable import VoiceInk

struct TimeShiftCoreAudioSourceTests {
    @Test func startUsesOnlyTheMemoryCaptureBoundaryAndAppendsPCM() async throws {
        let capture = TimeShiftMemoryCaptureSpy()
        let ring = PCM16RingBuffer(capacitySamples: 4)
        let source = TimeShiftCoreAudioSource(capture: capture, ring: ring)

        try await source.start(deviceID: 42)
        capture.emit(pcmData([1, 2, 3]))

        #expect(capture.startedDeviceIDs == [42])
        #expect(source.isCapturing)
        #expect(source.bufferedSampleCount == 3)
        await source.stopAndClear()
    }

    @Test func audioEmittedDuringStartIsRetained() async throws {
        let capture = TimeShiftMemoryCaptureSpy(startEmission: pcmData([4, 5]))
        let source = TimeShiftCoreAudioSource(
            capture: capture,
            ring: PCM16RingBuffer(capacitySamples: 4)
        )

        try await source.start(deviceID: 2)
        let snapshot = await source.stopAndSnapshot()

        #expect(samples(from: snapshot.pcmDataCopy()) == [4, 5])
    }

    @Test func snapshotIncludesFinalDrainedChunkThenRejectsRetainedCallback() async throws {
        let capture = TimeShiftMemoryCaptureSpy(stopEmission: pcmData([30]))
        let ring = PCM16RingBuffer(capacitySamples: 4)
        let source = TimeShiftCoreAudioSource(capture: capture, ring: ring)
        try await source.start(deviceID: 7)
        capture.emit(pcmData([10, 20]))

        let snapshot = await source.stopAndSnapshot()

        #expect(capture.events == ["start", "stop", "detach"])
        #expect(samples(from: snapshot.pcmDataCopy()) == [10, 20, 30])
        #expect(!source.isCapturing)
        #expect(source.bufferedSampleCount == 0)
        #expect(ring.isStorageZeroed)

        capture.emitRetainedHandler(at: 0, data: pcmData([40]))
        #expect(source.bufferedSampleCount == 0)
    }

    @Test func retainedCallbackCannotAppendIntoALaterSession() async throws {
        let capture = TimeShiftMemoryCaptureSpy()
        let source = TimeShiftCoreAudioSource(
            capture: capture,
            ring: PCM16RingBuffer(capacitySamples: 4)
        )
        try await source.start(deviceID: 1)
        _ = await source.stopAndSnapshot()

        try await source.start(deviceID: 1)
        capture.emitRetainedHandler(at: 0, data: pcmData([99]))
        capture.emit(pcmData([7]))
        let second = await source.stopAndSnapshot()

        #expect(samples(from: second.pcmDataCopy()) == [7])
    }

    @Test func stopAndClearZeroesAudioWithoutCreatingASnapshot() async throws {
        let capture = TimeShiftMemoryCaptureSpy()
        let ring = PCM16RingBuffer(capacitySamples: 4)
        let source = TimeShiftCoreAudioSource(capture: capture, ring: ring)
        try await source.start(deviceID: 3)
        capture.emit(pcmData([1, 2]))

        await source.stopAndClear()

        #expect(capture.events == ["start", "stop", "detach"])
        #expect(ring.isStorageZeroed)
        #expect(!source.isCapturing)
    }

    @Test func failedStartStopsDetachesAndZeroesTheRing() async {
        let capture = TimeShiftMemoryCaptureSpy(startError: .failed)
        let ring = PCM16RingBuffer(capacitySamples: 4)
        ring.append(pcmData([1]))
        let source = TimeShiftCoreAudioSource(capture: capture, ring: ring)

        await #expect(throws: TimeShiftMemoryCaptureSpy.Error.failed) {
            try await source.start(deviceID: 9)
        }
        #expect(capture.events == ["start", "stop", "detach"])
        #expect(ring.isStorageZeroed)
        #expect(!source.isCapturing)
    }

    @Test func startingTwiceIsRejectedWithoutRebindingOldAudio() async throws {
        let capture = TimeShiftMemoryCaptureSpy()
        let source = TimeShiftCoreAudioSource(capture: capture)
        try await source.start(deviceID: 8)

        await #expect(throws: TimeShiftCoreAudioSourceError.alreadyCapturing) {
            try await source.start(deviceID: 8)
        }

        #expect(capture.startedDeviceIDs == [8])
        await source.stopAndClear()
    }

    @Test func deinitStopsDetachesAndClears() async throws {
        let capture = TimeShiftMemoryCaptureSpy()
        let ring = PCM16RingBuffer(capacitySamples: 4)
        var source: TimeShiftCoreAudioSource? = TimeShiftCoreAudioSource(
            capture: capture,
            ring: ring
        )
        try await source?.start(deviceID: 5)
        capture.emit(pcmData([1]))

        source = nil

        #expect(capture.events == ["start", "stop", "detach"])
        #expect(ring.isStorageZeroed)
    }

    private func pcmData(_ samples: [Int16]) -> Data {
        Self.pcmData(samples)
    }

    private static func pcmData(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func samples(from data: Data) -> [Int16] {
        stride(from: 0, to: data.count - (data.count % 2), by: 2).map { offset in
            let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            return Int16(bitPattern: raw)
        }
    }
}

private final class TimeShiftMemoryCaptureSpy: TimeShiftMemoryAudioCapturing, @unchecked Sendable {
    enum Error: Swift.Error {
        case failed
    }

    private let lock = NSLock()
    private var handler: ((Data) -> Void)?
    private var retainedHandlers: [(Data) -> Void] = []
    private let startError: Error?
    private let startEmission: Data?
    private let stopEmission: Data?
    private var startedDeviceIDsStorage: [AudioDeviceID] = []
    private var eventsStorage: [String] = []

    var startedDeviceIDs: [AudioDeviceID] {
        lock.lock()
        defer { lock.unlock() }
        return startedDeviceIDsStorage
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return eventsStorage
    }

    var onAudioChunk: ((Data) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }
        set {
            lock.lock()
            handler = newValue
            if let newValue {
                retainedHandlers.append(newValue)
            } else {
                eventsStorage.append("detach")
            }
            lock.unlock()
        }
    }

    init(
        startError: Error? = nil,
        startEmission: Data? = nil,
        stopEmission: Data? = nil
    ) {
        self.startError = startError
        self.startEmission = startEmission
        self.stopEmission = stopEmission
    }

    func startMemoryCapture(deviceID: AudioDeviceID) throws {
        lock.lock()
        eventsStorage.append("start")
        startedDeviceIDsStorage.append(deviceID)
        let handler = self.handler
        let emission = startEmission
        let error = startError
        lock.unlock()

        if let emission {
            handler?(emission)
        }
        if let error {
            throw error
        }
    }

    func stopRecording() {
        lock.lock()
        eventsStorage.append("stop")
        let handler = self.handler
        let emission = stopEmission
        lock.unlock()
        if let emission {
            handler?(emission)
        }
    }

    func emit(_ data: Data) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(data)
    }

    func emitRetainedHandler(at index: Int, data: Data) {
        lock.lock()
        let handler = retainedHandlers[index]
        lock.unlock()
        handler(data)
    }
}
