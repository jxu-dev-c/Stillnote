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
| `stillnote help [command]` | — |

## Needs Stillnote running

The app is the only writer, and the only process that can record: capture permissions belong to
the signed app bundle, not to whatever launched the CLI.

| Command | Options |
| --- | --- |
| `stillnote transcript replace <find> <replacement>` | `--meeting <id>` *or* `--all` (required), `--regex`, `--ignore-case`, `--whole-word`, `--dry-run` |
| `stillnote transcript set <meeting>` | `--segment <id>` (required), `--text`, `--speaker` |
| `stillnote speaker rename <meeting>` | `--speaker <id>`, `--name` |
| `stillnote summary set <meeting>` | `--overview <text>` *or* `--json-stdin` |
| `stillnote notes set <meeting>` | `--text <notes>` *or* `--stdin` |
| `stillnote transcribe <meeting>` | `--language`, `--speakers` |
| `stillnote summarize <meeting>` | `--allow-remote` (required) |
| `stillnote record status` | — |
| `stillnote record start` | `--title`, `--mic`, `--screen`, `--language`, `--speakers`, `--no-system-audio`, `--screen-video` |
| `stillnote record stop` | `--no-transcribe` |
| `stillnote record pause` / `resume` / `discard` | — |
| `stillnote devices` | — |

## Argument notes

**`<meeting>`** — a full id, a unique id prefix, `latest`, or an exact title. An ambiguous prefix
is an error listing the candidates rather than a guess.

**Dates** — `YYYY-MM-DD` or `YYYY-MM`, nothing else. A four-digit year is required. `--since` is
the start of its unit and `--until` the end, so `--since 2026-05 --until 2026-05` is all of May.

**`--in`** — comma-separated: `title`, `transcript`, `summary`, `notes`. All four by default.

**`--status`** — `ready`, `transcribing`, `transcribed`, `summarizing`, `complete`, `error`.

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
| 4 | No such meeting, segment, speaker, or device; or an ambiguous reference |
| 5 | That meeting is transcribing or summarizing |

## Defaults and limits

- `list` returns 50 meetings, `search` 20 matching meetings, unless `--limit` says otherwise.
- `search` snippets show 80 characters around a match; change it with `--context`.
- Commands wait 60 seconds for the app, except `record stop`, which waits 900: saving mixes both
  audio sources and runs the silence detector over the whole capture.
- One recording at a time. Save it or discard it before starting another.
- The user can switch the whole interface off in **Settings → Advanced**, which returns exit 3.
