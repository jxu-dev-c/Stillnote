import Foundation
import StillnoteCore

/// Stars and tags: the sidebar's ways of grouping meetings. Both are plain meeting fields, so
/// they go through `edit` and never touch a summary.
extension AppModel {
    var todayCount: Int {
        let calendar = Calendar.current
        return meetings.count { calendar.isDateInToday($0.startDate) }
    }

    var starredCount: Int { meetings.count(where: \.starred) }

    /// Meetings per tag. A meeting with several tags counts once under each. Ids with no tag
    /// left are not counted.
    var tagCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for meeting in meetings {
            for id in meeting.tagIDs { counts[id, default: 0] += 1 }
        }
        return counts
    }

    func tag(_ id: String?) -> MeetingTag? {
        guard let id else { return nil }
        return tags.first { $0.id == id }
    }

    func setStarred(_ id: String, _ starred: Bool) async {
        await edit(id) { $0.starred = starred }
    }

    func toggleTag(_ tagID: String, on id: String) async {
        await edit(id) { meeting in
            if meeting.tagIDs.contains(tagID) { meeting.removeTag(tagID) } else { meeting.addTags([tagID]) }
        }
    }

    func clearTags(_ id: String) async {
        await edit(id) { $0.tagIDs = [] }
    }

    @discardableResult
    func createTag(name: String, color: TagColor? = nil) async -> MeetingTag? {
        do {
            return try await addTag(name: name, color: color)
        } catch {
            report(error)
            return nil
        }
    }

    /// `createTag` for callers that report the failure themselves, such as `stillnote tag create`.
    func addTag(name: String, color: TagColor? = nil) async throws -> MeetingTag {
        let tag = MeetingTag(
            name: try Validation.tagName(name),
            color: color ?? TagColor.next(after: tags.map(\.color)),
            position: (tags.map(\.position).max() ?? -1) + 1
        )
        let saved = try await store.saveTag(tag)
        tags.append(saved)
        return saved
    }

    func renameTag(_ id: String, to name: String) async {
        await updateTag(id) { $0.name = name }
    }

    func recolorTag(_ id: String, _ color: TagColor) async {
        await updateTag(id) { $0.color = color }
    }

    private func updateTag(_ id: String, _ mutate: (inout MeetingTag) -> Void) async {
        guard var tag = tag(id) else { return }
        mutate(&tag)
        do {
            let saved = try await store.saveTag(tag)
            if let index = tags.firstIndex(where: { $0.id == id }) { tags[index] = saved }
        } catch {
            report(error)
        }
    }

    /// Drops `id` onto `target` in manual order: after it when dragged down, before it when
    /// dragged up. The sidebar updates first so the row lands without waiting on the store.
    func moveTag(_ id: String, onto target: String) async {
        var ordered = MeetingTag.sorted(tags, by: .manual).map(\.id)
        guard id != target, let from = ordered.firstIndex(of: id), let to = ordered.firstIndex(of: target)
        else { return }
        ordered.remove(at: from)
        ordered.insert(id, at: to)
        for (position, tagID) in ordered.enumerated() {
            if let index = tags.firstIndex(where: { $0.id == tagID }) { tags[index].position = position }
        }
        do {
            tags = try await store.reorderTags(ordered)
        } catch {
            report(error)
            tags = (try? await store.tags()) ?? tags
        }
    }

    func deleteTag(_ id: String) async {
        // A split compares the original meeting before replacing it; removing its tag
        // underneath would make that split fail.
        guard splittingMeetings.isEmpty else {
            alertMessage = "Wait for recording splitting to finish."
            return
        }
        do {
            let changed = try await store.deleteTag(id)
            tags.removeAll { $0.id == id }
            for meeting in changed { await apply(meeting) }
        } catch {
            report(error)
        }
    }

    // MARK: - Suggested tags (OpenAI)

    /// Re-reads where the OpenAI key comes from. Reading the login shell starts a process, so it
    /// runs off the main actor.
    func refreshOpenAIKey() async {
        openAIKeySource = await Task.detached(priority: .utility) { OpenAICredentials.resolve()?.source }.value
    }

    func saveOpenAIKey(_ key: String) async {
        do {
            try OpenAICredentials.save(key)
        } catch {
            report(error)
        }
        await refreshOpenAIKey()
    }

    func removeOpenAIKey() async {
        do {
            try OpenAICredentials.delete()
        } catch {
            report(error)
        }
        await refreshOpenAIKey()
    }

    /// Meetings Auto-Tag Meetings would send: transcribed, idle, and carrying no tag yet.
    var untaggedMeetingIDs: [String] {
        meetings.filter { $0.tagIDs.isEmpty && [.transcribed, .complete].contains($0.status) }.map(\.id)
    }

    /// Suggest Tags from a meeting's menu. Failures show in the window's alert.
    func suggestTags(_ id: String) async {
        do {
            _ = try await tagMeeting(id, allowRemote: true)
        } catch {
            alertMessage = Self.taggingMessage(error)
        }
    }

    /// Auto-Tag Meetings: every untagged meeting, a few at a time on the agent slots. Stops at the
    /// first failure that would repeat for every meeting, such as a rejected key.
    func tagUntaggedMeetings() async {
        var failures: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for id in untaggedMeetingIDs {
                group.addTask { [weak self] in
                    guard let self else { return nil }
                    do {
                        _ = try await self.tagMeeting(id, allowRemote: true)
                        return nil
                    } catch {
                        return Self.taggingMessage(error)
                    }
                }
            }
            for await failure in group {
                if let failure { failures.append(failure) }
            }
        }
        if let first = failures.first {
            alertMessage = failures.count == 1 ? first : "\(failures.count) meetings couldn't be tagged. \(first)"
        }
    }

    /// Asks OpenAI which of the library's tags fit the meeting and adds the ones it lacks. It
    /// never removes a tag. Returns nil without throwing when the meeting is already being
    /// tagged or split, or was deleted. With `dryRun`, nothing is saved.
    func tagMeeting(_ id: String, allowRemote: Bool, dryRun: Bool = false) async throws -> TagSuggestion? {
        guard !splittingMeetings.contains(id), !taggingMeetings.contains(id) else { return nil }
        guard !tags.isEmpty else { throw ValidationError("Create a tag first, then Stillnote can suggest it.") }
        taggingMeetings.insert(id)
        defer { taggingMeetings.remove(id) }
        guard let meeting = try? await store.get(id), !splittingMeetings.contains(id) else { return nil }
        guard !meeting.status.isBusy else {
            throw ValidationError("This meeting is processing. Wait for it to finish.")
        }
        guard !meeting.segments.isEmpty else {
            throw ValidationError("Create a transcript before suggesting tags.")
        }
        let tags = tags
        let settings = settings.tagging
        let suggested = try await agentJobs.run {
            let key = try await Task.detached(priority: .userInitiated) { try OpenAICredentials.require() }.value
            return try await MeetingTagger.suggestTags(
                meeting: meeting, tags: tags, settings: settings, allowRemote: allowRemote, apiKey: key
            )
        }
        // A tag may have been deleted while OpenAI was working.
        let live = suggested.filter { tag($0) != nil }
        if dryRun {
            var preview = meeting
            let added = preview.addTags(live)
            return TagSuggestion(meeting: preview, suggested: live, added: added)
        }
        guard libraryItem(id) != nil else { return nil }
        guard let saved = await edit(id, { $0.addTags(live) }) else {
            throw ValidationError("The tags could not be saved.")
        }
        let added = live.filter { !meeting.tagIDs.contains($0) && saved.tagIDs.contains($0) }
        return TagSuggestion(meeting: saved, suggested: live, added: added)
    }

    nonisolated static func taggingMessage(_ error: Error) -> String {
        (error as? SummaryError)?.message
            ?? (error as? ValidationError)?.message
            ?? "Suggesting tags failed. Check the OpenAI key and model in Settings → Summaries."
    }
}

/// What `tagMeeting` chose: every suggested tag id, and the ones that were new to the meeting.
struct TagSuggestion {
    let meeting: Meeting
    let suggested: [String]
    let added: [String]
}
