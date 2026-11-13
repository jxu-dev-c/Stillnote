# stillnote --json output

Every `--json` reply is one object:

```json
{
  "code": "ok",
  "ok": true,
  "message": "human-readable text, the same thing printed without --json",
  "result": { }
}
```

`code` is `ok`, `unavailable`, `not_ready`, `requires_app`, `not_found`, `ambiguous`, `busy`,
`usage`, or `failed`. On failure there is no `result` and `message` says what to do; it is also
written to stderr rather than stdout.

These shapes are a stable contract. The stored meeting document keeps some legacy field names for
the app's own compatibility; the CLI does not expose them.

## `list`

```json
{ "count": 2,
  "meetings": [
    { "id": "aa11bb22cc33", "title": "Product launch planning",
      "created_at": "2026-09-08T15:04:05.100+00:00", "duration": 2412.0,
      "status": "complete", "speakers": ["Jackson", "Priya"], "segments": 148,
      "has_summary": true, "has_notes": true, "tags": ["Product", "Engineering"] } ] }
```

`status` is `ready`, `transcribing`, `transcribed`, `summarizing`, `complete`, or `error`.
`duration` is seconds. Newest first. `tags` are tag names in the order they were applied, empty when untagged.

## `show`, `summary show`, and anything that changed one meeting

```json
{ "id": "aa11bb22cc33", "title": "Product launch planning",
  "created_at": "…", "updated_at": "…", "duration": 2412.0,
  "status": "complete", "stage": "Summary ready", "error": null,
  "language": "en", "has_video": false, "segment_count": 148, "tags": ["Product"],
  "speakers": [ { "id": "speaker_1", "name": "Jackson", "profile": true } ],
  "summary": { "overview": "…", "key_points": ["…"], "decisions": ["…"],
               "action_items": [ { "text": "…", "owner": "Jackson", "due": "2026-09-20", "completed": true } ],
               "provider": "codex", "model": "gpt-5-codex", "generated_at": "…",
               "context_fingerprint": "…" },
  "notes": "…",
  "context_links": [ { "url": "https://…", "title": "…" } ],
  "cleanup": { "original_duration": 2600.0, "head": 120.0, "tail": 68.0, "applied_at": "…" },
  "segments": [ { "id": "s12", "start": 142.0, "end": 151.5, "speaker": "speaker_1",
                  "speaker_name": "Jackson", "text": "…" } ] }
```

`segments` is present only with `--segments`, and is filtered when `--speaker` is given;
`segment_count` is always the full count. `summary` is `null` until one is generated. An action
item has `completed` only once it has been checked off in the app.
`summary.context_fingerprint` identifies the notes and links the summary was made from; it is
absent on summaries set with `summary set` or made before summaries used them.
`speakers[].profile` is true when the name comes from a reusable speaker profile.
`speakers[].voice_match` is present when Stillnote linked that profile by voice and nobody has
confirmed it yet; it is the match's similarity, 0–1. Assigning the speaker removes it.
`cleanup` is present only when silence was trimmed from the saved recording, and records what was
removed — that trim cannot be undone.

Use `segments[].id` as the `--segment` value for `transcript set`, and `speakers[].id` as the
`--speaker` value for `speaker rename` and `speaker assign`.

## `speaker list`, `speaker show`, and anything that changed a profile

```json
{ "count": 2,
  "speakers": [ { "id": "3F2A…", "name": "Jackson", "email": "jackson@example.com",
                  "phone": "", "meeting_count": 4 } ] }
```

`speaker show`, `speaker add`, `speaker update`, and `speaker delete` return one profile, with
the meetings it is linked to:

```json
{ "id": "3F2A…", "name": "Jackson", "email": "jackson@example.com", "phone": "",
  "meeting_count": 2,
  "meetings": [ { "id": "aa11bb22cc33", "title": "Product launch planning",
                  "created_at": "…", "speaker": "speaker_1" } ] }
```

`email` and `phone` are empty strings when not recorded. `meetings[].speaker` is the speaker id
inside that meeting. After `speaker delete`, `meetings` lists the meetings it was unlinked from;
they keep the name they showed. `speaker assign` changes a meeting, so it returns the meeting
shape above.

## `tag list`, `tag show`, and `tag create`

```json
{ "count": 2,
  "tags": [ { "id": "6b1e…", "name": "Product", "color": "blue", "meeting_count": 4 } ] }
```

Tags are in the user's sidebar order. `tag show` and `tag create` return one tag with the
meetings carrying it, newest first:

```json
{ "id": "6b1e…", "name": "Product", "color": "blue", "meeting_count": 1,
  "meetings": [ { "id": "aa11bb22cc33", "title": "Product launch planning",
                  "created_at": "…", "status": "complete", "has_summary": true,
                  "tags": ["Product", "Engineering"] } ] }
```

`meetings[].tags` is every tag on that meeting. `tag apply` and `tag remove` change a meeting, so
they return the meeting shape above.

## `tag auto`

```json
{ "dry_run": false, "model": "gpt-5.4-mini", "count": 2,
  "meetings": [ { "id": "aa11bb22cc33", "title": "Product launch planning",
                  "suggested": ["Product", "Engineering"], "added": ["Engineering"],
                  "tags": ["Product", "Engineering"] },
                { "id": "dd44ee55ff66", "title": "Old call", "suggested": [], "added": [],
                  "tags": [], "error": "Create a transcript before suggesting tags." } ] }
```

`suggested` is every tag OpenAI chose; `added` is the ones the meeting didn't already carry, saved
unless `dry_run` is true; `tags` is the meeting's tags afterwards. An empty `suggested` means no
tag fit. `error` is present only for a meeting that couldn't be tagged.

## `speaker voices` and `speaker learn`

```json
{ "learned": true, "learned_at": "2026-11-06T18:20:00.000+00:00",
  "profiles": 35, "meetings": 83, "samples": 338, "skipped_meetings": 0,
  "calibrated": true, "precision": 0.972, "coverage": 0.85,
  "scorer": "nearest", "threshold": 0.67, "margin": 0.15,
  "auto_tag_after_transcription": false }
```

`precision` and `coverage` come from testing the learned voices against the user's own tags, one
meeting held out at a time: `precision` is the share of matches that named the right profile,
and `coverage` the share of recognizable speakers that were tagged. Both are absent when
`calibrated` is false. Before anything is learned, `learned` is false and the counts are zero.
Voiceprints themselves are never printed.

## `speaker autotag`

```json
{ "dry_run": false, "tagged": 2,
  "meetings": [ { "id": "aa11bb22cc33", "title": "Weekly sync", "tagged": 2,
                  "summary_cleared": true,
                  "matches": [
                    { "speaker": "speaker_1", "decision": "assigned", "applied": true,
                      "profile": "3F2A…", "profile_name": "Jackson", "score": 0.91,
                      "runner_up": "9C1D…", "runner_up_name": "Priya", "runner_up_score": 0.46 },
                    { "speaker": "speaker_3", "decision": "uncertain", "applied": false,
                      "profile": "…", "profile_name": "…", "score": 0.73,
                      "runner_up": "…", "runner_up_name": "…", "runner_up_score": 0.66 } ] } ],
  "skipped": [ { "id": "dd44ee55ff66", "title": "Old call",
                 "reason": "This meeting's audio is missing." } ] }
```

`matches` covers only speakers that had no profile. `decision` is `assigned` (confident; linked
unless `dry_run`), `uncertain` (two profiles were too close), `unrecognized` (no profile was close
enough), or `too_short` (too little clear speech). `applied` is always false for a dry run.
`skipped` lists the meetings `--all` could not process and why; with one named meeting a failure
fails the command instead, so `skipped` is empty.

## `process`

```json
{ "dry_run": false,
  "meetings": [ { "id": "aa11bb22cc33", "title": "Meeting · Oct 3", "stage": "transcribe",
                  "parts": 3, "named": true,
                  "queued": [ "0f1e…", "7a2b…", "c93d…" ] },
                { "id": "dd44ee55ff66", "title": "Weekly sync", "stage": "summarize",
                  "parts": 1, "named": true, "queued": [ "dd44ee55ff66" ] } ],
  "skipped": [ { "id": "ff00aa11bb22", "title": "Old call",
                 "reason": "This meeting is processing. Wait for it to finish." } ] }
```

`stage` is where the meeting resumed: `transcribe` (no transcript yet: split if long, transcribe,
auto-tag, summarize, name) or `summarize` (summarize, then name). `parts` is how many meetings a
split made, 1 when it stayed whole. `queued` holds the ids now in the queue — a split meeting's
parts, which replace it, or the meeting itself; it is empty for a dry run. `named` is false with
`--keep-title`. The command returns once everything is queued, not once it is finished: poll
`list` or `show` for each `queued` id. `skipped` lists the meetings `--all` could not queue and why.

`name` returns the meeting, as `show` does, with its new `title`.

## `search`

```json
{ "query": "launch", "count": 1,
  "results": [
    { "id": "aa11bb22cc33", "title": "Product launch planning", "created_at": "…",
      "speakers": ["Jackson", "Priya"], "matches": 8,
      "hits": [ { "field": "transcript", "snippet": "…the Sept launch…",
                  "speaker": "Jackson", "start": 142.0 },
                { "field": "summary", "snippet": "…" } ] } ] }
```

`field` is `title`, `transcript`, `summary`, or `notes`. `speaker` and `start` appear on
transcript hits only; `start` is seconds, for seeking. `matches` counts occurrences, which can
exceed `hits.length` when one passage contains several. A long snippet is elided with `…`.

## `transcript replace`

```json
{ "find": "ANE", "replacement": "AEM", "dry_run": true,
  "matches": 14, "segments": 11, "summary_invalidated": true,
  "meetings": [ { "id": "aa11bb22cc33", "title": "Product launch planning",
                  "matches": 9, "segments": 7 } ] }
```

With `"dry_run": true` nothing was written. `summary_invalidated` is true when at least one
affected meeting had a summary, which was cleared because it quoted the old text. Meetings that
are busy are skipped by an `--all` sweep and do not appear.

## `record status`, `record start`, `record stop`

```json
{ "recording": true, "state": "recording", "session_id": "9f2c…",
  "elapsed": 412.0, "error": null,
  "options": { "title": "Design review", "language": "auto", "speaker_count": null,
               "microphone_id": "…", "display_id": 1, "system_audio": true,
               "screen_video": false } }
```

`state` is `starting`, `recording`, `paused`, `stopping`, or `stopped`. After a successful
`record stop` the session is gone and the reply names the meeting instead:

```json
{ "recording": false, "state": null, "meeting_id": "aa11bb22cc33", "transcribing": true }
```

`transcribing: false` after a stop means transcription was skipped — `message` says why, usually
that the speech model is not installed.

## `status`

```json
{ "running": true, "ready": true, "version": "0.4.0",
  "data_directory": "/Users/you/Library/Application Support/Stillnote/data",
  "socket": "/Users/you/Library/Application Support/Stillnote/data/cli.sock",
  "meetings": 42, "speech_ready": true, "speech_detail": "…",
  "recording": false, "transcribing": false,
  "summary_provider": "codex", "capture_available": true }
```

When the app is closed, only `running`, `ready`, `data_directory`, `socket`, and `meetings` are
populated; the rest are absent. `speech_ready: false` means transcription is unavailable until the
model is downloaded in the app's Settings.

## `devices`

```json
{ "available": true, "reason": null, "default_display": "1",
  "microphones": [ { "id": "BuiltInMicrophoneDevice", "name": "MacBook Pro Microphone" } ],
  "displays": [ { "id": "1", "name": "Built-in Display (main)" } ] }
```

## `export`, `notes show`, `notes set`

`export` returns `{ "id": …, "format": "md", "path": "/…", "text": null }` when `--out` was given,
and `path: null` with the document in `text` otherwise. `notes show` and `notes set` return
`{ "id": …, "text": "…" }`.
