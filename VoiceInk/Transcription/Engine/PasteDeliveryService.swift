import Foundation

struct PreparedPastePayload: Equatable {
    /// The user-facing result before licensing and paste-only whitespace are applied.
    let displayText: String

    /// The exact immutable text that will be written to the pasteboard.
    let pastedText: String

    /// The key to post after a successful paste command.
    let autoSendKey: AutoSendKey
}

enum PasteDeliveryOutcome: Equatable {
    case commandPosted
    case commandNotPosted
}

@MainActor
protocol PasteDeliveryServicing: AnyObject {
    func prepare(text: String, output: OutputRuntimeConfiguration) -> PreparedPastePayload

    @discardableResult
    func deliver(
        _ payload: PreparedPastePayload,
        dismiss: () async -> Void,
        playStopSound: Bool
    ) async -> PasteDeliveryOutcome

    /// Preserves VoiceInk's existing fire-and-return behavior for Mini, Notch,
    /// and Halo's event-tap fallback while sharing the same exact payload path.
    func deliverImmediately(
        _ payload: PreparedPastePayload,
        dismiss: () async -> Void,
        playStopSound: Bool
    ) async

    /// Copies the exact immutable paste payload. It deliberately does not
    /// consume a review, post Cmd-V, or execute the configured auto-send key.
    @discardableResult
    func copy(_ payload: PreparedPastePayload) -> Bool

    func notifyReviewReady()
}

/// Owns all paste-only transformations and side effects so immediate delivery and
/// approved Halo reviews execute the same payload in the same order.
@MainActor
final class PasteDeliveryService: PasteDeliveryServicing {
    struct Dependencies {
        let usageRestrictionMessage: () -> String?
        let shouldAppendTrailingSpace: () -> Bool
        let playStopSound: () -> Void
        let postPasteCommand: (String) async -> PasteDeliveryOutcome
        let waitBeforeAutoSend: () async -> Void
        let performAutoSend: (AutoSendKey) -> Void
        let copyToClipboard: (String) -> Bool

        init(
            usageRestrictionMessage: @escaping () -> String?,
            shouldAppendTrailingSpace: @escaping () -> Bool,
            playStopSound: @escaping () -> Void,
            postPasteCommand: @escaping (String) async -> PasteDeliveryOutcome,
            waitBeforeAutoSend: @escaping () async -> Void,
            performAutoSend: @escaping (AutoSendKey) -> Void,
            copyToClipboard: @escaping (String) -> Bool = ClipboardManager.copyToClipboard
        ) {
            self.usageRestrictionMessage = usageRestrictionMessage
            self.shouldAppendTrailingSpace = shouldAppendTrailingSpace
            self.playStopSound = playStopSound
            self.postPasteCommand = postPasteCommand
            self.waitBeforeAutoSend = waitBeforeAutoSend
            self.performAutoSend = performAutoSend
            self.copyToClipboard = copyToClipboard
        }

        @MainActor static let live = Dependencies(
            usageRestrictionMessage: {
                LicenseViewModel().usageRestrictionMessage
            },
            shouldAppendTrailingSpace: {
                UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
            },
            playStopSound: {
                SoundManager.shared.playStopSound()
            },
            postPasteCommand: { text in
                let result = await CursorPaster.pasteAtCursorAndWaitUntilPosted(text)
                return result.didPostPasteCommand ? .commandPosted : .commandNotPosted
            },
            waitBeforeAutoSend: {
                try? await Task.sleep(nanoseconds: 500_000_000)
            },
            performAutoSend: { autoSendKey in
                CursorPaster.performAutoSend(autoSendKey)
            },
            copyToClipboard: { text in
                ClipboardManager.copyToClipboard(text)
            }
        )
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies? = nil) {
        self.dependencies = dependencies ?? .live
    }

    func prepare(text: String, output: OutputRuntimeConfiguration) -> PreparedPastePayload {
        var pastedText = text
        if let restrictionMessage = dependencies.usageRestrictionMessage() {
            pastedText = """
                \(restrictionMessage)
                \n\(pastedText)
                """
        }

        if dependencies.shouldAppendTrailingSpace() {
            pastedText += " "
        }

        return PreparedPastePayload(
            displayText: text,
            pastedText: pastedText,
            autoSendKey: output.outputMode == .paste ? output.autoSendKey : .none
        )
    }

    @discardableResult
    func deliver(
        _ payload: PreparedPastePayload,
        dismiss: () async -> Void,
        playStopSound: Bool = true
    ) async -> PasteDeliveryOutcome {
        if playStopSound {
            dependencies.playStopSound()
        }

        // VoiceInk must yield focus to the destination application before posting Cmd-V.
        await dismiss()

        return await postAndAutoSend(payload)
    }

    func deliverImmediately(
        _ payload: PreparedPastePayload,
        dismiss: () async -> Void,
        playStopSound: Bool = true
    ) async {
        if playStopSound {
            dependencies.playStopSound()
        }

        await dismiss()

        Task { @MainActor [self] in
            _ = await postAndAutoSend(payload)
        }
    }

    private func postAndAutoSend(_ payload: PreparedPastePayload) async -> PasteDeliveryOutcome {
        let outcome = await dependencies.postPasteCommand(payload.pastedText)
        guard outcome == .commandPosted, payload.autoSendKey.isEnabled else {
            return outcome
        }

        await dependencies.waitBeforeAutoSend()
        dependencies.performAutoSend(payload.autoSendKey)
        return outcome
    }

    @discardableResult
    func copy(_ payload: PreparedPastePayload) -> Bool {
        dependencies.copyToClipboard(payload.pastedText)
    }

    func notifyReviewReady() {
        dependencies.playStopSound()
    }
}
