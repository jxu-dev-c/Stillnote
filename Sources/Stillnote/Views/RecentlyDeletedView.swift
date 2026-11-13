import StillnoteCore
import SwiftUI

struct RecentlyDeletedView: View {
    @Environment(AppModel.self) private var model
    @State private var restoring: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Deleted")
                .font(.system(size: 24, weight: .bold))
                .accessibilityAddTraits(.isHeader)
                .foregroundStyle(DS.text)
            Text("Deleted meetings are kept for five days, then permanently removed with their recordings.")
                .font(.system(size: 13))
                .foregroundStyle(DS.text2)
            if model.recentlyDeleted.isEmpty {
                ContentUnavailableView("No Recently Deleted Meetings", systemImage: "trash",
                    description: Text("Meetings you delete will appear here for five days."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.recentlyDeleted) { meeting in
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(meeting.title).font(.headline).foregroundStyle(DS.text)
                                    Text("Permanently removed \(meeting.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(DS.text2)
                                }
                                Spacer()
                                Button("Restore") {
                                    restoring.insert(meeting.id)
                                    Task {
                                        await model.restoreDeleted(meeting.id)
                                        restoring.remove(meeting.id)
                                    }
                                }
                                .disabled(restoring.contains(meeting.id) || meeting.expiresAt <= Date())
                                .accessibilityLabel("Restore \(meeting.title)")
                            }
                            .padding(.vertical, 14)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(28)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { do { try await model.refreshRecentlyDeleted() } catch { model.report(error) } }
    }
}
