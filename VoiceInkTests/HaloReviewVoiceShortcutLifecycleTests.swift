import Testing
@testable import VoiceInk

struct HaloReviewVoiceShortcutLifecycleTests {
    @Test func toggleStartsOnFirstDownAndStopsOnSecondDown() {
        var lifecycle = HaloReviewVoiceShortcutLifecycle()

        let firstDown = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 1,
            mode: .toggle,
            isReviewAvailable: true
        )
        #expect(firstDown == .handled(.startCapture))
        #expect(lifecycle.isCaptureActive)
        let firstUp = lifecycle.handleKeyUp(
            action: .primaryRecording,
            eventTime: 1.1,
            mode: .toggle,
            isReviewAvailable: true
        )
        #expect(firstUp == .handled())
        #expect(lifecycle.isCaptureActive)

        let secondDown = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 2,
            mode: .toggle,
            isReviewAvailable: true
        )
        #expect(secondDown == .handled(.stopCapture))
        #expect(!lifecycle.isCaptureActive)
        let secondUp = lifecycle.handleKeyUp(
            action: .primaryRecording,
            eventTime: 2.1,
            mode: .toggle,
            isReviewAvailable: true
        )
        #expect(secondUp == .handled())
    }

    @Test func pushToTalkStartsOnDownAndStopsOnUp() {
        var lifecycle = HaloReviewVoiceShortcutLifecycle()

        let down = lifecycle.handleKeyDown(
            action: .secondaryRecording,
            eventTime: 3,
            mode: .pushToTalk,
            isReviewAvailable: true
        )
        #expect(down == .handled(.startCapture))
        let up = lifecycle.handleKeyUp(
            action: .secondaryRecording,
            eventTime: 3.2,
            mode: .pushToTalk,
            isReviewAvailable: true
        )
        #expect(up == .handled(.stopCapture))
        #expect(!lifecycle.isCaptureActive)
    }

    @Test func shortHybridReleaseBecomesHandsFreeUntilNextRecordingShortcut() {
        var lifecycle = HaloReviewVoiceShortcutLifecycle()

        let down = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 4,
            mode: .hybrid,
            isReviewAvailable: true
        )
        #expect(down == .handled(.startCapture))
        let up = lifecycle.handleKeyUp(
            action: .primaryRecording,
            eventTime: 4.49,
            mode: .hybrid,
            isReviewAvailable: true
        )
        #expect(up == .handled())
        #expect(lifecycle.isCaptureActive)

        let stop = lifecycle.handleKeyDown(
            action: .secondaryRecording,
            eventTime: 5,
            mode: .pushToTalk,
            isReviewAvailable: true
        )
        #expect(stop == .handled(.stopCapture))
        #expect(!lifecycle.isCaptureActive)
    }

    @Test func longHybridReleaseStopsCaptureAtThreshold() {
        var lifecycle = HaloReviewVoiceShortcutLifecycle()

        _ = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 10,
            mode: .hybrid,
            isReviewAvailable: true
        )

        let up = lifecycle.handleKeyUp(
            action: .primaryRecording,
            eventTime: 10.5,
            mode: .hybrid,
            isReviewAvailable: true
        )
        #expect(up == .handled(.stopCapture))
        #expect(!lifecycle.isCaptureActive)
    }

    @Test func repeatedAndCompetingKeyDownEventsAreHandledWithoutNewCapture() {
        var lifecycle = HaloReviewVoiceShortcutLifecycle()

        _ = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 20,
            mode: .pushToTalk,
            isReviewAvailable: true
        )

        let repeatedDown = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 20.1,
            mode: .pushToTalk,
            isReviewAvailable: true
        )
        #expect(repeatedDown == .handled())
        let competingDown = lifecycle.handleKeyDown(
            action: .secondaryRecording,
            eventTime: 20.2,
            mode: .toggle,
            isReviewAvailable: true
        )
        #expect(competingDown == .handled())
        #expect(lifecycle.isCaptureActive)
    }

    @Test func shortcutInterruptionCancelsOnlyItsActiveCapture() {
        var lifecycle = HaloReviewVoiceShortcutLifecycle()

        _ = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 30,
            mode: .pushToTalk,
            isReviewAvailable: true
        )
        let unrelatedInterruption = lifecycle.handleInterruption(
            action: .secondaryRecording,
            isReviewAvailable: true
        )
        #expect(unrelatedInterruption == .handled())
        #expect(lifecycle.isCaptureActive)
        let activeInterruption = lifecycle.handleInterruption(
            action: .primaryRecording,
            isReviewAvailable: true
        )
        #expect(activeInterruption == .handled(.cancelCapture))
        #expect(!lifecycle.isCaptureActive)
    }

    @Test func unavailableReviewAndUnrelatedActionsFallThrough() {
        var lifecycle = HaloReviewVoiceShortcutLifecycle()

        let unavailable = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 40,
            mode: .toggle,
            isReviewAvailable: false
        )
        #expect(unavailable == .unhandled)
        let unrelated = lifecycle.handleKeyDown(
            action: .pasteLastTranscription,
            eventTime: 41,
            mode: .toggle,
            isReviewAvailable: true
        )
        #expect(unrelated == .unhandled)
        #expect(!lifecycle.isCaptureActive)
    }

    @Test func endingReviewClearsHandsFreeState() {
        var lifecycle = HaloReviewVoiceShortcutLifecycle()

        _ = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 50,
            mode: .toggle,
            isReviewAvailable: true
        )
        _ = lifecycle.handleKeyUp(
            action: .primaryRecording,
            eventTime: 50.1,
            mode: .toggle,
            isReviewAvailable: true
        )

        let unavailable = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 51,
            mode: .toggle,
            isReviewAvailable: false
        )
        #expect(unavailable == .unhandled)
        #expect(!lifecycle.isCaptureActive)
    }

    @Test func mouseStartedCaptureIsStoppedByRecordingShortcut() {
        var lifecycle = HaloReviewVoiceShortcutLifecycle()
        lifecycle.synchronizeCapture(isActive: true)

        let down = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 60,
            mode: .hybrid,
            isReviewAvailable: true
        )
        #expect(down == .handled(.stopCapture))
        #expect(!lifecycle.isCaptureActive)
    }

    @Test func mouseStoppedCaptureDoesNotEmitASecondStopOnKeyUp() {
        var lifecycle = HaloReviewVoiceShortcutLifecycle()
        _ = lifecycle.handleKeyDown(
            action: .primaryRecording,
            eventTime: 70,
            mode: .pushToTalk,
            isReviewAvailable: true
        )
        lifecycle.synchronizeCapture(isActive: false)

        let up = lifecycle.handleKeyUp(
            action: .primaryRecording,
            eventTime: 70.2,
            mode: .pushToTalk,
            isReviewAvailable: true
        )
        #expect(up == .handled())
        #expect(!lifecycle.isCaptureActive)
    }
}
