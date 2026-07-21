import AppKit
import Foundation

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(into store: RecordingContextSnapshotStore) -> [Task<Void, Never>] {
        [
            Task { @MainActor in
                store.updateClipboardText(NSPasteboard.general.string(forType: .string))
            },
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                let selectedText = await SelectedTextService.fetchSelectedText()
                guard !Task.isCancelled else { return }
                store.updateSelectedText(selectedText)
            },
            Task { @MainActor in
                guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
                let screenCaptureService = ScreenCaptureService()
                let screenText = await screenCaptureService.captureAndExtractText()
                guard !Task.isCancelled else { return }
                store.updateScreenText(screenText)
            },
        ]
    }

    /// Captures only the context sources explicitly enabled by the frozen
    /// Mode. Time-Shift calls this after the user invokes Capture, never while
    /// the rolling memory buffer is merely armed.
    static func captureSnapshot(
        useClipboard: Bool,
        useSelectedText: Bool,
        useScreen: Bool
    ) async -> RecordingContextSnapshot? {
        guard useClipboard || useSelectedText || useScreen else { return nil }

        let clipboardText = useClipboard
            ? NSPasteboard.general.string(forType: .string)
            : nil
        async let selectedText: String? = {
            guard useSelectedText, !Task.isCancelled else { return nil }
            return await SelectedTextService.fetchSelectedText()
        }()
        async let screenText: String? = {
            guard useScreen,
                CGPreflightScreenCaptureAccess(),
                !Task.isCancelled
            else {
                return nil
            }
            return await ScreenCaptureService().captureAndExtractText()
        }()

        let store = RecordingContextSnapshotStore()
        store.updateClipboardText(clipboardText)
        store.updateSelectedText(await selectedText)
        store.updateScreenText(await screenText)
        return store.snapshot
    }
}
