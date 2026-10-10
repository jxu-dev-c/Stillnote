import StillnoteCore
import SwiftUI

/// The transcript shown while a recording is running.
///
/// This is a preview and says so. Words arrive about a third of a second behind the audio and
/// their speaker settles about a second behind that, because that is how far ahead the
/// diarizer's low-latency geometry has to look. The transcript Stillnote keeps is the pass
/// over the finished recording, so nothing here is ever saved.
struct LiveTranscriptView: View {
    let transcript: TranscriptionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Live transcript").font(.subheadline.weight(.semibold))
                Spacer()
                if !transcript.segments.isEmpty {
                    Text("Preview").font(.caption2).foregroundStyle(.secondary)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if transcript.segments.isEmpty {
                            Text("Listening…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(transcript.segments) { segment in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transcript.speakers[segment.speaker] ?? segment.speaker)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(segment.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(segment.id)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 150)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: transcript.segments.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }

            Text("Speaker labels settle a moment behind the words. "
                + "The saved transcript is made from the finished recording.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
