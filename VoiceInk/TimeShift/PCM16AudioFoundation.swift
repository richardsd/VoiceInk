import Darwin
import Foundation

/// A memory-only snapshot of VoiceInk's canonical transcription audio format.
///
/// The backing bytes are protected by a lock so the snapshot can cross task
/// boundaries safely. Call `zeroize()` as soon as the transcription consumer
/// finishes with the audio.
final class PCM16Snapshot: @unchecked Sendable {
    static let sampleRate: UInt32 = 16_000
    static let channelCount: UInt16 = 1
    static let bitsPerSample: UInt16 = 16
    static let bytesPerSample = Int(bitsPerSample / 8)

    private let lock = NSLock()
    private var storage: Data

    init(pcmData: Data) {
        let completeByteCount = pcmData.count - (pcmData.count % Self.bytesPerSample)
        storage = Data(pcmData.prefix(completeByteCount))
    }

    deinit {
        zeroize()
    }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    var sampleCount: Int {
        byteCount / Self.bytesPerSample
    }

    var duration: TimeInterval {
        TimeInterval(sampleCount) / TimeInterval(Self.sampleRate)
    }

    var isEmpty: Bool {
        byteCount == 0
    }

    var isZeroized: Bool {
        isEmpty
    }

    /// Returns a transient copy suitable for an in-memory transcription adapter.
    /// The caller should release its copy as soon as the request completes.
    func pcmDataCopy() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return Data(storage)
    }

    /// Exposes normalized Float32 samples only for the lifetime of `body`.
    /// The temporary float storage is overwritten before this method returns,
    /// so local in-memory adapters do not need to retain another audio copy.
    func withNormalizedFloatSamples<Result>(
        _ body: (UnsafeBufferPointer<Float32>) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        var samples = storage.withUnsafeBytes { rawBytes -> [Float32] in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: Self.bytesPerSample).map { offset in
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                return Float32(Int16(bitPattern: bits)) / 32_768.0
            }
        }
        lock.unlock()

        defer {
            samples.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return }
                memset(baseAddress, 0, bytes.count)
            }
            samples.removeAll(keepingCapacity: false)
        }
        return try samples.withUnsafeBufferPointer(body)
    }

    /// Overwrites the owned bytes before releasing the snapshot's storage.
    func zeroize() {
        lock.lock()
        defer { lock.unlock() }

        storage.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return }
            memset(baseAddress, 0, bytes.count)
        }
        storage.removeAll(keepingCapacity: false)
    }
}

/// A fixed-capacity rolling buffer for 16 kHz, mono, signed 16-bit PCM.
///
/// Appends may arrive from the Core Audio processing queue, while snapshots and
/// lifecycle clears occur elsewhere. All mutable state is therefore protected
/// by a lock. A single trailing byte is retained until the next append so an
/// arbitrarily split byte stream never exposes a partial sample.
final class PCM16RingBuffer: @unchecked Sendable {
    static let durationSeconds = 15
    static let capacitySamples = Int(PCM16Snapshot.sampleRate) * durationSeconds
    static let capacityBytes = capacitySamples * PCM16Snapshot.bytesPerSample

    private let lock = NSLock()
    private var storage: [UInt8]
    private var writeIndex = 0
    private var storedByteCount = 0
    private var pendingByte: UInt8?

    /// The default is the product's fixed 15-second capacity. The smaller
    /// internal initializer is useful for deterministic unit tests.
    init(capacitySamples: Int = PCM16RingBuffer.capacitySamples) {
        precondition(capacitySamples > 0, "PCM16 ring capacity must be positive")
        storage = [UInt8](
            repeating: 0,
            count: capacitySamples * PCM16Snapshot.bytesPerSample
        )
    }

    deinit {
        lock.lock()
        zeroStorageLocked()
        lock.unlock()
    }

    var byteCapacity: Int {
        storage.count
    }

    var bufferedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedByteCount
    }

    var bufferedSampleCount: Int {
        bufferedByteCount / PCM16Snapshot.bytesPerSample
    }

    var bufferedDuration: TimeInterval {
        TimeInterval(bufferedSampleCount) / TimeInterval(PCM16Snapshot.sampleRate)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        data.withUnsafeBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else { return }

            var offset = 0
            if let pendingByte {
                writeSampleBytesLocked(pendingByte, baseAddress[0])
                self.pendingByte = nil
                offset = 1
            }

            let remainingCount = bytes.count - offset
            let completeByteCount = remainingCount - (remainingCount % PCM16Snapshot.bytesPerSample)
            if completeByteCount > 0 {
                appendCompleteBytesLocked(
                    baseAddress.advanced(by: offset),
                    count: completeByteCount
                )
                offset += completeByteCount
            }

            if offset < bytes.count {
                pendingByte = baseAddress[offset]
            }
        }
    }

    func snapshot() -> PCM16Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshotLocked()
    }

    /// Atomically captures the current complete samples, then overwrites all
    /// ring storage and any incomplete trailing byte.
    func snapshotAndClear() -> PCM16Snapshot {
        lock.lock()
        defer { lock.unlock() }

        let snapshot = makeSnapshotLocked()
        zeroStorageLocked()
        return snapshot
    }

    /// Overwrites all owned audio before resetting the ring.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        zeroStorageLocked()
    }

    /// Internal verification seam; it exposes no captured audio.
    var isStorageZeroed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedByteCount == 0
            && pendingByte == nil
            && storage.allSatisfy { $0 == 0 }
    }

    private func writeSampleBytesLocked(_ first: UInt8, _ second: UInt8) {
        storage[writeIndex] = first
        storage[(writeIndex + 1) % storage.count] = second
        writeIndex = (writeIndex + PCM16Snapshot.bytesPerSample) % storage.count
        storedByteCount = min(storage.count, storedByteCount + PCM16Snapshot.bytesPerSample)
    }

    private func appendCompleteBytesLocked(
        _ source: UnsafePointer<UInt8>,
        count: Int
    ) {
        precondition(count % PCM16Snapshot.bytesPerSample == 0)
        guard count > 0 else { return }

        if count >= storage.count {
            let storageCount = storage.count
            let newestBytes = source.advanced(by: count - storageCount)
            storage.withUnsafeMutableBytes { destination in
                guard let destinationAddress = destination.baseAddress else { return }
                memcpy(destinationAddress, newestBytes, storageCount)
            }
            writeIndex = 0
            storedByteCount = storageCount
            return
        }

        let firstCopyCount = min(count, storage.count - writeIndex)
        storage.withUnsafeMutableBytes { destination in
            guard let destinationAddress = destination.baseAddress else { return }
            memcpy(destinationAddress.advanced(by: writeIndex), source, firstCopyCount)

            let secondCopyCount = count - firstCopyCount
            if secondCopyCount > 0 {
                memcpy(
                    destinationAddress,
                    source.advanced(by: firstCopyCount),
                    secondCopyCount
                )
            }
        }

        writeIndex = (writeIndex + count) % storage.count
        storedByteCount = min(storage.count, storedByteCount + count)
    }

    private func chronologicalDataLocked() -> Data {
        guard storedByteCount > 0 else { return Data() }

        let startIndex = (writeIndex - storedByteCount + storage.count) % storage.count
        var result = Data(count: storedByteCount)

        result.withUnsafeMutableBytes { destination in
            guard let destinationAddress = destination.baseAddress else { return }
            storage.withUnsafeBytes { source in
                guard let sourceAddress = source.baseAddress else { return }

                let firstCopyCount = min(storedByteCount, storage.count - startIndex)
                memcpy(
                    destinationAddress,
                    sourceAddress.advanced(by: startIndex),
                    firstCopyCount
                )

                let secondCopyCount = storedByteCount - firstCopyCount
                if secondCopyCount > 0 {
                    memcpy(
                        destinationAddress.advanced(by: firstCopyCount),
                        sourceAddress,
                        secondCopyCount
                    )
                }
            }
        }

        return result
    }

    private func makeSnapshotLocked() -> PCM16Snapshot {
        var transientData = chronologicalDataLocked()
        defer {
            if !transientData.isEmpty {
                transientData.resetBytes(in: 0..<transientData.count)
                transientData.removeAll(keepingCapacity: false)
            }
        }
        return PCM16Snapshot(pcmData: transientData)
    }

    private func zeroStorageLocked() {
        storage.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return }
            memset(baseAddress, 0, bytes.count)
        }
        pendingByte = 0
        pendingByte = nil
        writeIndex = 0
        storedByteCount = 0
    }
}

enum PCM16WAVEncoderError: Error, Equatable {
    case payloadTooLarge
}

/// Encodes canonical VoiceInk PCM into an in-memory RIFF/WAVE payload.
enum PCM16WAVEncoder {
    static let headerByteCount = 44

    static func encode(_ snapshot: PCM16Snapshot) throws -> Data {
        var pcmData = snapshot.pcmDataCopy()
        defer { zeroize(&pcmData) }
        guard pcmData.count <= Int(UInt32.max) - 36 else {
            throw PCM16WAVEncoderError.payloadTooLarge
        }

        let payloadByteCount = UInt32(pcmData.count)
        let blockAlignment = PCM16Snapshot.channelCount * (PCM16Snapshot.bitsPerSample / 8)
        let byteRate = PCM16Snapshot.sampleRate * UInt32(blockAlignment)

        var wav = Data()
        wav.reserveCapacity(headerByteCount + pcmData.count)
        wav.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(36) + payloadByteCount, to: &wav)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &wav)
        appendLittleEndian(UInt16(1), to: &wav)
        appendLittleEndian(PCM16Snapshot.channelCount, to: &wav)
        appendLittleEndian(PCM16Snapshot.sampleRate, to: &wav)
        appendLittleEndian(byteRate, to: &wav)
        appendLittleEndian(blockAlignment, to: &wav)
        appendLittleEndian(PCM16Snapshot.bitsPerSample, to: &wav)
        wav.append(contentsOf: "data".utf8)
        appendLittleEndian(payloadByteCount, to: &wav)
        wav.append(pcmData)
        return wav
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func zeroize(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.resetBytes(in: 0..<data.count)
        data.removeAll(keepingCapacity: false)
    }
}
