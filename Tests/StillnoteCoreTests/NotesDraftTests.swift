import Foundation
import Testing

@testable import StillnoteCore

@MainActor
@Suite struct NotesDraftTests {
    private func withDraft(_ test: (NotesDraft, UserDefaults) async throws -> Void) async throws {
        let suite = "stillnote-notes-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let draft = NotesDraft(defaults: defaults)
        draft.load(meetingID: "test", savedText: "original")
        try await test(draft, defaults)
    }

    @Test func failedSaveKeepsDraftForRecoveryAndRetry() async throws {
        try await withDraft { draft, defaults in
            draft.text = "unsaved edit"
            draft.recordEdit()
            await draft.save { _ in false }
            #expect(draft.isDirty)
            #expect(draft.savedText == "original")
            #expect(draft.error != nil)
            let recovered = NotesDraft(defaults: defaults)
            recovered.load(meetingID: "test", savedText: "original")
            #expect(recovered.text == "unsaved edit")
            await recovered.save { value in value == "unsaved edit" }
            #expect(!recovered.isDirty)
            #expect(recovered.error == nil)
            #expect(defaults.string(forKey: "stillnote:notes:test") == nil)
        }
    }

    @Test func editsDuringSaveRemainRecoverable() async throws {
        try await withDraft { draft, defaults in
            draft.text = "first edit"
            draft.recordEdit()
            await draft.save { pending in
                #expect(pending == "first edit")
                draft.text = "newer edit"
                draft.recordEdit()
                return true
            }
            #expect(draft.savedText == "first edit")
            #expect(draft.isDirty)
            #expect(defaults.string(forKey: "stillnote:notes:test") == "newer edit")
        }
    }

    @Test func oversizedNotesStayRecoverableWithoutWritingTheStore() async throws {
        try await withDraft { draft, defaults in
            draft.text = String(repeating: "a", count: Validation.maxNotesLength + 1)
            draft.recordEdit()
            await draft.save { _ in
                Issue.record("Oversized notes must not reach the store")
                return true
            }
            #expect(draft.isDirty)
            #expect(draft.error?.contains("characters") == true)
            #expect(defaults.string(forKey: "stillnote:notes:test") == draft.text)
        }
    }
}
