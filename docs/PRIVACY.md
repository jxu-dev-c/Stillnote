# Privacy and removal

Recordings, transcripts, notes, speaker contacts, and summaries are stored locally under
`~/Library/Application Support/Stillnote/`. They are not encrypted by Stillnote; protect
the Mac account and backups accordingly. Deleting a meeting removes its database record
and associated media, but does not erase backups or guarantee forensic erasure.

Network activity includes dependency installation, public Hugging Face model downloads,
page-title and favicon requests for context links, and optional summary CLI requests.
Summaries require confirmation and send transcript text and speaker labels to the chosen
provider; optionally they include the local video path as text. Provider retention and
account policies apply. No cloud transcription fallback is used.

## The stillnote command

While Stillnote is open it accepts commands on a Unix domain socket at
`cli.sock` inside the data folder. That is a filesystem object, not a network port: its directory
is `0700` and the socket itself `0600`, so only this macOS user can connect, and nothing is
listening once the app quits. Nothing sent over it leaves the machine.

Anything running as this user — including an AI agent you point at the command — can therefore
read every meeting, correct transcripts and summaries, and start, stop, or discard a recording,
which means it can switch on the microphone. Turn the whole interface off in
**Settings → Advanced** to refuse every command. Generating a summary is excluded from that trust:
`stillnote summarize` requires an explicit `--allow-remote`, the command-line form of the
confirmation the window asks for, so no transcript reaches a provider CLI without consent.

A file named `cli.sock` may remain in the data folder after Stillnote quits. It carries no
content; the next launch reclaims it once a connection proves nothing is listening.

To uninstall, quit Stillnote, remove the app, and optionally remove its Application Support
folder to delete recordings and models (and any legacy Python runtime). Back up wanted recordings
first. Environment-variable overrides may place data elsewhere; remove those separately.
CLI accounts and their credentials belong to the independently installed provider CLIs.
