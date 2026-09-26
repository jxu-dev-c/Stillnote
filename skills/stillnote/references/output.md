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
      "has_summary": true, "has_notes": true } ] }
```

`status` is `ready`, `transcribing`, `transcribed`, `summarizing`, `complete`, or `error`.
`duration` is seconds. Newest first.

## `show`, `summary show`, and anything that changed one meeting

```json
{ "id": "aa11bb22cc33", "title": "Product launch planning",
  "created_at": "…", "updated_at": "…", "duration": 2412.0,
  "status": "complete", "stage": "Summary ready", "error": null,
  "language": "en", "has_video": false, "segment_count": 148,
  "speakers": [ { "id": "speaker_1", "name": "Jackson", "profile": true } ],
  "summary": { "overview": "…", "key_points": ["…"], "decisions": ["…"],
               "action_items": [ { "text": "…", "owner": "Jackson", "due": "2026-09-20" } ],
               "provider": "codex", "model": "gpt-5-codex", "generated_at": "…" },
  "notes": "…",
  "context_links": [ { "url": "https://…", "title": "…" } ],
  "cleanup": { "original_duration": 2600.0, "head": 120.0, "tail": 68.0, "applied_at": "…" },
  "segments": [ { "id": "s12", "start": 142.0, "end": 151.5, "speaker": "speaker_1",
                  "speaker_name": "Jackson", "text": "…" } ] }
```

`segments` is present only with `--segments`, and is filtered when `--speaker` is given;
`segment_count` is always the full count. `summary` is `null` until one is generated.
`speakers[].profile` is true when the name comes from a reusable speaker profile.
`cleanup` is present only when silence was trimmed from the saved recording, and records what was
removed — that trim cannot be undone.

Use `segments[].id` as the `--segment` value for `transcript set`, and `speakers[].id` as the
`--speaker` value for `speaker rename`.

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
