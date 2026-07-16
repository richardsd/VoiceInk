import Foundation

enum ShortcutAction: Hashable {
    case primaryRecording
    case secondaryRecording
    case pasteLastTranscription
    case pasteLastEnhancement
    case retryLastTranscription
    case cancelRecorder
    case openHistoryWindow
    case quickAddToDictionary
    case mode(UUID)
    case recorderPanelEscape
    case recorderPanelApply
    case recorderPanelToggleHaloDelivery
    case recorderPanelReviewFinal
    case recorderPanelReviewChanges
    case recorderPanelReviewOriginal
    case recorderPanelPreviousRevision
    case recorderPanelNextRevision
    case recorderPanelMode(Int)

    var userDefaultsKey: String {
        "Shortcut_\(storageName)"
    }

    var isStored: Bool {
        switch self {
        case .recorderPanelEscape,
            .recorderPanelApply,
            .recorderPanelToggleHaloDelivery,
            .recorderPanelReviewFinal,
            .recorderPanelReviewChanges,
            .recorderPanelReviewOriginal,
            .recorderPanelPreviousRevision,
            .recorderPanelNextRevision,
            .recorderPanelMode:
            return false
        default:
            return true
        }
    }

    var storageName: String {
        switch self {
        case .primaryRecording:
            return "primaryRecording"
        case .secondaryRecording:
            return "secondaryRecording"
        case .pasteLastTranscription:
            return "pasteLastTranscription"
        case .pasteLastEnhancement:
            return "pasteLastEnhancement"
        case .retryLastTranscription:
            return "retryLastTranscription"
        case .cancelRecorder:
            return "cancelRecorder"
        case .openHistoryWindow:
            return "openHistoryWindow"
        case .quickAddToDictionary:
            return "quickAddToDictionary"
        case .mode(let id):
            return "mode_\(id.uuidString)"
        case .recorderPanelEscape:
            return "recorderPanelEscape"
        case .recorderPanelApply:
            return "recorderPanelApply"
        case .recorderPanelToggleHaloDelivery:
            return "recorderPanelToggleHaloDelivery"
        case .recorderPanelReviewFinal:
            return "recorderPanelReviewFinal"
        case .recorderPanelReviewChanges:
            return "recorderPanelReviewChanges"
        case .recorderPanelReviewOriginal:
            return "recorderPanelReviewOriginal"
        case .recorderPanelPreviousRevision:
            return "recorderPanelPreviousRevision"
        case .recorderPanelNextRevision:
            return "recorderPanelNextRevision"
        case .recorderPanelMode(let index):
            return "recorderPanelMode_\(index)"
        }
    }

    var displayName: String {
        switch self {
        case .primaryRecording:
            return String(localized: "Primary Shortcut")
        case .secondaryRecording:
            return String(localized: "Secondary Shortcut")
        case .pasteLastTranscription:
            return String(localized: "Paste Last Transcription")
        case .pasteLastEnhancement:
            return String(localized: "Paste Last Enhanced Transcription")
        case .retryLastTranscription:
            return String(localized: "Retry Last Transcription")
        case .cancelRecorder:
            return String(localized: "Cancel Recording")
        case .openHistoryWindow:
            return String(localized: "Open History Window")
        case .quickAddToDictionary:
            return String(localized: "Quick Add to Dictionary")
        case .mode(let id):
            if let config = ModeManager.shared.getConfiguration(with: id) {
                return String(format: String(localized: "%@ Mode"), config.name)
            }

            if let template = StarterModeCatalog.templates.first(where: { $0.id == id }) {
                return String(format: String(localized: "%@ Mode"), template.name)
            }

            return String(localized: "Mode")
        case .recorderPanelEscape:
            return String(localized: "Recorder Cancel")
        case .recorderPanelApply:
            return String(localized: "Apply Recorder Review")
        case .recorderPanelToggleHaloDelivery:
            return String(localized: "Toggle Halo Result Delivery")
        case .recorderPanelReviewFinal:
            return String(localized: "Show Final Halo Result")
        case .recorderPanelReviewChanges:
            return String(localized: "Show Halo Result Changes")
        case .recorderPanelReviewOriginal:
            return String(localized: "Show Original Halo Transcript")
        case .recorderPanelPreviousRevision:
            return String(localized: "Previous Halo Revision")
        case .recorderPanelNextRevision:
            return String(localized: "Next Halo Revision")
        case .recorderPanelMode(let index):
            return String(format: String(localized: "Select Mode %@"), Self.displayNumber(forRecorderPanelIndex: index))
        }
    }

    static let globalUtilityActions: [Self] = [
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .retryLastTranscription,
        .openHistoryWindow,
        .quickAddToDictionary,
    ]

    static let recorderPanelStoredActions: [Self] = [
        .cancelRecorder
    ]

    static let legacyKeyboardShortcutActions: [Self] = [
        .primaryRecording,
        .secondaryRecording,
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .retryLastTranscription,
        .cancelRecorder,
        .openHistoryWindow,
        .quickAddToDictionary,
    ]

    private static func displayNumber(forRecorderPanelIndex index: Int) -> String {
        index == 9 ? "10" : "\(index + 1)"
    }
}
