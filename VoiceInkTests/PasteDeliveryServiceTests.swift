import Foundation
import Testing
@testable import VoiceInk

struct PasteDeliveryServiceTests {
    @MainActor
    @Test func preparationSnapshotsExactLicensedAndTrailingSpaceText() {
        let service = PasteDeliveryService(
            dependencies: .init(
                usageRestrictionMessage: { "Usage limit reached" },
                shouldAppendTrailingSpace: { true },
                playStopSound: {},
                postPasteCommand: { _ in .commandPosted },
                waitBeforeAutoSend: {},
                performAutoSend: { _ in }
            )
        )

        let payload = service.prepare(
            text: "Final transcript",
            output: OutputRuntimeConfiguration(
                mode: nil,
                outputMode: .paste,
                autoSendKey: .commandEnter,
                customCommand: nil
            )
        )

        #expect(payload.displayText == "Final transcript")
        #expect(payload.pastedText == "Usage limit reached\n\nFinal transcript ")
        #expect(payload.autoSendKey == .commandEnter)
    }

    @MainActor
    @Test func deliveryDismissesBeforePasteAndAutoSendsAfterSuccessfulCommand() async {
        var events: [String] = []
        let service = PasteDeliveryService(
            dependencies: .init(
                usageRestrictionMessage: { nil },
                shouldAppendTrailingSpace: { false },
                playStopSound: { events.append("sound") },
                postPasteCommand: { text in
                    events.append("paste:\(text)")
                    return .commandPosted
                },
                waitBeforeAutoSend: { events.append("wait") },
                performAutoSend: { key in events.append("send:\(key.rawValue)") }
            )
        )
        let payload = PreparedPastePayload(
            displayText: "Result",
            pastedText: "Exact result",
            autoSendKey: .enter
        )

        let outcome = await service.deliver(
            payload,
            dismiss: { events.append("dismiss") },
            playStopSound: false
        )

        #expect(outcome == .commandPosted)
        #expect(events == ["dismiss", "paste:Exact result", "wait", "send:enter"])
    }

    @MainActor
    @Test func failedPasteCommandNeverAutoSends() async {
        var events: [String] = []
        let service = PasteDeliveryService(
            dependencies: .init(
                usageRestrictionMessage: { nil },
                shouldAppendTrailingSpace: { false },
                playStopSound: { events.append("sound") },
                postPasteCommand: { _ in
                    events.append("paste")
                    return .commandNotPosted
                },
                waitBeforeAutoSend: { events.append("wait") },
                performAutoSend: { _ in events.append("send") }
            )
        )
        let payload = PreparedPastePayload(
            displayText: "Result",
            pastedText: "Result",
            autoSendKey: .enter
        )

        let outcome = await service.deliver(
            payload,
            dismiss: { events.append("dismiss") },
            playStopSound: true
        )

        #expect(outcome == .commandNotPosted)
        #expect(events == ["sound", "dismiss", "paste"])
    }

    @MainActor
    @Test func copyUsesExactPastePayloadWithoutPostingOrAutoSending() {
        var events: [String] = []
        let service = PasteDeliveryService(
            dependencies: .init(
                usageRestrictionMessage: { nil },
                shouldAppendTrailingSpace: { false },
                playStopSound: { events.append("sound") },
                postPasteCommand: { _ in
                    events.append("paste")
                    return .commandPosted
                },
                waitBeforeAutoSend: { events.append("wait") },
                performAutoSend: { _ in events.append("send") },
                copyToClipboard: { text in
                    events.append("copy:\(text)")
                    return true
                }
            )
        )
        let payload = PreparedPastePayload(
            displayText: "Displayed result",
            pastedText: "Licensed exact result ",
            autoSendKey: .enter
        )

        #expect(service.copy(payload))
        #expect(events == ["copy:Licensed exact result "])
    }
}
