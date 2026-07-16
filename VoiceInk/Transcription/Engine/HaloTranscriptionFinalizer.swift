import Foundation
import SwiftData
import os

/// Persists the user-visible Halo result only after the paste command has been
/// posted. Paste-only licensing and trailing-space changes intentionally never
/// enter History.
@MainActor
enum HaloTranscriptionFinalizer {
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "HaloTranscriptionFinalizer"
    )

    @discardableResult
    static func finalizeIfCommandPosted(
        outcome: PasteDeliveryOutcome,
        transcriptionID: UUID,
        payload: PreparedPastePayload,
        modelContext: ModelContext
    ) -> Bool {
        guard outcome == .commandPosted else { return false }

        let targetID = transcriptionID
        var descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate { transcription in
                transcription.id == targetID
            }
        )
        descriptor.fetchLimit = 1

        do {
            guard let transcription = try modelContext.fetch(descriptor).first else {
                logger.error("Could not finalize Halo transcription because its saved record was unavailable")
                return false
            }

            transcription.finalizedText = payload.displayText
            try modelContext.save()
            return true
        } catch {
            logger.error("Could not save the finalized Halo result")
            return false
        }
    }
}
