import Testing
@testable import VoiceInk

struct RecorderPanelRoutingTests {
    @Test func haloIsEffectiveOnlyForPasteOutput() {
        #expect(
            RecorderPanelRouting.effectiveStyle(
                selectedStyle: .halo,
                outputMode: .paste
            ) == .halo
        )
        #expect(
            RecorderPanelRouting.effectiveStyle(
                selectedStyle: .halo,
                outputMode: .respond
            ) == .mini
        )
        #expect(
            RecorderPanelRouting.effectiveStyle(
                selectedStyle: .halo,
                outputMode: .customCommand
            ) == .mini
        )
    }

    @Test func existingRecorderStylesAreNeverRemapped() {
        for outputMode in ModeOutputMode.allCases {
            #expect(
                RecorderPanelRouting.effectiveStyle(
                    selectedStyle: .mini,
                    outputMode: outputMode
                ) == .mini
            )
            #expect(
                RecorderPanelRouting.effectiveStyle(
                    selectedStyle: .notch,
                    outputMode: outputMode
                ) == .notch
            )
        }
    }

    @MainActor
    @Test func globalRecordingShortcutsAreBlockedDuringReview() {
        #expect(RecordingShortcutManager.canHandleShortcutAction(for: .recording))
        #expect(!RecordingShortcutManager.canHandleShortcutAction(for: .reviewing))
    }
}
