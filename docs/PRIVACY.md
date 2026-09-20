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

To uninstall, quit Stillnote, remove the app, and optionally remove its Application Support
folder to delete recordings and models (and any legacy Python runtime). Back up wanted recordings
first. Environment-variable overrides may place data elsewhere; remove those separately.
CLI accounts and their credentials belong to the independently installed provider CLIs.
