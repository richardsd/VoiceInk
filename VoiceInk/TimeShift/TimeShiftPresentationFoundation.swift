import AppKit
import SwiftUI

/// A privacy-safe projection of Time-Shift's runtime state for menus and the
/// compact armed/capture pulse. Runtime identifiers and recording context are
/// intentionally absent from this value.
struct TimeShiftStatusPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case disabled
        case unavailable
        case ready
        case arming
        case armed
        case capturing
        case processing
    }

    enum Tone: Equatable, Sendable {
        case muted
        case accent
        case warning
    }

    let kind: Kind
    let menuLabel: String
    let statusLabel: String
    let detailLabel: String
    let systemImage: String
    let tone: Tone
    let showsPulse: Bool

    static func project(
        capabilityEnabled: Bool,
        captureState: TimeShiftCaptureState
    ) -> Self {
        guard capabilityEnabled else {
            return Self(
                kind: .disabled,
                menuLabel: String(localized: "Time-Shift: Off"),
                statusLabel: String(localized: "Time-Shift disabled"),
                detailLabel: String(localized: "Enable it in Settings > Halo"),
                systemImage: "waveform.slash",
                tone: .muted,
                showsPulse: false
            )
        }

        switch captureState {
        case let .unavailable(reason):
            if reason == .disabled {
                return Self(
                    kind: .disabled,
                    menuLabel: String(localized: "Time-Shift: Off"),
                    statusLabel: String(localized: "Time-Shift disabled"),
                    detailLabel: String(localized: "Enable it in Settings > Halo"),
                    systemImage: "waveform.slash",
                    tone: .muted,
                    showsPulse: false
                )
            }

            return Self(
                kind: .unavailable,
                menuLabel: String(localized: "Time-Shift: Unavailable"),
                statusLabel: String(localized: "Time-Shift unavailable"),
                detailLabel: unavailableDetail(for: reason),
                systemImage: "exclamationmark.waveform",
                tone: .warning,
                showsPulse: false
            )

        case .unarmed:
            return Self(
                kind: .ready,
                menuLabel: String(localized: "Time-Shift: Ready"),
                statusLabel: String(localized: "Time-Shift ready"),
                detailLabel: String(localized: "Arm to remember the last 15 seconds"),
                systemImage: "waveform",
                tone: .muted,
                showsPulse: false
            )

        case .arming:
            return Self(
                kind: .arming,
                menuLabel: String(localized: "Time-Shift: Arming"),
                statusLabel: String(localized: "Arming Time-Shift"),
                detailLabel: String(localized: "Starting the private memory buffer"),
                systemImage: "record.circle",
                tone: .accent,
                showsPulse: true
            )

        case .armed:
            return Self(
                kind: .armed,
                menuLabel: String(localized: "Time-Shift: Armed"),
                statusLabel: String(localized: "Time-Shift armed"),
                detailLabel: String(localized: "Listening locally - 15 seconds in memory"),
                systemImage: "record.circle",
                tone: .accent,
                showsPulse: true
            )

        case .capturing:
            return Self(
                kind: .capturing,
                menuLabel: String(localized: "Time-Shift: Capturing"),
                statusLabel: String(localized: "Capturing last 15 seconds"),
                detailLabel: String(localized: "Preparing Halo review"),
                systemImage: "waveform.badge.magnifyingglass",
                tone: .accent,
                showsPulse: true
            )

        case .processing:
            return Self(
                kind: .processing,
                menuLabel: String(localized: "Time-Shift: Processing"),
                statusLabel: String(localized: "Preparing Halo review"),
                detailLabel: String(localized: "The microphone is no longer in use"),
                systemImage: "waveform.badge.magnifyingglass",
                tone: .accent,
                showsPulse: true
            )
        }
    }

    private static func unavailableDetail(for reason: TimeShiftUnavailableReason) -> String {
        switch reason {
        case .disabled:
            return String(localized: "Enable it in Settings > Halo")
        case .permissionDenied:
            return String(localized: "Microphone access is unavailable")
        case .audioDeviceChanged:
            return String(localized: "Audio device changed - arm again")
        case .microphoneInUse:
            return String(localized: "The microphone is being used by another VoiceInk capture")
        case .audioCaptureFailed:
            return String(localized: "The memory-only audio capture could not start")
        case .unsupportedModel:
            return String(localized: "The selected transcription model cannot use memory-only audio")
        case .systemSleeping, .screenLocked, .terminating:
            return String(localized: "Arm again when VoiceInk is available")
        }
    }
}

enum TimeShiftPulseMetrics {
    static let size = CGSize(width: 210, height: 42)
    static let bottomInset: CGFloat = 24
    static let dismissalDuration: TimeInterval = 0.16

    static func frame(
        in visibleFrame: CGRect,
        size: CGSize = size,
        bottomInset: CGFloat = bottomInset
    ) -> CGRect {
        CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + bottomInset,
            width: size.width,
            height: size.height
        )
    }
}

enum TimeShiftPulseTransitionPolicy {
    static func duration(
        _ preferredDuration: TimeInterval,
        reduceMotion: Bool
    ) -> TimeInterval {
        reduceMotion ? 0 : max(0, preferredDuration)
    }
}

@MainActor
struct TimeShiftScheduledCancellation {
    private let cancelAction: @MainActor () -> Void

    init(_ cancelAction: @escaping @MainActor () -> Void) {
        self.cancelAction = cancelAction
    }

    func cancel() {
        cancelAction()
    }
}

@MainActor
protocol TimeShiftPulseScheduling: AnyObject {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> TimeShiftScheduledCancellation
}

@MainActor
final class TimeShiftPulseTaskScheduler: TimeShiftPulseScheduling {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> TimeShiftScheduledCancellation {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(max(0, interval)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }

        return TimeShiftScheduledCancellation {
            task.cancel()
        }
    }
}

@MainActor
protocol TimeShiftPulseSurface: AnyObject {
    func present(_ presentation: TimeShiftStatusPresentation)
    func beginDismissal()
    func close()
}

/// Owns the pulse lifetime independently from Time-Shift's capture state
/// machine. Hiding begins immediately; destruction is delayed only long enough
/// for the visual fade, and can be deterministically cancelled by a new state.
@MainActor
final class TimeShiftPulseWindowManager {
    typealias SurfaceFactory = @MainActor () -> any TimeShiftPulseSurface

    private let scheduler: any TimeShiftPulseScheduling
    private let surfaceFactory: SurfaceFactory
    private let dismissalDuration: TimeInterval

    private var surface: (any TimeShiftPulseSurface)?
    private var pendingCleanup: TimeShiftScheduledCancellation?
    private var presentationGeneration = 0

    init(
        scheduler: (any TimeShiftPulseScheduling)? = nil,
        dismissalDuration: TimeInterval = TimeShiftPulseMetrics.dismissalDuration,
        surfaceFactory: @escaping SurfaceFactory = { TimeShiftPulseAppKitSurface() }
    ) {
        self.scheduler = scheduler ?? TimeShiftPulseTaskScheduler()
        self.dismissalDuration = max(0, dismissalDuration)
        self.surfaceFactory = surfaceFactory
    }

    func update(
        capabilityEnabled: Bool,
        captureState: TimeShiftCaptureState
    ) {
        update(
            TimeShiftStatusPresentation.project(
                capabilityEnabled: capabilityEnabled,
                captureState: captureState
            )
        )
    }

    func update(_ presentation: TimeShiftStatusPresentation) {
        presentationGeneration += 1
        let generation = presentationGeneration
        pendingCleanup?.cancel()
        pendingCleanup = nil

        guard presentation.showsPulse else {
            beginDismissal(generation: generation)
            return
        }

        let surface = surface ?? surfaceFactory()
        self.surface = surface
        surface.present(presentation)
    }

    /// Application shutdown and privacy-sensitive lifecycle teardown use an
    /// immediate close rather than waiting for a visual transition.
    func shutdown() {
        presentationGeneration += 1
        pendingCleanup?.cancel()
        pendingCleanup = nil
        surface?.close()
        surface = nil
    }

    private func beginDismissal(generation: Int) {
        guard let surface else { return }

        surface.beginDismissal()
        pendingCleanup = scheduler.schedule(after: dismissalDuration) { [weak self, weak surface] in
            guard let self,
                self.presentationGeneration == generation,
                let surface,
                self.surface === surface
            else {
                return
            }

            surface.close()
            self.surface = nil
            self.pendingCleanup = nil
        }
    }
}

final class TimeShiftPulsePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = .statusBar + 2
        hidesOnDeactivate = false
        canHide = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        ignoresMouseEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false
    }
}

@MainActor
final class TimeShiftPulseAppKitSurface: TimeShiftPulseSurface {
    private let panel: TimeShiftPulsePanel
    private let hostingController: NSHostingController<TimeShiftPulseView>
    private let screenProvider: @MainActor () -> NSScreen?
    private let reduceMotionProvider: @MainActor () -> Bool

    init(
        screenProvider: @escaping @MainActor () -> NSScreen? = {
            NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        },
        reduceMotionProvider: @escaping @MainActor () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.screenProvider = screenProvider
        self.reduceMotionProvider = reduceMotionProvider
        let initialPresentation = TimeShiftStatusPresentation.project(
            capabilityEnabled: true,
            captureState: .unarmed
        )
        hostingController = NSHostingController(
            rootView: TimeShiftPulseView(presentation: initialPresentation)
        )
        panel = TimeShiftPulsePanel(
            contentRect: CGRect(origin: .zero, size: TimeShiftPulseMetrics.size)
        )
        panel.contentViewController = hostingController
    }

    func present(_ presentation: TimeShiftStatusPresentation) {
        hostingController.rootView = TimeShiftPulseView(presentation: presentation)
        if let screen = screenProvider() {
            panel.setFrame(
                TimeShiftPulseMetrics.frame(in: screen.visibleFrame),
                display: true
            )
        }

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }

        setAlphaValue(
            1,
            duration: 0.14,
            timingFunction: CAMediaTimingFunction(name: .easeOut)
        )
    }

    func beginDismissal() {
        setAlphaValue(
            0,
            duration: TimeShiftPulseMetrics.dismissalDuration,
            timingFunction: CAMediaTimingFunction(name: .easeIn)
        )
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }

    private func setAlphaValue(
        _ alphaValue: CGFloat,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction
    ) {
        let resolvedDuration = TimeShiftPulseTransitionPolicy.duration(
            duration,
            reduceMotion: reduceMotionProvider()
        )
        guard resolvedDuration > 0 else {
            panel.alphaValue = alphaValue
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = resolvedDuration
            context.timingFunction = timingFunction
            panel.animator().alphaValue = alphaValue
        }
    }
}

struct TimeShiftPulseView: View {
    let presentation: TimeShiftStatusPresentation

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.2))
                Circle()
                    .fill(accentColor)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.statusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .lineLimit(1)
                Text(presentation.detailLabel)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: TimeShiftPulseMetrics.size.width, height: TimeShiftPulseMetrics.size.height)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(red: 0.07, green: 0.075, blue: 0.08).opacity(0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.75)
                }
        )
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.statusLabel)
        .accessibilityValue(presentation.detailLabel)
    }

    private var accentColor: Color {
        switch presentation.tone {
        case .muted:
            return Color.white.opacity(0.52)
        case .accent:
            return Color(red: 1, green: 0.32, blue: 0.27)
        case .warning:
            return Color.orange
        }
    }
}
