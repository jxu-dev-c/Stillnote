# Privacy and removal

Recordings, transcripts, notes, speaker contacts, and summaries are stored locally under
`~/Library/Application Support/Stillnote/`. They are not encrypted by Stillnote; protect
the Mac account and backups accordingly. Deleting a meeting removes its database record
and associated media, but does not erase backups or guarantee forensic erasure.

Network activity includes dependency installation, public Hugging Face model downloads,
page-title and favicon requests for context links, optional summary CLI requests, and optional OpenAI requests for suggested tags.
Summaries send transcript text and speaker labels to the provider chosen in
**Settings → Summarize**; recordings with screen video always include the local video path
as text. The agent can access that path according to its own configuration and permissions. **Name Meeting** sends the
meeting's summary, or the opening of its transcript and speaker labels when there is no summary.
Choosing a provider in Settings is the consent: the window does not ask again for each request. Provider retention and
account policies apply. No cloud transcription fallback is used.

## Suggested tags (OpenAI)

**Suggest Tags**, **Auto-Tag Meetings…**, and `stillnote tag auto` send a meeting's title, its
summary (overview, key points, and decisions) or the opening of its transcript with speaker labels,
and the names of your tags to OpenAI's Decisions API. Nothing is sent until you
choose one of those, or turn on **Suggest tags after each summary** in **Settings → Summarize**,
which then tags each newly summarized meeting without asking again. The `stillnote` command needs
`--allow-remote` on every `tag auto`. OpenAI's API data policies apply.

The OpenAI API key saved in **Settings → Summarize** is stored in the macOS login Keychain, not in
Stillnote's database. Without one, Stillnote reads `OPENAI_API_KEY` from its environment or your
login shell. **Remove** deletes the saved key.

## Voice recognition

Learn Voices and Auto-Tag compute voiceprints: numbers that describe how each speaker in a
meeting sounds. They are computed on this Mac by the bundled worker and stored in the same
private database as the meetings, never sent to a summary provider, written to exports, or
printed by the `stillnote` command, which reports only counts and accuracy. The first run
downloads a public 15 MB voice model from Hugging Face, which sends no audio. Deleting a meeting
retains its voiceprints in Recently Deleted for five days; **Forget Voices** in Settings → Speakers deletes all of them, including archived voiceprints. Profile
links made by voice are ordinary speaker tags and stay until changed.

## Meeting reminders

Meeting reminders are off until turned on in **Settings → Record**. While they are on,
Stillnote asks Core Audio which processes are capturing from an input device. It reads only their
bundle identifiers and never their audio, needs no macOS permission, and saves nothing about what
it sees. Turning reminders off stops the observation entirely.

## The stillnote command

While Stillnote is open it accepts commands on a Unix domain socket at
`cli.sock` inside the data folder. That is a filesystem object, not a network port: its directory
is `0700` and the socket itself `0600`, so only this macOS user can connect, and nothing is
listening once the app quits. Nothing sent over it leaves the machine.

Anything running as this user — including an AI agent you point at the command — can therefore
read every meeting, correct transcripts and summaries, and start, stop, or discard a recording,
which means it can switch on the microphone. Turn the whole interface off in
**Settings → Command line** to refuse every command. Generating a summary is excluded from that trust:
`stillnote summarize` requires an explicit `--allow-remote`, so an agent cannot send a transcript
to a provider CLI without consent on that command.

A file named `cli.sock` may remain in the data folder after Stillnote quits. It carries no
content; the next launch reclaims it once a connection proves nothing is listening.

To uninstall, quit Stillnote, remove the app, and optionally remove its Application Support
folder to delete recordings and models (and any legacy Python runtime). Back up wanted recordings
first. Environment-variable overrides may place data elsewhere; remove those separately.
CLI accounts and their credentials belong to the independently installed provider CLIs.

## Recently Deleted

Deleted meetings, transcripts, notes, and recordings stay on this Mac for five days and can be restored from Recently Deleted above Settings. After 120 hours, Stillnote removes them permanently on its next cleanup (at launch and every minute while running). They are not moved to macOS Trash. Meetings deleted before this feature cannot be recovered through it.
