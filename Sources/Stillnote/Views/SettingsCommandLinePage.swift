import StillnoteCore
import SwiftUI

/// The command interface: a local socket the bundled `stillnote` CLI talks to.
struct CommandLineSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let enabled = model.settings.cli.enabled
        SettingsCard {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow the stillnote command to control this app")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.text)
                    SettingsCaption("Stillnote listens on a socket inside your library folder so the bundled stillnote command, and any agent you point at it, can read and correct meetings and start or stop a recording.")
                    SettingsCaption("Turn this off to refuse every command, including starting a recording.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsSwitch("Allow the stillnote command to control this app", isOn: model.setting(\.cli.enabled))
            }
            .padding(14)
        }

        SettingsSection("How it connects") {
            SettingsCard {
                HStack(spacing: 12) {
                    Text("Socket").font(SettingsMetrics.rowFont)
                    Text((model.paths.commandSocketURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(DS.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .background(DS.well, in: .rect(cornerRadius: 8, style: .continuous))
                        .help(model.paths.commandSocketURL.path)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                fact(icon: .lock, color: DS.okInk, title: Text("Stays on this Mac"),
                     caption: "The socket is a file only your macOS account can open. Nothing is sent anywhere and no network port is used.")
                fact(icon: .arrowOut, color: DS.awayInk,
                     title: Text("Summaries need \(Text("--allow-remote").font(.system(size: 12, design: .monospaced))) on each command"),
                     caption: "A command may come from an agent, so summarize, name, process, and tag auto must consent each time they send meeting text to your provider.")
            }
        }
        .opacity(enabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.18), value: enabled)
        .accessibilityHint(enabled ? "" : "The command interface is off.")
    }

    private func fact(icon: DesignIcon, color: Color, title: Text, caption: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Icon(icon, size: 16, lineWidth: 1.9)
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                title.font(.system(size: 13)).foregroundStyle(DS.text)
                SettingsCaption(caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
