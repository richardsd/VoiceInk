import Foundation
import Testing
@testable import VoiceInk

private actor DenyingRecorderAudioCaptureLeaseCoordinator: AudioCaptureLeaseCoordinating {
    private(set) var requestedOwners: [AudioCaptureLeaseOwner] = []
    private(set) var releasedLeases: [AudioCaptureLease] = []

    func acquire(for owner: AudioCaptureLeaseOwner) async -> AudioCaptureLeaseAcquisition {
        requestedOwners.append(owner)
        return .denied(.occupied(by: .timeShift))
    }

    func release(_ lease: AudioCaptureLease) async -> Bool {
        releasedLeases.append(lease)
        return true
    }
}

@MainActor
struct RecorderAudioCaptureLeaseTests {
    @Test func normalRecordingDenialOccursBeforeHardwareStartAndNeedsNoRelease() async {
        let coordinator = DenyingRecorderAudioCaptureLeaseCoordinator()
        let recorder = Recorder(
            audioCaptureLeaseCoordinator: coordinator,
            prepareOnInitialization: false
        )

        do {
            try await recorder.startRecording(
                toOutputFile: URL(fileURLWithPath: "/tmp/never-created.wav")
            )
            Issue.record("Expected the occupied microphone lease to reject recording")
        } catch let error as Recorder.RecorderError {
            #expect(error == .audioCaptureUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await coordinator.requestedOwners == [.normalRecording])
        #expect(await coordinator.releasedLeases.isEmpty)
    }
}
