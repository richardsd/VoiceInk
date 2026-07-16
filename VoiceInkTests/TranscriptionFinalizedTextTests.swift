import Foundation
import SwiftData
import Testing

@testable import VoiceInk

struct TranscriptionFinalizedTextTests {
    @Test func displayedResultTextUsesFinalEnhancedRawPrecedence() {
        let transcription = Transcription(text: "Raw", duration: 1)
        #expect(transcription.displayedResultText == "Raw")

        transcription.enhancedText = "Enhanced"
        #expect(transcription.displayedResultText == "Enhanced")

        transcription.finalizedText = "Final"
        #expect(transcription.displayedResultText == "Final")

        transcription.finalizedText = nil
        #expect(transcription.displayedResultText == "Enhanced")

        transcription.enhancedText = "Enhancement failed: private backend detail"
        #expect(transcription.usableEnhancedText == nil)
        #expect(transcription.displayedResultText == "Raw")
    }

    @MainActor
    @Test func optionalFinalizedTextPersistsForNewAndLegacyShapedRows() throws {
        let schema = Schema([Transcription.self])
        let configuration = ModelConfiguration(
            "finalized-text-tests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: configuration)

        let legacyShaped = Transcription(text: "Legacy raw", duration: 1, enhancedText: "Legacy enhanced")
        let finalized = Transcription(
            text: "Raw",
            duration: 2,
            enhancedText: "Enhanced",
            finalizedText: "Final"
        )
        container.mainContext.insert(legacyShaped)
        container.mainContext.insert(finalized)
        try container.mainContext.save()

        let stored = try container.mainContext.fetch(
            FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\Transcription.duration)])
        )

        #expect(stored.count == 2)
        #expect(stored[0].finalizedText == nil)
        #expect(stored[0].displayedResultText == "Legacy enhanced")
        #expect(stored[1].finalizedText == "Final")
        #expect(stored[1].displayedResultText == "Final")
    }

    @MainActor
    @Test func addingOptionalFinalizedTextLightweightMigratesAnExistingStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("transcriptions.store")

        let v1Schema = Schema(versionedSchema: FinalizedTextSchemaV1.self)
        let v1Configuration = ModelConfiguration(
            "finalized-migration",
            schema: v1Schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        var v1Container: ModelContainer? = try ModelContainer(
            for: v1Schema,
            migrationPlan: FinalizedTextMigrationPlan.self,
            configurations: v1Configuration
        )
        let legacy = FinalizedTextSchemaV1.StoredTranscription(
            text: "Legacy raw",
            enhancedText: "Legacy enhanced"
        )
        v1Container?.mainContext.insert(legacy)
        try v1Container?.mainContext.save()
        v1Container = nil

        let v2Schema = Schema(versionedSchema: FinalizedTextSchemaV2.self)
        let v2Configuration = ModelConfiguration(
            "finalized-migration",
            schema: v2Schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let v2Container = try ModelContainer(
            for: v2Schema,
            migrationPlan: FinalizedTextMigrationPlan.self,
            configurations: v2Configuration
        )
        let migrated = try v2Container.mainContext.fetch(
            FetchDescriptor<FinalizedTextSchemaV2.StoredTranscription>()
        )

        #expect(migrated.count == 1)
        #expect(migrated[0].text == "Legacy raw")
        #expect(migrated[0].enhancedText == "Legacy enhanced")
        #expect(migrated[0].finalizedText == nil)
    }

    @MainActor
    @Test func historySearchFindsFinalizedTextAndHonorsPaginationBoundary() throws {
        let schema = Schema([Transcription.self])
        let configuration = ModelConfiguration(
            "finalized-search-tests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: configuration)

        let older = Transcription(text: "Raw one", duration: 1, finalizedText: "final-only phrase")
        older.timestamp = Date(timeIntervalSince1970: 100)
        let newer = Transcription(text: "Raw two", duration: 1, finalizedText: "final-only phrase")
        newer.timestamp = Date(timeIntervalSince1970: 200)
        container.mainContext.insert(older)
        container.mainContext.insert(newer)
        try container.mainContext.save()

        var descriptor = FetchDescriptor<Transcription>(
            predicate: TranscriptionHistorySearch.predicate(
                matching: "final-only",
                before: Date(timeIntervalSince1970: 150)
            )
        )
        descriptor.sortBy = [SortDescriptor(\Transcription.timestamp)]
        let matches = try container.mainContext.fetch(descriptor)

        #expect(matches.map(\.id) == [older.id])
    }

    @Test func csvAppendsFinalTranscriptWithoutReorderingExistingColumns() {
        let transcription = Transcription(
            text: "Raw",
            duration: 12.5,
            enhancedText: "Enhanced",
            finalizedText: "Final",
            transcriptionModelName: "Whisper",
            aiEnhancementModelName: "Luna",
            promptName: "Cleanup",
            transcriptionDuration: 1.25,
            enhancementDuration: 2.5,
            modeName: "Dictation"
        )
        transcription.timestamp = Date(timeIntervalSince1970: 0)

        let csv = VoiceInkCSVExportService().generateCSV(for: [transcription])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(
            lines.first
                == "Original Transcript,Enhanced Transcript,Enhancement Model,Prompt Name,Transcription Model,Mode,Enhancement Time,Transcription Time,Timestamp,Duration,Final Transcript"
        )
        #expect(lines.dropFirst().first?.hasSuffix(",12.5,Final") == true)
        #expect(lines.dropFirst().first?.hasPrefix("Raw,Enhanced,Luna,Cleanup,Whisper,Dictation,2.5,1.25,") == true)
    }

    @Test func cancellationClearsAnyFinalizedResult() {
        let transcription = Transcription(text: "Raw", duration: 1, finalizedText: "Final")

        transcription.markAsCanceledTranscription()

        #expect(transcription.finalizedText == nil)
        #expect(transcription.displayedResultText == Transcription.canceledTranscriptionText)
    }

    @MainActor
    @Test func finalizerWritesDisplayTextOnlyAfterPasteCommandPosts() throws {
        let schema = Schema([Transcription.self])
        let configuration = ModelConfiguration(
            "halo-finalizer-tests",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let transcription = Transcription(text: "Raw", duration: 1, enhancedText: "Initial")
        container.mainContext.insert(transcription)
        try container.mainContext.save()

        let revisedPayload = PreparedPastePayload(
            displayText: "Selected refinement",
            pastedText: "License notice\n\nSelected refinement ",
            autoSendKey: .enter
        )

        #expect(
            !HaloTranscriptionFinalizer.finalizeIfCommandPosted(
                outcome: .commandNotPosted,
                transcriptionID: transcription.id,
                payload: revisedPayload,
                modelContext: container.mainContext
            )
        )
        #expect(transcription.finalizedText == nil)

        #expect(
            HaloTranscriptionFinalizer.finalizeIfCommandPosted(
                outcome: .commandPosted,
                transcriptionID: transcription.id,
                payload: revisedPayload,
                modelContext: container.mainContext
            )
        )
        #expect(transcription.finalizedText == "Selected refinement")
        #expect(transcription.finalizedText != revisedPayload.pastedText)
    }
}

private enum FinalizedTextSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [StoredTranscription.self] }

    @Model
    final class StoredTranscription {
        var text: String
        var enhancedText: String?

        init(text: String, enhancedText: String?) {
            self.text = text
            self.enhancedText = enhancedText
        }
    }
}

private enum FinalizedTextSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [StoredTranscription.self] }

    @Model
    final class StoredTranscription {
        var text: String
        var enhancedText: String?
        var finalizedText: String?

        init(text: String, enhancedText: String?, finalizedText: String? = nil) {
            self.text = text
            self.enhancedText = enhancedText
            self.finalizedText = finalizedText
        }
    }
}

private enum FinalizedTextMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [FinalizedTextSchemaV1.self, FinalizedTextSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: FinalizedTextSchemaV1.self,
                toVersion: FinalizedTextSchemaV2.self
            )
        ]
    }
}
