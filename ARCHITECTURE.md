# Meeting Notes implementation contract

Local-only web application: React + TypeScript + Vite frontend on /, FastAPI backend 127.0.0.1:8765. Production static assets served by FastAPI. Python >=3.11. SQLite/files under data/. Models under models/. No recording or transcription leaves the computer. No browser SpeechRecognition APIs. Explicit model download/setup is allowed but never sends audio. Optional summaries can send transcript text to a provider only after per-request consent.

## API contracts
- GET /api/health -> {status:'ok', speech: object}
- GET /api/settings -> {transcription: {model:string, language:string, speaker_count:number|null}, summary:{provider:'local'|'ollama'|'openai-compatible'|'anthropic', model:string, base_url:string, api_key_set:boolean}, speech: object}
- PUT /api/settings body {transcription?:{model?,language?,speaker_count?},summary?:{provider?,model?,base_url?,api_key?}} -> same public settings
- GET /api/meetings -> Meeting[] most recent first
- POST /api/meetings multipart file, title, language='auto', speaker_count optional -> Meeting (audio saved, status='ready'; transcription separate explicit request)
- GET /api/meetings/{id} -> Meeting
- PATCH /api/meetings/{id} body {title?, notes?, speakers?:Record<string,string>, segments?:Segment[]} -> Meeting
- DELETE /api/meetings/{id} -> 204
- GET /api/meetings/{id}/audio -> stored audio
- POST /api/meetings/{id}/transcribe body {speaker_count?:number|null, language?:string} -> Meeting status='transcribing', background worker updates progress
- POST /api/meetings/{id}/summary body {allow_remote:boolean=false} -> Meeting status='summarizing', worker updates
- GET /api/meetings/{id}/export?format=md|json|txt|srt -> download
- POST /api/models/install body {model:string='moss-0.9b'} -> {status:'installing'}; model setup is explicit UI action
- GET /api/models/status -> speech status object

Meeting = {id,title,created_at,updated_at,duration:number,status:'ready'|'transcribing'|'transcribed'|'summarizing'|'complete'|'error',progress:number,stage:string,error:string|null,audio_name:string,audio_url:string,language:string,speaker_count:number|null,speakers:Record<string,string>,segments:Segment[],summary:Summary|null,notes:string}
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
| `backend/meeting_app/summarization.py` | Local extraction and transcript-only provider adapters with explicit remote consent. |
| `frontend/src/` | React meeting library, recording, editing, playback, settings, and provider consent UI. |

A single background worker serializes processing to bound memory usage. Original audio is saved before transcription begins. Transcription runs in a separate process so native failures are recoverable. Successful transcript or speaker edits invalidate the previous summary; failed retranscription preserves existing corrections. Provider keys are backend-only and are omitted from public settings and validation errors.

The speech setup endpoint downloads public model assets. Inference requires complete local files, uses offline mode, and forbids external media references. Remote summarization accepts only transcript text and speaker labels. The browser bundles all assets locally and makes same-origin API requests.

## MOSS on Apple Silicon

`moss_mlx.py` adapts pinned MLX Audio code to the existing verified MOSS checkpoint. It runs 8-bit decoder inference on Metal, batches only independent encoder windows, preserves one full decoder context, and uses bounded prefill steps/cache allocation. `speech.py` selects MLX on macOS arm64 and keeps PyTorch elsewhere. The isolated worker always runs with Hugging Face offline flags; MLX additionally disables Transformers' PyTorch import.

`POST /api/meetings/{id}/transcribe/cancel` signals the job's cancellation event. Queued futures cancel immediately; active workers terminate via a polling watcher, escalating to kill after two seconds. The API keeps the meeting busy until the worker exits and restores its previous transcript/summary state. Job completion and cancellation share a lock so late progress/results cannot overwrite cancellation.
