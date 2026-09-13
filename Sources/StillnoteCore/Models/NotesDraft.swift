import Foundation
import Observation

/// Keeps a recoverable draft until the store confirms the exact text was saved.
@MainActor
@Observable
public final class NotesDraft {
    public var text = ""
    public private(set) var savedText = ""
    public private(set) var error: String?
    public var isDirty: Bool { text != savedText }

    private let defaults: UserDefaults
    private var key: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(meetingID: String, savedText: String) {
        key = "stillnote:notes:\(meetingID)"
        self.savedText = savedText
        text = defaults.string(forKey: key!) ?? savedText
        error = nil
    }

    public func recordEdit() {
        error = nil
        retainUnsavedText()
    }

    public func save(using persist: (String) async -> Bool) async {
        guard isDirty else { return }
        guard text.count <= Validation.maxNotesLength else {
            error = "Notes must be at most \(Validation.maxNotesLength.formatted()) characters. Your draft is kept."
            retainUnsavedText()
            return
        }
        let pending = text
        guard await persist(pending) else {
            error = "Notes could not be saved. Your draft is kept; retry saving."
            retainUnsavedText()
            return
        }
        savedText = pending
        error = nil
        // Text may have changed while the write was in flight. Keep that newer draft.
        retainUnsavedText()
    }

    private func retainUnsavedText() {
        guard let key else { return }
        if isDirty {
            defaults.set(text, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
