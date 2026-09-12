# Meeting Notes implementation contract

Local-only web application: React + TypeScript + Vite frontend on /, FastAPI backend 127.0.0.1:8765. Production static assets served by FastAPI. Python >=3.11. SQLite/files under data/. Models under models/. No recording or transcription leaves the computer. No browser SpeechRecognition APIs. Explicit model download/setup is allowed but never sends audio. Optional summaries can send transcript text to a provider only after per-request consent.

## API contracts
- GET /api/health -> {status:'ok', speech: object}
- GET /api/settings -> {transcription: {model:string, language:string, speaker_count:number|null}, summary:{provider:'codex'|'claude-code', model:string, reasoning_effort:'low'|'medium'|'high'}, agents:Record<string,{installed:boolean,command:string}>, speech: object}
- PUT /api/settings body {transcription?:{model?,language?,speaker_count?},summary?:{provider?,model?,reasoning_effort?}} -> same public settings
- GET /api/meetings -> Meeting[] most recent first
- POST /api/meetings multipart file, title, language='auto', speaker_count optional -> Meeting (audio saved, status='ready'; transcription separate explicit request)
- GET /api/meetings/{id} -> Meeting
- PATCH /api/meetings/{id} body {title?, notes?, context_links?:ContextLink[], speakers?:Record<string,string>, segments?:Segment[]} -> Meeting
- POST /api/context/link-title body {url:string} -> {title:string}; best-effort public page title, empty on failure. The client requests this only when saving a link without a label and persists the returned title with the link.
- DELETE /api/meetings/{id} -> 204
- GET /api/meetings/{id}/audio -> stored audio
- GET /api/meetings/{id}/video -> optional MP4 screen recording with mixed audio
- GET /api/recordings/capabilities -> native availability, microphone IDs/names, display IDs/names
- GET /api/recordings/current -> current native session or null
- POST /api/recordings body {title?,language?,speaker_count?,microphone_id?,display_id?,system_audio?:true,screen_video?:false} -> native session
- POST /api/recordings/{id}/pause|resume -> native session; state changes are confirmed through polling
- POST /api/recordings/{id}/stop -> saved Meeting; repeated successful calls return the same meeting
- DELETE /api/recordings/{id} -> 204; stops capture and discards unsaved session files
- POST /api/meetings/{id}/transcribe body {speaker_count?:number|null, language?:string} -> Meeting status='transcribing', background worker updates progress
- POST /api/meetings/{id}/summary body {allow_remote:boolean=false} -> Meeting status='summarizing', worker updates
- GET /api/meetings/{id}/export?format=md|json|txt|srt -> download
- POST /api/models/install body {model:string='moss-0.9b'} -> {status:'installing'}; model setup is explicit UI action
- GET /api/models/status -> speech status object

Meeting = {id,title,created_at,updated_at,duration:number,status:'ready'|'transcribing'|'transcribed'|'summarizing'|'complete'|'error',progress:number,stage:string,error:string|null,audio_name:string,audio_url:string,video_url:string|null,language:string,speaker_count:number|null,speakers:Record<string,string>,segments:Segment[],summary:Summary|null,notes:string,context_links:ContextLink[]}
ContextLink = {url:string,title:string} // HTTP(S) only, no embedded credentials; optional title defaults to "".
Segment = {id:string,start:number,end:number,speaker:string,text:string}
Summary = {overview:string,key_points:string[],decisions:string[],action_items:{text:string,owner:string|null,due:string|null}[],provider:string,model:string,generated_at:string}

## Runtime modules

| Module | Responsibility |
| --- | --- |
| `backend/meeting_app/main.py` | Loopback API, request validation, background job orchestration, exports, and static interface hosting. |
| `backend/meeting_app/storage.py` | SQLite meeting/settings persistence, local audio paths, and interrupted-job recovery. |
| `backend/meeting_app/schemas.py` | Validated request models. |
| `backend/meeting_app/speech.py` | Explicit model installation, local model readiness, restricted media decoding, MOSS/VibeVoice inference and native speaker attribution, and isolated inference orchestration. |
| `backend/meeting_app/speech_worker.py` | Child-process entry point for native CPU inference and progress events. |
| `backend/meeting_app/summarization.py` | Transcript normalization, chunking, summary validation, and local merging with explicit remote consent. |
| `backend/meeting_app/agents.py` | Headless Codex/Claude Code subprocess adapters, structured output, timeouts, cleanup, and CLI availability. |
| `frontend/src/` | React meeting library, recording, editing, playback, settings, and provider consent UI. |

A single background worker serializes processing to bound memory usage. Original audio is saved before transcription begins. Transcription runs in a separate process so native failures are recoverable. Successful transcript or speaker edits invalidate the previous summary; failed retranscription preserves existing corrections. Agent credentials are managed by the installed CLIs. Summary settings default to Codex/gpt-5.6-luna/high; Claude Code defaults to claude-sonnet-5/high. Retired provider settings migrate without changing saved meetings or summaries.

The speech setup endpoint downloads public model assets. Inference requires complete local files, uses offline mode, and forbids external media references. Remote summarization accepts transcript text and speaker labels, plus an optional local screen-video path when the meeting's `summary_include_video_path` preference is true. This patchable boolean defaults to false for new and legacy meetings. The API resolves the path from its own video store and rejects an enabled option when the file is missing; clients cannot provide arbitrary paths. Each section receives the path as JSON-encoded text metadata. File-reading tools remain disabled and no video content is sent. Changing the preference affects future summaries and preserves any existing summary. The browser bundles all assets locally and makes same-origin API requests.

## MOSS on Apple Silicon

`moss_mlx.py` adapts pinned MLX Audio code to the existing verified MOSS checkpoint. It runs 8-bit decoder inference on Metal, batches only independent encoder windows, preserves one full decoder context, and uses bounded prefill steps/cache allocation. `speech.py` selects MLX on macOS arm64 and keeps PyTorch elsewhere. The isolated worker always runs with Hugging Face offline flags; MLX additionally disables Transformers' PyTorch import.

`POST /api/meetings/{id}/transcribe/cancel` signals the job's cancellation event. Queued futures cancel immediately; active workers terminate via a polling watcher, escalating to kill after two seconds. The API keeps the meeting busy until the worker exits and restores its previous transcript/summary state. Job completion and cancellation share a lock so late progress/results cannot overwrite cancellation.

Headless agents receive only speaker-labeled transcript text through stdin, in a private temporary working directory. Codex runs read-only with shell/web disabled and user config ignored; Claude Code disables tools, MCP servers, slash commands and hooks. Both use ephemeral sessions and schema-constrained JSON, with independent output validation. A five-minute per-section deadline kills the CLI process group on POSIX. Raw CLI logs never become API error messages.

## Native capture

`backend/meeting_app/recording.py` owns one macOS helper subprocess, session recovery, bounded-memory PCM mixing, and optional MP4 muxing. `native/macos/` uses ScreenCaptureKit on macOS 15+ for microphone/system audio and opt-in screen video. The web interface polls session state and input levels; the helper writes recoverable WAVs while capturing. Saved screen video contains the same mixed audio used for transcription, and is stored separately from the WAV. Both use the same pause-adjusted host-clock timeline. Capture permissions are requested only on an explicit recording start. Browser recording remains the fallback. See `native/README.md` for build, lifecycle, and platform limitations.
