# stillnote command reference

Generated behaviour lives in `Sources/StillnoteCore/CLI/CommandCatalog.swift`; run
`stillnote help --json` for the machine-readable version of this table.

Every command accepts `--json` (structured output) and `--timeout <seconds>` (how long to wait
for the app). `--help` on any command prints its usage instead of running it.

## Works while Stillnote is closed

These read the library directly, read-only.

| Command | Options |
| --- | --- |
| `stillnote status` | — |
| `stillnote list` | `--limit`, `--since`, `--until`, `--status`, `--speaker` |
| `stillnote show <meeting>` | `--segments`, `--speaker` |
| `stillnote search <query>` | `--in`, `--speaker`, `--since`, `--until`, `--limit`, `--context` |
| `stillnote export <meeting>` | `--format md\|txt\|srt\|json`, `--out <path>` |
| `stillnote summary show <meeting>` | — |
| `stillnote notes show <meeting>` | — |
| `stillnote speaker list` | — |
| `stillnote speaker show <profile>` | — |
| `stillnote speaker voices` | — |
| `stillnote help [command]` | — |

## Needs Stillnote running

The app is the only writer, and the only process that can record: capture permissions belong to
the signed app bundle, not to whatever launched the CLI.

| Command | Options |
| --- | --- |
| `stillnote transcript replace <find> <replacement>` | `--meeting <id>` *or* `--all` (required), `--regex`, `--ignore-case`, `--whole-word`, `--dry-run` |
| `stillnote transcript set <meeting>` | `--segment <id>` (required), `--text`, `--speaker` |
| `stillnote speaker rename <meeting>` | `--speaker <id>`, `--name` |
| `stillnote speaker add` | `--name` (required), `--email`, `--phone` |
| `stillnote speaker update <profile>` | `--name`, `--email`, `--phone` (at least one; `""` clears email or phone) |
| `stillnote speaker delete <profile>` | — |
| `stillnote speaker assign <meeting>` | `--speaker <id>` (required), `--profile <profile>` *or* `--none` |
| `stillnote speaker learn` | `--wait` |
| `stillnote speaker autotag [<meeting>]` | a meeting *or* `--all`, `--dry-run` |
| `stillnote summary set <meeting>` | `--overview <text>` *or* `--json-stdin` |
| `stillnote notes set <meeting>` | `--text <notes>` *or* `--stdin` |
| `stillnote transcribe <meeting>` | `--language`, `--speakers` |
| `stillnote summarize <meeting>` | `--allow-remote` (required) |
| `stillnote name <meeting>` | `--allow-remote` (required) |
| `stillnote process [<meeting>]` | a meeting *or* `--all`; `--allow-remote` (required unless `--dry-run`), `--dry-run`, `--no-split`, `--keep-title`; with `--all`: `--status`, `--since`, `--until`, `--limit` |
| `stillnote record status` | — |
| `stillnote record start` | `--title`, `--mic`, `--screen`, `--language`, `--speakers`, `--no-system-audio`, `--screen-video` |
| `stillnote record stop` | `--no-transcribe` |
| `stillnote record pause` / `resume` / `discard` | — |
| `stillnote devices` | — |

## Argument notes

**`<meeting>`** — a full id, a unique id prefix, `latest`, or an exact title. An ambiguous prefix
is an error listing the candidates rather than a guess.

**`<profile>`** — a speaker profile's full id, a unique id prefix, its exact name, or its exact
email, ignoring case. Two profiles with the same name make the name ambiguous; use the id.

**Dates** — `YYYY-MM-DD` or `YYYY-MM`, nothing else. A four-digit year is required. `--since` is
the start of its unit and `--until` the end, so `--since 2026-05 --until 2026-05` is all of May.

**`--in`** — comma-separated: `title`, `transcript`, `summary`, `notes`. All four by default.

**`search --speaker`** — searches only transcript segments attributed to the matching speaker.
Title, summary, and notes matches are omitted because they have no speaker attribution.

**`--status`** — `ready`, `transcribing`, `transcribed`, `summarizing`, `complete`, `error`.
For `process --all` only `ready`, `transcribed`, or `error`; without it, `process --all` takes
`ready` and `transcribed` meetings.

**`--mic` / `--screen`** — an exact device id from `stillnote devices`, or a substring of its name.

**`--regex`** — ICU syntax. `$1` in the replacement refers to a capture group. Without `--regex`,
both sides are literal: `$1` stays `$1` and `(a)` matches those three characters.

**`--`** — everything after it is a positional, for text that starts with `--`.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | The command failed |
| 2 | Bad usage: an unknown option, a missing argument, an invalid value |
| 3 | Stillnote is not running, is still opening, or has the command interface switched off |
| 4 | No such meeting, segment, speaker, speaker profile, or device; or an ambiguous reference |
| 5 | That meeting is transcribing or summarizing |

## Defaults and limits

- `list` returns 50 meetings, `search` 20 matching meetings, unless `--limit` says otherwise.
- `search` snippets show 80 characters around a match; change it with `--context`.
- Commands wait 60 seconds for the app, except `record stop`, which waits 900: saving mixes both
  audio sources and runs the silence detector over the whole capture; `name`, which waits 660 for
  the agent; and `process` and `speaker learn`/`autotag`, which wait 3600.
- One recording at a time. Save it or discard it before starting another.
- `record start` without `--title` names the meeting `Meeting · <date>`. `record stop` only
  transcribes, so the placeholder stays until `name` or `process` titles it, or the recording is
  stopped in the app with **Stop, Transcribe & Summarize**. `name` and `process` replace any
  title, including one given with `--title`; `process --keep-title` leaves titles alone.
- `process` splits a recording at or above the split threshold in Settings into 20-minute
  parts, each named `<title> partN`, before transcribing it. The original meeting is replaced by
  its parts. `--no-split` keeps it whole.
- `speaker add` refuses a name another profile already has, so names stay usable references.
- The user can switch the whole interface off in **Settings → Advanced**, which returns exit 3.
