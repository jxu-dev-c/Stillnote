import StillnoteCore
import SwiftUI

struct RecentlyDeletedView: View {
    @Environment(AppModel.self) private var model
    @State private var restoring: Set<String> = []

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recently Deleted")
                        .font(.system(size: 24, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                        .foregroundStyle(DS.text)
                    Text("Deleted meetings are kept for five days, then permanently removed with their recordings.")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 20)
                if model.recentlyDeleted.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.recentlyDeleted) { meeting in
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(meeting.title).font(.headline).foregroundStyle(DS.text)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text("Permanently removed \(meeting.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundStyle(DS.text2)
                                    }
                                    Spacer()
                                    CapsuleButton(title: "Restore") {
                                        restoring.insert(meeting.id)
                                        Task {
                                            await model.restoreDeleted(meeting.id)
                                            restoring.remove(meeting.id)
                                        }
                                    }
                                    .disabled(restoring.contains(meeting.id) || meeting.expiresAt <= Date())
                                    .accessibilityLabel("Restore \(meeting.title)")
                                    .fixedSize()
                                }
                                .padding(.vertical, 14)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 52)
            .padding(.bottom, 28)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .task { do { try await model.refreshRecentlyDeleted() } catch { model.report(error) } }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Icon(.trash, size: 36)
                .foregroundStyle(DS.text3)
            Text("No Recently Deleted Meetings")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DS.text)
            Text("Meetings you delete will appear here for five days.")
                .font(.system(size: 13))
                .foregroundStyle(DS.text2)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
