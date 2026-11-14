import StillnoteCore
import SwiftUI

/// Positions Assign Speaker under the portrait or line chip it belongs to, with a caret
/// pointing at it. Clicking elsewhere or pressing Escape closes it.
struct SpeakerPickerOverlay: View {
    let meeting: Meeting
    let target: PickerTarget
    let anchors: [PickerAnchorID: Anchor<CGRect>]
    let player: PlayerModel?
    let close: () -> Void

    private static let width: CGFloat = 404
    @State private var height: CGFloat = 420

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture(perform: close)
                if let placement = placement(proxy) {
                    SpeakerPicker(meeting: meeting, target: target, caretX: placement.caretX,
                                  caretBelow: placement.above, room: placement.room, player: player, close: close)
                        .frame(width: Self.width)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                        .offset(x: placement.origin.x, y: placement.origin.y)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: placement.above ? .bottom : .top)))
                }
            }
        }
    }

    /// Below the chip, or above it when there is more room there. The list shrinks to fit.
    private func placement(_ proxy: GeometryProxy) -> (origin: CGPoint, caretX: CGFloat, above: Bool, room: CGFloat)? {
        let chip: CGRect, x: CGFloat, caretX: CGFloat, below: CGFloat
        switch target {
        case .voice(let id):
            guard let chipAnchor = anchors[.voice(id)], let groupAnchor = anchors[.voiceGroup] else { return nil }
            let group = proxy[groupAnchor]
            chip = proxy[chipAnchor]
            // Left-aligned with the portraits, 12 points below them, moved right only as far as
            // keeps the caret inside the popover for a portrait far along the row.
            let caretInset: CGFloat = 24
            let preferred = max(group.minX, chip.midX + caretInset - Self.width)
            x = max(8, min(preferred, proxy.size.width - 8 - Self.width))
            caretX = chip.midX - x
            below = group.maxY + 12
        case .line:
            guard let chipAnchor = anchors[.line] else { return nil }
            chip = proxy[chipAnchor]
            x = max(8, chip.minX - 6)
            caretX = chip.minX + 15 - x
            below = chip.maxY + 12
        }
        let roomBelow = proxy.size.height - below - 8, roomAbove = chip.minY - 20
        let above = roomBelow < height && roomAbove > roomBelow
        return (CGPoint(x: x, y: above ? chip.minY - 12 - height : below), caretX, above, above ? roomAbove : roomBelow)
    }
}

private struct SpeakerPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(Feedback.self) private var feedback
    @Environment(\.openSettings) private var openSettings
    let meeting: Meeting
    let target: PickerTarget
    let caretX: CGFloat
    let caretBelow: Bool
    /// The height available to the popover; its list gives way first.
    let room: CGFloat
    let player: PlayerModel?
    let close: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var working = false

    /// The voice this popover is about, and for a line, which line.
    private var voice: String {
        switch target {
        case .voice(let id): id
        case .line(let segmentID): meeting.segments.first { $0.id == segmentID }?.speaker ?? ""
        }
    }

    private var line: Segment? {
        if case .line(let id) = target { return meeting.segments.first { $0.id == id } }
        return nil
    }

    private var voiceLines: [Segment] { meeting.segments.filter { $0.speaker == voice } }
    private var voiceNumber: Int { meeting.voiceNumber(voice) }
    /// A line popover changes only that line, unless the voice has no other lines.
    private var lineScope: Bool { line != nil && voiceLines.count > 1 }
    private var currentProfile: String? { meeting.speakerProfiles[voice] }

    var body: some View {
        let look = meeting.look(voice)
        VStack(alignment: .leading, spacing: 12) {
            header(look)
            searchField
            results
                .padding(.horizontal, -6)
                .padding(.top, -2)
            Rectangle().fill(DS.separator).frame(height: 0.5).padding(.horizontal, -14)
            HStack {
                Spacer()
                Button {
                    model.requestedSpeakerProfileID = currentProfile
                    model.settingsPage = .people
                    close()
                    openSettings()
                } label: {
                    Text("Manage Profiles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.accentInk)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .hoverFill(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, -6)
            .padding(.top, -4)
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 8, trailing: 14))
        .designMenu(.rect(cornerRadius: 20))
        .overlay(alignment: caretBelow ? .bottomLeading : .topLeading) {
            caret
                .rotationEffect(.degrees(caretBelow ? 180 : 0))
                .offset(x: caretX - 6, y: caretBelow ? 6 : -6)
        }
        .disabled(working)
        .onAppear { searchFocused = true }
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(line == nil ? "Assign speaker" : "Assign speaker for this line")
        .accessibilityAddTraits(.isModal)
    }

    private var caret: some View {
        UnevenRoundedRectangle(topLeadingRadius: 3)
            .fill(DS.menuSolid)
            .overlay {
                UnevenRoundedRectangle(topLeadingRadius: 3)
                    .stroke(DS.menuCaretBorder, lineWidth: 0.5)
                    .mask(alignment: .topLeading) {
                        // Only the two outer edges carry a border, as the design's caret does.
                        Path { p in
                            p.move(to: .zero); p.addLine(to: CGPoint(x: 12, y: 0)); p.addLine(to: CGPoint(x: 0, y: 12)); p.closeSubpath()
                        }
                    }
            }
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(45))
            .accessibilityHidden(true)
    }

    private func header(_ look: SpeakerLook) -> some View {
        HStack(spacing: 12) {
            SpeakerPortrait(look: look, size: 36, fontSize: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(look))
                    .font(.system(size: 15, weight: .bold))
                    .letterSpacing(-0.01, size: 15)
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CapsuleButton(title: "Listen", icon: .play, iconFilled: true, action: listen)
            .disabled(player?.unplayableReason != nil || player == nil)
            .accessibilityLabel("Play a voice sample from this speaker")
        }
    }

    private func title(_ look: SpeakerLook) -> String {
        if line != nil { return look.unknown ? "Who said this?" : look.name }
        return look.unknown ? "Who is \(look.name)?" : look.name
    }

    private var subtitle: String {
        if let line {
            return "This line at \(clock(line.start)) · Voice \(voiceNumber)"
        }
        let count = voiceLines.count
        return "Voice \(voiceNumber) · \(count) \(count == 1 ? "line" : "lines") in this meeting"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Icon(.search, size: 16, lineWidth: 1.9)
            TextField("Search name or email", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(DS.text)
                .focused($searchFocused)
                .onSubmit(submit)
                .accessibilityLabel("Search people")
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Icon(.close, size: 10, lineWidth: 3.4)
                        .foregroundStyle(DS.menuSolid)
                        .frame(width: 20, height: 20)
                        .background(DS.text3, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .foregroundStyle(DS.text2)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(DS.field, in: .rect(cornerRadius: 12))
        .overlay {
            if searchFocused {
                RoundedRectangle(cornerRadius: 12).stroke(DS.Accent.blue.tint, lineWidth: 3).padding(-1.5)
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// People already in this meeting first, then everyone else; or the matches for a search.
    private var profiles: [SpeakerProfile] {
        let all = model.speakerProfiles
        if !trimmedQuery.isEmpty {
            return all.filter { profile in
                [profile.name, profile.email, profile.phone].contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
            }
        }
        let present = Set(meeting.speakerProfiles.values)
        return all.filter { present.contains($0.id) } + all.filter { !present.contains($0.id) }
    }

    private var results: some View {
        let profiles = self.profiles
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !trimmedQuery.isEmpty && !profiles.isEmpty {
                    sectionLabel("Results")
                }
                ForEach(profiles) { profile in
                    row(profile)
                }
                if profiles.isEmpty {
                    Text(trimmedQuery.isEmpty
                         ? "No profiles yet. Type a name to add one."
                         : "No one matches “\(trimmedQuery)”.")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.text2)
                        .padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))
                }
                if !trimmedQuery.isEmpty && !profiles.contains(where: { $0.name.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
                    createRow
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: max(88, min(232, room - 186)))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(DS.text2)
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 4, trailing: 10))
    }

    private func row(_ profile: SpeakerProfile) -> some View {
        let checked = currentProfile == profile.id
        let accent = DS.Accent.stable(profile.id)
        let matched = meeting.autoSpeakerProfiles[voice] != nil && currentProfile == profile.id
        let contact = [profile.email, profile.phone].first { !$0.isEmpty } ?? ""
        return Button { assign(profile, unlink: checked && !lineScope) } label: {
            HStack(spacing: 10) {
                Text(Meeting.initial(profile.name))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent.ink)
                    .frame(width: 28, height: 28)
                    .background(accent.tint, in: .circle)
                VStack(alignment: .leading, spacing: 0) {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    if !contact.isEmpty {
                        Text(contact)
                            .font(.system(size: 12))
                            .foregroundStyle(DS.text2)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if matched {
                    HStack(spacing: 4) {
                        Icon(.waveform, size: 12, lineWidth: 2)
                        Text("Voice match").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(DS.accentInk)
                    .padding(.leading, 6)
                    .padding(.trailing, 8)
                    .frame(height: 22)
                    .background(DS.Accent.blue.tint, in: .capsule)
                    .help(meeting.autoSpeakerProfiles[voice].map { "Matched by voice, \(Int(($0 * 100).rounded()))% similar" } ?? "")
                }
                if checked {
                    Icon(.check, size: 16, lineWidth: 2.6).foregroundStyle(DS.accentInk)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .hoverFill(.rect(cornerRadius: 12), active: checked)
        }
        .buttonStyle(.plain)
        .help(checked && !lineScope ? "Unlink this voice from \(profile.name)" : "Assign to \(profile.name)")
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private var createRow: some View {
        let name = trimmedQuery.capitalized
        return Button(action: { create(name) }) {
            HStack(spacing: 10) {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: 28, height: 28)
                    .overlay { Icon(.plus, size: 14, lineWidth: 2.2) }
                Text("New profile “\(name)”")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DS.accentInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .hoverFill(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func listen() {
        let sample = line ?? voiceLines.max { ($0.end - $0.start) < ($1.end - $1.start) }
        guard let sample else { return }
        player?.preview(from: sample.start, to: sample.end)
    }

    /// Return assigns the only match, or creates the typed person when nobody matches.
    private func submit() {
        let matches = profiles
        if matches.count == 1 {
            assign(matches[0], unlink: false)
        } else if matches.isEmpty, !trimmedQuery.isEmpty {
            create(trimmedQuery.capitalized)
        }
    }

    private func create(_ name: String) {
        working = true
        Task {
            defer { working = false }
            do {
                let profile = try SpeakerProfile(name: name).validated()
                if lineScope, let line {
                    let saved = try await model.saveSpeakerProfile(profile)
                    await assignLine(line, to: saved)
                } else {
                    let previous = (meeting.speakerProfiles[voice], meeting.speakerName(voice))
                    try await model.createSpeakerProfile(profile, meetingID: meeting.id, speakerID: voice)
                    announceVoice(name: profile.name, previous: previous)
                }
                close()
            } catch {
                model.report(error)
            }
        }
    }

    private func assign(_ profile: SpeakerProfile, unlink: Bool) {
        working = true
        Task {
            defer { working = false }
            if lineScope, let line {
                // The line already belongs to this person.
                if profile.id != currentProfile { await assignLine(line, to: profile) }
                close()
                return
            }
            let previous = (meeting.speakerProfiles[voice], meeting.speakerName(voice))
            do {
                try await model.assignSpeakerProfile(unlink ? nil : profile.id, meetingID: meeting.id, speakerID: voice)
                announceVoice(name: unlink ? nil : profile.name, previous: previous)
                close()
            } catch {
                model.report(error)
            }
        }
    }

    private func assignLine(_ line: Segment, to profile: SpeakerProfile) async {
        let meetingID = meeting.id
        guard let change = await model.assignLine(line.id, in: meetingID, to: profile) else { return }
        feedback.show("Assigned 1 line to \(profile.name)") { [model] in
            Task { await model.undoLineAssignment(change, in: meetingID) }
        }
    }

    private func announceVoice(name: String?, previous: (profile: String?, name: String)) {
        let count = voiceLines.count
        let lines = "\(count) \(count == 1 ? "line" : "lines")"
        let meetingID = meeting.id, voice = self.voice
        feedback.show(name.map { "Assigned \(lines) to \($0)" } ?? "Unlinked \(lines)") { [model] in
            Task {
                do {
                    try await model.assignSpeakerProfile(
                        previous.profile, meetingID: meetingID, speakerID: voice,
                        localName: previous.profile == nil ? previous.name : nil
                    )
                } catch {
                    model.report(error)
                }
            }
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
