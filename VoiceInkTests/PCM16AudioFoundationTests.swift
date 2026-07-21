import Foundation
import Testing
@testable import VoiceInk

struct PCM16AudioFoundationTests {
    @Test func snapshotDropsAnIncompleteTrailingSampleAndReportsDuration() {
        let snapshot = PCM16Snapshot(pcmData: Data([0x01, 0x02, 0x03]))

        #expect(snapshot.pcmDataCopy() == Data([0x01, 0x02]))
        #expect(snapshot.byteCount == 2)
        #expect(snapshot.sampleCount == 1)
        #expect(snapshot.duration == 1.0 / 16_000.0)
    }

    @Test func ringUsesTheFixedFifteenSecondProductCapacity() {
        let ring = PCM16RingBuffer()

        #expect(PCM16RingBuffer.capacitySamples == 240_000)
        #expect(PCM16RingBuffer.capacityBytes == 480_000)
        #expect(ring.byteCapacity == 480_000)
    }

    @Test func ringReturnsCompleteSamplesInAppendOrder() {
        let ring = PCM16RingBuffer(capacitySamples: 6)
        ring.append(pcmData([1, 2]))
        ring.append(pcmData([3, 4]))

        let snapshot = ring.snapshot()

        #expect(samples(from: snapshot.pcmDataCopy()) == [1, 2, 3, 4])
        #expect(ring.bufferedSampleCount == 4)
        #expect(ring.bufferedDuration == 4.0 / 16_000.0)
    }

    @Test func ringWraparoundReturnsTheNewestSamplesChronologically() {
        let ring = PCM16RingBuffer(capacitySamples: 4)
        ring.append(pcmData([1, 2, 3]))
        ring.append(pcmData([4, 5]))

        #expect(samples(from: ring.snapshot().pcmDataCopy()) == [2, 3, 4, 5])
    }

    @Test func oversizedInputRetainsOnlyItsNewestCompleteSamples() {
        let ring = PCM16RingBuffer(capacitySamples: 4)
        ring.append(pcmData([1, 2, 3, 4, 5, 6, 7]))

        #expect(samples(from: ring.snapshot().pcmDataCopy()) == [4, 5, 6, 7])
        #expect(ring.bufferedByteCount == 8)
    }

    @Test func oddBytesAreJoinedAcrossAppendsWithoutExposingPartialAudio() {
        let ring = PCM16RingBuffer(capacitySamples: 4)
        ring.append(Data([0x01, 0x02, 0x03]))

        #expect(ring.snapshot().pcmDataCopy() == Data([0x01, 0x02]))
        #expect(ring.bufferedByteCount == 2)

        ring.append(Data([0x04]))

        #expect(ring.snapshot().pcmDataCopy() == Data([0x01, 0x02, 0x03, 0x04]))
        #expect(ring.bufferedByteCount == 4)
    }

    @Test func snapshotAndClearIsAtomicAndRemovesPendingAndStoredBytes() {
        let ring = PCM16RingBuffer(capacitySamples: 4)
        ring.append(Data([0x01, 0x02, 0x03]))

        let captured = ring.snapshotAndClear()

        #expect(captured.pcmDataCopy() == Data([0x01, 0x02]))
        #expect(ring.bufferedByteCount == 0)
        #expect(ring.snapshot().isEmpty)
        #expect(ring.isStorageZeroed)

        ring.append(Data([0x04]))
        #expect(ring.snapshot().isEmpty)
        ring.append(Data([0x05]))
        #expect(ring.snapshot().pcmDataCopy() == Data([0x04, 0x05]))
    }

    @Test func clearOverwritesStorageAndResetsChronology() {
        let ring = PCM16RingBuffer(capacitySamples: 3)
        ring.append(pcmData([10, 20, 30, 40]))

        ring.clear()

        #expect(ring.isStorageZeroed)
        ring.append(pcmData([50]))
        #expect(samples(from: ring.snapshot().pcmDataCopy()) == [50])
    }

    @Test func snapshotCanBeExplicitlyZeroized() {
        let snapshot = PCM16Snapshot(pcmData: pcmData([10, 20]))

        snapshot.zeroize()

        #expect(snapshot.isZeroized)
        #expect(snapshot.pcmDataCopy().isEmpty)
        #expect(snapshot.sampleCount == 0)
        #expect(snapshot.duration == 0)
    }

    @Test func snapshotProvidesScopedNormalizedFloatSamples() {
        let snapshot = PCM16Snapshot(pcmData: pcmData([-32_768, 0, 32_767]))

        let values = snapshot.withNormalizedFloatSamples { Array($0) }

        #expect(values == [-1, 0, Float32(32_767) / 32_768])
        #expect(snapshot.sampleCount == 3)
    }

    @Test func concurrentAppendsDoNotLoseOrSplitSamples() {
        let sampleTotal = 128
        let ring = PCM16RingBuffer(capacitySamples: sampleTotal)

        DispatchQueue.concurrentPerform(iterations: sampleTotal) { value in
            ring.append(pcmData([Int16(value)]))
        }

        let capturedSamples = samples(from: ring.snapshot().pcmDataCopy())
        #expect(capturedSamples.count == sampleTotal)
        #expect(Set(capturedSamples) == Set((0..<sampleTotal).map(Int16.init)))
    }

    @Test func wavEncoderWritesCanonicalRiffHeaderAndUnchangedPCM() throws {
        let sourcePCM = pcmData([0x1234, -2])
        let snapshot = PCM16Snapshot(pcmData: sourcePCM)

        let wav = try PCM16WAVEncoder.encode(snapshot)

        #expect(wav.count == PCM16WAVEncoder.headerByteCount + sourcePCM.count)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(readUInt32(wav, at: 4) == UInt32(36 + sourcePCM.count))
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: wav[12..<16], as: UTF8.self) == "fmt ")
        #expect(readUInt32(wav, at: 16) == 16)
        #expect(readUInt16(wav, at: 20) == 1)
        #expect(readUInt16(wav, at: 22) == 1)
        #expect(readUInt32(wav, at: 24) == 16_000)
        #expect(readUInt32(wav, at: 28) == 32_000)
        #expect(readUInt16(wav, at: 32) == 2)
        #expect(readUInt16(wav, at: 34) == 16)
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(readUInt32(wav, at: 40) == UInt32(sourcePCM.count))
        #expect(Data(wav[44...]) == sourcePCM)
    }

    @Test func wavEncoderProducesAValidHeaderForAnEmptySnapshot() throws {
        let wav = try PCM16WAVEncoder.encode(PCM16Snapshot(pcmData: Data()))

        #expect(wav.count == 44)
        #expect(readUInt32(wav, at: 4) == 36)
        #expect(readUInt32(wav, at: 40) == 0)
    }

    private func pcmData(_ samples: [Int16]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<Int16>.size)
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

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
