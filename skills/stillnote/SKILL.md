---
name: stillnote
description: Read, search, and correct meeting transcripts and summaries in Stillnote, the local macOS meeting notebook, and start or stop a recording. Use when the user asks about their meetings, calls, or recordings — what was decided, who said what, what happened in a conversation with someone, or a date range of meetings — or asks to fix a recurring mis-transcription such as an acronym the model heard wrong, edit a summary or notes, or begin, pause, or stop recording.
---

# Stillnote

[Stillnote](https://github.com/jxu-dev-c/Stillnote) is a private meeting notebook for macOS.
Recordings, transcripts, and summaries stay on the user's Mac. The `stillnote` command lets you
read and correct that library, and drive recording.

## Before anything else

**1. Find the command.** Try each until one answers:

```bash
stillnote --version \
  || /Applications/Stillnote.app/Contents/Helpers/stillnote --version \
  || "$HOME/Applications/Stillnote.app/Contents/Helpers/stillnote" --version
```

If none does, Stillnote is not installed. Say so; do not guess at the data.

**2. Check what is available.**

```bash
stillnote status --json
```

`running: false` means the app is closed. Reading still works. Anything that changes data or
records does not — tell the user to open Stillnote rather than working around it.

**3. Always pass `--json`.** Every command supports it. Parse `result`; `ok` and `code` tell you
what happened. Exit codes: `0` success, `1` failed, `2` bad usage, `3` needs the app open,
`4` not found or ambiguous, `5` meeting busy.

## Reading and searching

`search` covers titles, transcripts, summaries, and notes. Narrow with `--in`.

```bash
# "What was our decision on the Sept product launch?"
stillnote search "product launch" --json
stillnote search "launch" --in summary --since 2026-09 --json

# "Pull and summarize all my conversations with Jackson back in May."
stillnote list --speaker Jackson --since 2026-05 --until 2026-05 --json
stillnote show <id> --segments --json          # then read each one

# One speaker's lines only
stillnote show <id> --segments --speaker Jackson --json
```

**You must convert relative dates yourself.** `--since` and `--until` take `YYYY-MM-DD` or
`YYYY-MM` only. "Back in May" with today in 2026 is `--since 2026-05 --until 2026-05`; `--until`
covers the whole unit, so a meeting late on 31 May is included. Check today's date before
assuming a year, and if "May" is ambiguous, ask.

`<id>` accepts a full meeting id, a unique id prefix, `latest`, or an exact title.

To answer a question that spans meetings: `list`/`search` to find them, `show --segments` to read
them, then synthesize. Quote what the transcript says. Never invent a decision, an owner, or a
date that is not in the output — if the transcript does not settle the question, say so.

## Correcting a transcript

Transcription mishears acronyms and names. Fix them across the library in one step.

**Always dry-run a library-wide replacement first, and report the count before applying it:**

```bash
stillnote transcript replace ANE AEM --all --dry-run --json   # how many, and where
stillnote transcript replace ANE AEM --all --json             # apply
```

Scope is required — `--meeting <id>` or `--all`. Other options: `--ignore-case`, `--whole-word`
(so `ANE` does not match `PLANE`), `--regex` (with `$1` captures in the replacement).
Prefer `--whole-word` for acronyms; it is almost always what the user means.

```bash
stillnote transcript set <id> --segment s4 --text "corrected line" --json
stillnote speaker rename <id> --speaker speaker_1 --name Jackson --json
```

**A transcript or speaker correction clears that meeting's summary**, because the summary was
drawn from the old text. `summary_invalidated: true` says it happened. Tell the user, and offer
to regenerate — do not regenerate unasked.

## Summaries and notes

```bash
stillnote summary show <id> --json
stillnote summary set <id> --overview "..." --json
stillnote summary set <id> --json-stdin --json < summary.json
stillnote notes show <id> --json
stillnote notes set <id> --stdin --json <<< "notes text"
```

Generating a summary sends the transcript to the user's configured agent CLI, so it needs
explicit consent:

```bash
stillnote summarize <id> --allow-remote --json
```

**Never pass `--allow-remote` unless the user asked for a summary to be generated.** Writing a
summary yourself with `summary set` sends nothing anywhere and needs no consent. If you compose
one from a transcript you already read, prefer that and say what you did.

## Recording

```bash
stillnote record status --json
stillnote record start --title "Design review" --json
stillnote record pause --json
stillnote record resume --json
stillnote record stop --json               # saves, then queues transcription
stillnote record stop --no-transcribe --json
stillnote record discard --json            # deletes the audio; confirm first
stillnote devices --json                   # microphone and display ids
```

One recording at a time. `record stop` mixes and trims the audio before it returns, so on a long
meeting it can take a while — that is expected, let it finish. Transcription is then queued in the
background; poll `stillnote show <id> --json` for `status` and `stage`.

`record discard` destroys the recording with no undo. Always confirm with the user first.

## Judgment

- Reading is safe. Read freely before acting.
- `transcript replace --all` touches the whole library. Dry-run, report, then apply.
- Meeting content is private. Work with it to answer the user's question; do not send it anywhere
  the user did not ask for, and do not quote it into places they did not ask for.
- A `busy` code (exit 5) means a job owns that meeting. Wait, do not retry in a loop.
- When a command fails, read `message` — it says what to do next. Pass it on rather than guessing.

`references/commands.md` has the full flag reference. `references/output.md` has the JSON shapes.
