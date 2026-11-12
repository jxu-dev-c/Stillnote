import Foundation
import StillnoteCore

/// Stars and categories: the sidebar's ways of grouping meetings. Both are plain meeting
/// fields, so they go through `edit` and never touch a summary.
extension AppModel {
    var todayCount: Int {
        let calendar = Calendar.current
        return meetings.count { calendar.isDateInToday($0.startDate) }
    }

    var starredCount: Int { meetings.count(where: \.starred) }

    /// Meetings per category. Ids with no category left are not counted.
    var categoryCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for meeting in meetings {
            if let id = meeting.categoryID { counts[id, default: 0] += 1 }
        }
        return counts
    }

    func category(_ id: String?) -> MeetingCategory? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    func setStarred(_ id: String, _ starred: Bool) async {
        await edit(id) { $0.starred = starred }
    }

    func setCategory(_ id: String, _ categoryID: String?) async {
        await edit(id) { $0.categoryID = categoryID }
    }

    @discardableResult
    func createCategory(name: String) async -> MeetingCategory? {
        do {
            let category = MeetingCategory(
                name: try Validation.categoryName(name),
                color: CategoryColor.next(after: categories.map(\.color)),
                position: (categories.map(\.position).max() ?? -1) + 1
            )
            let saved = try await store.saveCategory(category)
            categories.append(saved)
            return saved
        } catch {
            report(error)
            return nil
        }
    }

    func renameCategory(_ id: String, to name: String) async {
        await updateCategory(id) { $0.name = name }
    }

    func recolorCategory(_ id: String, _ color: CategoryColor) async {
        await updateCategory(id) { $0.color = color }
    }

    private func updateCategory(_ id: String, _ mutate: (inout MeetingCategory) -> Void) async {
        guard var category = category(id) else { return }
        mutate(&category)
        do {
            let saved = try await store.saveCategory(category)
            if let index = categories.firstIndex(where: { $0.id == id }) { categories[index] = saved }
        } catch {
            report(error)
        }
    }

    /// Drops `id` onto `target` in manual order: after it when dragged down, before it when
    /// dragged up. The sidebar updates first so the row lands without waiting on the store.
    func moveCategory(_ id: String, onto target: String) async {
        var ordered = MeetingCategory.sorted(categories, by: .manual).map(\.id)
        guard id != target, let from = ordered.firstIndex(of: id), let to = ordered.firstIndex(of: target)
        else { return }
        ordered.remove(at: from)
        ordered.insert(id, at: to)
        for (position, categoryID) in ordered.enumerated() {
            if let index = categories.firstIndex(where: { $0.id == categoryID }) { categories[index].position = position }
        }
        do {
            categories = try await store.reorderCategories(ordered)
        } catch {
            report(error)
            categories = (try? await store.categories()) ?? categories
        }
    }

    func deleteCategory(_ id: String) async {
        // A split compares the original meeting before replacing it; clearing its category
        // underneath would make that split fail.
        guard splittingMeetings.isEmpty else {
            alertMessage = "Wait for recording splitting to finish."
            return
        }
        do {
            let changed = try await store.deleteCategory(id)
            categories.removeAll { $0.id == id }
            for meeting in changed { await apply(meeting) }
        } catch {
            report(error)
        }
    }
}
