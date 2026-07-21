import AppKit
import Testing
@testable import VoiceInk

struct TimeShiftPresentationFoundationTests {
    @Test func projectionExposesOnlyCoarseLifecycleStates() {
        let disabled = TimeShiftStatusPresentation.project(
            capabilityEnabled: false,
            captureState: .armed(sessionID: UUID(), bufferedSampleCount: 123)
        )
        #expect(disabled.kind == .disabled)
        #expect(disabled.menuLabel == "Time-Shift: Off")
        #expect(!disabled.showsPulse)

        let unavailable = TimeShiftStatusPresentation.project(
            capabilityEnabled: true,
            captureState: .unavailable(.permissionDenied)
        )
        #expect(unavailable.kind == .unavailable)
        #expect(unavailable.menuLabel == "Time-Shift: Unavailable")
        #expect(!unavailable.showsPulse)

        let ready = TimeShiftStatusPresentation.project(
            capabilityEnabled: true,
            captureState: .unarmed
        )
        #expect(ready.kind == .ready)
        #expect(ready.menuLabel == "Time-Shift: Ready")
        #expect(!ready.showsPulse)

        let arming = TimeShiftStatusPresentation.project(
            capabilityEnabled: true,
            captureState: .arming(sessionID: UUID())
        )
        #expect(arming.kind == .arming)
        #expect(arming.showsPulse)

        let armed = TimeShiftStatusPresentation.project(
            capabilityEnabled: true,
            captureState: .armed(sessionID: UUID(), bufferedSampleCount: 160_000)
        )
        #expect(armed.kind == .armed)
        #expect(armed.menuLabel == "Time-Shift: Armed")
        #expect(armed.showsPulse)

        let capturing = TimeShiftStatusPresentation.project(
            capabilityEnabled: true,
            captureState: .capturing(sessionID: UUID(), requestID: UUID())
        )
        #expect(capturing.kind == .capturing)
        #expect(capturing.menuLabel == "Time-Shift: Capturing")
        #expect(capturing.showsPulse)

        let processing = TimeShiftStatusPresentation.project(
            capabilityEnabled: true,
            captureState: .processing(requestID: UUID(), sampleCount: 160_000)
        )
        #expect(processing.kind == .processing)
        #expect(processing.detailLabel.contains("microphone is no longer"))
        #expect(processing.showsPulse)
    }

    @Test func projectionNeverIncludesRuntimeIdentifiersOrRecordingContext() {
        let sessionID = UUID()
        let requestID = UUID()
        let presentation = TimeShiftStatusPresentation.project(
            capabilityEnabled: true,
            captureState: .capturing(sessionID: sessionID, requestID: requestID)
        )
        let visibleText = [
            presentation.menuLabel,
            presentation.statusLabel,
            presentation.detailLabel,
        ].joined(separator: " ")

        #expect(!visibleText.contains(sessionID.uuidString))
        #expect(!visibleText.contains(requestID.uuidString))
        #expect(!visibleText.localizedCaseInsensitiveContains("clipboard"))
        #expect(!visibleText.localizedCaseInsensitiveContains("destination"))
        #expect(!visibleText.localizedCaseInsensitiveContains("mode"))
    }

    @Test func enabledDisabledUnavailableReasonStillProjectsAsDisabled() {
        let presentation = TimeShiftStatusPresentation.project(
            capabilityEnabled: true,
            captureState: .unavailable(.disabled)
        )

        #expect(presentation.kind == .disabled)
        #expect(presentation.tone == .muted)
        #expect(!presentation.showsPulse)
    }

    @Test func pulseGeometryIsBottomCenteredWithinTheVisibleFrame() {
        let visibleFrame = CGRect(x: -1_440, y: 20, width: 1_440, height: 880)
        let frame = TimeShiftPulseMetrics.frame(
            in: visibleFrame,
            size: CGSize(width: 210, height: 42),
            bottomInset: 24
        )

        #expect(frame.midX == visibleFrame.midX)
        #expect(frame.minY == 44)
        #expect(frame.size == CGSize(width: 210, height: 42))
    }

    @Test @MainActor func hiddenStateSchedulesCleanupAfterBeginningDismissal() {
        let scheduler = ManualTimeShiftPulseScheduler()
        let surface = SpyTimeShiftPulseSurface()
        let manager = TimeShiftPulseWindowManager(
            scheduler: scheduler,
            dismissalDuration: 0.16,
            surfaceFactory: { surface }
        )

        manager.update(capabilityEnabled: true, captureState: .armed(
            sessionID: UUID(),
            bufferedSampleCount: 0
        ))
        manager.update(capabilityEnabled: true, captureState: .unarmed)

        #expect(surface.presentations.count == 1)
        #expect(surface.dismissalCount == 1)
        #expect(surface.closeCount == 0)
        #expect(scheduler.scheduledIntervals == [0.16])

        scheduler.runAll()
        #expect(surface.closeCount == 1)
    }

    @Test @MainActor func rearmingCancelsStaleCleanupAndReusesTheSurface() {
        let scheduler = ManualTimeShiftPulseScheduler()
        let surface = SpyTimeShiftPulseSurface()
        var factoryCount = 0
        let manager = TimeShiftPulseWindowManager(
            scheduler: scheduler,
            surfaceFactory: {
                factoryCount += 1
                return surface
            }
        )

        manager.update(capabilityEnabled: true, captureState: .armed(
            sessionID: UUID(),
            bufferedSampleCount: 0
        ))
        manager.update(capabilityEnabled: true, captureState: .unarmed)
        manager.update(capabilityEnabled: true, captureState: .armed(
            sessionID: UUID(),
            bufferedSampleCount: 10
        ))
        scheduler.runAll(includingCancelled: true)

        #expect(factoryCount == 1)
        #expect(surface.presentations.count == 2)
        #expect(surface.closeCount == 0)
    }

    @Test @MainActor func capturingUpdatesTheExistingPulseWithoutSchedulingCleanup() {
        let scheduler = ManualTimeShiftPulseScheduler()
        let surface = SpyTimeShiftPulseSurface()
        let manager = TimeShiftPulseWindowManager(
            scheduler: scheduler,
            surfaceFactory: { surface }
        )

        manager.update(capabilityEnabled: true, captureState: .armed(
            sessionID: UUID(),
            bufferedSampleCount: 160
        ))
        manager.update(capabilityEnabled: true, captureState: .capturing(
            sessionID: UUID(),
            requestID: UUID()
        ))

        #expect(surface.presentations.map(\.kind) == [.armed, .capturing])
        #expect(surface.dismissalCount == 0)
        #expect(scheduler.scheduledIntervals.isEmpty)
    }

    @Test @MainActor func shutdownCancelsPendingCleanupAndClosesImmediatelyExactlyOnce() {
        let scheduler = ManualTimeShiftPulseScheduler()
        let surface = SpyTimeShiftPulseSurface()
        let manager = TimeShiftPulseWindowManager(
            scheduler: scheduler,
            surfaceFactory: { surface }
        )

        manager.update(capabilityEnabled: true, captureState: .armed(
            sessionID: UUID(),
            bufferedSampleCount: 0
        ))
        manager.update(capabilityEnabled: false, captureState: .unarmed)
        manager.shutdown()
        scheduler.runAll(includingCancelled: true)

        #expect(surface.dismissalCount == 1)
        #expect(surface.closeCount == 1)
    }

    @Test @MainActor func panelIsAlwaysNonKeyAndMouseTransparent() {
        let panel = TimeShiftPulsePanel(
            contentRect: CGRect(origin: .zero, size: TimeShiftPulseMetrics.size)
        )

        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.ignoresMouseEvents)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        panel.close()
    }
}

@MainActor
private final class SpyTimeShiftPulseSurface: TimeShiftPulseSurface {
    private(set) var presentations: [TimeShiftStatusPresentation] = []
    private(set) var dismissalCount = 0
    private(set) var closeCount = 0

    func present(_ presentation: TimeShiftStatusPresentation) {
        presentations.append(presentation)
    }

    func beginDismissal() {
        dismissalCount += 1
    }

    func close() {
        closeCount += 1
    }
}

@MainActor
private final class ManualTimeShiftPulseScheduler: TimeShiftPulseScheduling {
    private struct Entry {
        let interval: TimeInterval
        let action: @MainActor () -> Void
        var isCancelled: Bool
    }

    private var entries: [UUID: Entry] = [:]
    private(set) var scheduledIntervals: [TimeInterval] = []

    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> TimeShiftScheduledCancellation {
        let id = UUID()
        entries[id] = Entry(interval: interval, action: action, isCancelled: false)
        scheduledIntervals.append(interval)

        return TimeShiftScheduledCancellation { [weak self] in
            guard var entry = self?.entries[id] else { return }
            entry.isCancelled = true
            self?.entries[id] = entry
        }
    }

    func runAll(includingCancelled: Bool = false) {
        let pending = entries.values
        entries.removeAll()
        for entry in pending where includingCancelled || !entry.isCancelled {
            entry.action()
        }
    }
}
