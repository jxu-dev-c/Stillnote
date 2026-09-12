"""Stillnote's loopback-only API and static app server."""

import json
import math
import mimetypes
import os
import re
import threading
from concurrent.futures import Future, ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import quote, urlparse
from uuid import uuid4

import av
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from starlette.middleware.trustedhost import TrustedHostMiddleware

from . import agents, link_metadata, recording, speech, summarization
from .schemas import (
    ContextLink,
    InstallRequest,
    MeetingPatch,
    RecordingRequest,
    SettingsPatch,
    SummaryRequest,
    TranscribeRequest,
)
from .storage import BUSY, Store

PROJECT_ROOT = Path(__file__).resolve().parents[2]
MAX_AUDIO_BYTES = 2 * 1024 * 1024 * 1024


def timestamp(seconds, srt=False):
    milliseconds = round(max(0, seconds) * 1000)
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    secs, milliseconds = divmod(milliseconds, 1000)
    return f"{hours:02}:{minutes:02}:{secs:02}" + (f",{milliseconds:03}" if srt else "")


def export_text(meeting, format):
    if format == "json":
        return json.dumps(meeting, indent=2, ensure_ascii=False)
    speakers = meeting["speakers"]
    if format == "srt":
        return (
            "\n\n".join(
                f"{i + 1}\n{timestamp(s['start'], True)} --> {timestamp(s['end'], True)}\n"
                f"{speakers.get(s['speaker'], s['speaker'])}: {s['text']}"
                for i, s in enumerate(meeting["segments"])
            )
            + "\n"
        )
    heading = "# " if format == "md" else ""
    lines = [f"{heading}{meeting['title']}", "", f"Recorded: {meeting['created_at']}", ""]
    summary = meeting.get("summary")
    if summary:
        lines += [f"{heading}Summary", "", summary["overview"], ""]
        for key, label in [
            ("key_points", "Key points"),
            ("decisions", "Decisions"),
            ("action_items", "Action items"),
        ]:
            lines += [f"{heading}{label}", ""]
            for item in summary[key]:
                if isinstance(item, dict):
                    text = item["text"]
                    if item.get("owner"):
                        text += f" — Owner: {item['owner']}"
                    if item.get("due"):
                        text += f" — Due: {item['due']}"
                else:
                    text = item
                lines.append(f"- {text}")
            lines.append("")
        lines += [f"Summary provider: {summary['provider']} ({summary['model']})", ""]
    if meeting.get("notes") or meeting.get("context_links"):
        lines += [f"{heading}Context", ""]
        if meeting.get("notes"):
            lines += [meeting["notes"], ""]
        for link in meeting.get("context_links", []):
            if format == "md":
                title = re.sub(r"([\\`*_{}\[\]<>()!])", r"\\\1", link["title"] or link["url"])
                url = link["url"].replace("<", "%3C").replace(">", "%3E")
                lines.append(f"- [{title}](<{url}>)")
            else:
                lines.append(f"- {link['title']}: {link['url']}" if link["title"] else f"- {link['url']}")
        if meeting.get("context_links"):
            lines.append("")
    lines += [f"{heading}Transcript", ""]
    for segment in meeting["segments"]:
        name = speakers.get(segment["speaker"], segment["speaker"])
        lines += [f"[{timestamp(segment['start'])}] {name}: {segment['text']}", ""]
    return "\n".join(lines)


def create_app(data_dir=None, model_dir=None):
    store = Store(Path(data_dir or os.environ.get("STILLNOTE_DATA_DIR", PROJECT_ROOT / "data")))
    capture = recording.RecordingManager(store)
    model_dir = Path(model_dir or os.environ.get("STILLNOTE_MODEL_DIR", PROJECT_ROOT / "models"))
    model_dir.mkdir(parents=True, exist_ok=True)
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="stillnote")
    install_state = {"installing": False, "progress": 0, "error": None}
    job_lock = threading.RLock()
    transcription_cancellations: dict[str, threading.Event] = {}
    transcription_futures: dict[str, Future] = {}

    @asynccontextmanager
    async def lifespan(app):
        yield
        capture.close()
        for cancel_event in list(transcription_cancellations.values()):
            cancel_event.set()
        executor.shutdown(wait=True, cancel_futures=False)

    app = FastAPI(title="Stillnote", version="0.1.0", lifespan=lifespan)
    app.state.store = store
    app.state.executor = executor
    app.state.capture = capture
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost", "[::1]"])

    @app.exception_handler(recording.RecordingError)
    async def recording_error(request: Request, error: recording.RecordingError):
        return JSONResponse({"detail": str(error)}, error.status)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, error: RequestValidationError):
        # FastAPI's default errors include rejected input, potentially an API key.
        known_fields = {
            "summary",
            "transcription",
            "api_key",
            "provider",
            "model",
            "reasoning_effort",
            "base_url",
            "language",
            "speaker_count",
            "title",
            "notes",
            "context_links",
            "url",
            "speakers",
            "segments",
            "start",
            "end",
            "text",
            "speaker",
            "id",
            "allow_remote",
            "file",
        }
        fields = sorted(
            {".".join(str(part) for part in item["loc"] if part in known_fields) for item in error.errors()}
        )
        location = ", ".join(field for field in fields if field) or "the submitted fields"
        return JSONResponse({"detail": f"Invalid value for {location}. Check field values and lengths."}, 422)

    @app.middleware("http")
    async def local_boundary(request: Request, call_next):
        # Block hostile websites (including form POSTs) and DNS rebinding attacks.
        origin = request.headers.get("origin")
        if origin:
            try:
                parsed = urlparse(origin)
                valid_origin = origin == str(request.base_url).rstrip("/") or (
                    parsed.scheme == "http"
                    and parsed.hostname in {"localhost", "127.0.0.1"}
                    and parsed.port == 5173
                    and parsed.path == ""
                )
            except ValueError:
                valid_origin = False
            if not valid_origin:
                return JSONResponse({"detail": "Only the local Stillnote app may access this API."}, 403)
        if request.headers.get("sec-fetch-site") == "cross-site":
            return JSONResponse({"detail": "Cross-site access is disabled."}, 403)
        if request.url.path == "/api/meetings" and request.method == "POST":
            try:
                if int(request.headers.get("content-length", "0")) > MAX_AUDIO_BYTES + 1024 * 1024:
                    return JSONResponse({"detail": "Audio files must be smaller than 2 GB."}, 413)
            except ValueError:
                return JSONResponse({"detail": "Invalid upload length."}, 400)
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Permissions-Policy"] = "microphone=(self), camera=()"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: https: http:; media-src 'self' blob:; connect-src 'self'; "
            "font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
        )
        if request.url.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
        return response

    def status():
        settings = store.settings()
        result = speech.speech_status(model_dir, settings["transcription"]["model"])
        if install_state["installing"] or install_state["error"]:
            result.update(install_state)
        return result

    def public_settings():
        result = store.settings()
        result["agents"] = agents.agent_status()
        result["speech"] = status()
        return result

    def get_meeting(meeting_id):
        try:
            return store.get(meeting_id)
        except KeyError:
            raise HTTPException(404, "Meeting not found.") from None

    def require_idle(meeting):
        if meeting["status"] in BUSY:
            raise HTTPException(409, "This meeting is processing. Wait for it to finish.")

    @app.get("/api/health")
    def health():
        return {"status": "ok", "speech": status()}

    @app.get("/api/settings")
    def get_settings():
        return public_settings()

    @app.put("/api/settings")
    def put_settings(patch: SettingsPatch):
        changes = patch.model_dump(exclude_unset=True, exclude_none=True)
        # Nullable speaker count must be preserved when switching back to automatic detection.
        if patch.transcription and "speaker_count" in patch.transcription.model_fields_set:
            changes.setdefault("transcription", {})["speaker_count"] = patch.transcription.speaker_count
        store.save_settings(changes)
        return public_settings()

    @app.get("/api/meetings")
    def list_meetings():
        return store.list()

    @app.get("/api/recordings/capabilities")
    def recording_capabilities():
        return recording.capabilities()

    @app.get("/api/recordings/current")
    def current_recording():
        return capture.current()

    @app.post("/api/recordings", status_code=201)
    def start_recording(options: RecordingRequest):
        return capture.start(options.model_dump())

    @app.post("/api/recordings/{session_id}/pause")
    def pause_recording(session_id: str):
        return capture.control(session_id, "pause")

    @app.post("/api/recordings/{session_id}/resume")
    def resume_recording(session_id: str):
        return capture.control(session_id, "resume")

    @app.post("/api/recordings/{session_id}/stop")
    def stop_recording(session_id: str):
        return capture.finish(session_id)

    @app.delete("/api/recordings/{session_id}", status_code=204)
    def discard_recording(session_id: str):
        capture.discard(session_id)
        return Response(status_code=204)

    @app.post("/api/meetings", status_code=201)
    async def create_meeting(
        file: UploadFile = File(...),
        title: str = Form("Untitled meeting"),
        language: str = Form("auto"),
        speaker_count: int | None = Form(None),
    ):
        if not title.strip() or len(title) > 240:
            raise HTTPException(422, "Use a title between 1 and 240 characters.")
        if speaker_count is not None and not 1 <= speaker_count <= 20:
            raise HTTPException(422, "Choose between 1 and 20 speakers, or automatic detection.")
        if not re.fullmatch(r"[a-zA-Z-]{2,20}", language):
            raise HTTPException(422, "Use an ISO language code or auto.")
        meeting_id = uuid4().hex
        path = store.audio_dir / meeting_id
        total = 0
        try:
            with path.open("xb") as audio_file:
                os.chmod(path, 0o600)
                while chunk := await file.read(1024 * 1024):
                    total += len(chunk)
                    if total > MAX_AUDIO_BYTES:
                        raise HTTPException(413, "Audio files must be smaller than 2 GB.")
                    audio_file.write(chunk)
            if not total:
                raise HTTPException(422, "The audio file is empty.")
            try:
                with (
                    path.open("rb") as source,
                    av.open(
                        source,
                        options=speech.MEDIA_OPEN_OPTIONS,
                        io_open=speech._deny_external_media,
                    ) as container,
                ):
                    if not container.streams.audio:
                        raise ValueError("No audio")
                    duration = float(container.duration / av.time_base) if container.duration else 0.0
                    if not math.isfinite(duration) or duration < 0:
                        duration = 0.0
            except Exception:
                raise HTTPException(
                    415, "This file could not be read as audio. Try WAV, MP3, M4A, WebM, or FLAC."
                ) from None
            audio_name = Path((file.filename or "recording.webm").replace("\\", "/")).name[:240]
            return store.create(title.strip(), audio_name, language, speaker_count, duration, meeting_id)
        except BaseException:
            path.unlink(missing_ok=True)
            raise
        finally:
            await file.close()

    @app.post("/api/context/link-title")
    async def context_link_title(link: ContextLink):
        return {"title": await link_metadata.page_title(str(link.url))}

    @app.get("/api/meetings/{meeting_id}")
    def read_meeting(meeting_id: str):
        return get_meeting(meeting_id)

    @app.patch("/api/meetings/{meeting_id}")
    def edit_meeting(meeting_id: str, patch: MeetingPatch):
        with job_lock:
            meeting = get_meeting(meeting_id)
            require_idle(meeting)
            changes = patch.model_dump(mode="json", exclude_none=True)
            if patch.segments is not None:
                segments = changes["segments"]
                ids = [segment["id"] for segment in segments]
                if len(set(ids)) != len(ids):
                    raise HTTPException(422, "Transcript segment IDs must be unique.")
                if any(s["end"] > meeting["duration"] + 2 for s in segments):
                    raise HTTPException(422, "Transcript timestamps must fit within the recording.")
                segments.sort(key=lambda s: s["start"])
            if patch.speakers is not None or patch.segments is not None:
                speakers = changes.get("speakers", meeting["speakers"]).copy()
                for segment in changes.get("segments", meeting["segments"]):
                    speakers.setdefault(segment["speaker"], segment["speaker"])
                changes["speakers"] = speakers
                changes.update(
                    summary=None,
                    status="transcribed" if changes.get("segments", meeting["segments"]) else "ready",
                    error=None,
                    progress=100 if changes.get("segments", meeting["segments"]) else 0,
                    stage="Transcript ready"
                    if changes.get("segments", meeting["segments"])
                    else "Ready to transcribe",
                )
            return store.update(meeting_id, **changes)

    @app.delete("/api/meetings/{meeting_id}", status_code=204)
    def delete_meeting(meeting_id: str):
        with job_lock:
            require_idle(get_meeting(meeting_id))
            (store.audio_dir / meeting_id).unlink(missing_ok=True)
            (store.video_dir / meeting_id).unlink(missing_ok=True)
            store.delete(meeting_id)
        return Response(status_code=204)

    @app.get("/api/meetings/{meeting_id}/audio")
    def audio(meeting_id: str):
        meeting = get_meeting(meeting_id)
        path = store.audio_dir / meeting_id
        if not path.is_file():
            raise HTTPException(404, "The audio file is missing from local storage.")
        media_type = mimetypes.guess_type(meeting["audio_name"])[0] or "application/octet-stream"
        if not media_type.startswith(("audio/", "video/")):
            media_type = "application/octet-stream"
        return FileResponse(
            path, media_type=media_type, filename=meeting["audio_name"], content_disposition_type="inline"
        )

    @app.get("/api/meetings/{meeting_id}/video")
    def video(meeting_id: str):
        meeting = get_meeting(meeting_id)
        path = store.video_dir / meeting_id
        if not meeting.get("video_url") or not path.is_file():
            raise HTTPException(404, "The screen recording is missing from local storage.")
        return FileResponse(path, media_type="video/mp4", filename="screen.mp4", content_disposition_type="inline")

    def progress_for(meeting_id):
        def report(progress, stage):
            store.update(meeting_id, progress=max(0, min(100, progress)), stage=stage)

        return report

    def mark_transcription_stopped(meeting_id):
        meeting = store.get(meeting_id)
        restored = "complete" if meeting["summary"] else "transcribed" if meeting["segments"] else "ready"
        return store.update(
            meeting_id, status=restored, stage="Transcription stopped", progress=0, error=None
        )

    def run_transcription(meeting_id, settings, language, speaker_count, cancel_event):
        def report(value, stage):
            with job_lock:
                if not cancel_event.is_set():
                    progress_for(meeting_id)(value, stage)

        try:
            result = speech.transcribe_audio(
                store.audio_dir / meeting_id,
                model_dir,
                settings["model"],
                language,
                speaker_count,
                report,
                cancel_event=cancel_event,
            )
            with job_lock:
                if cancel_event.is_set():
                    raise speech.TranscriptionCancelled("Transcription stopped.")
                if not result["segments"]:
                    store.update(
                        meeting_id,
                        duration=result["duration"],
                        language=result["language"],
                        status="error",
                        progress=100,
                        stage="No speech detected",
                        error="No speech was detected. Your audio is saved. Check the microphone, language, or try a clearer recording.",
                    )
                    return
                store.update(
                    meeting_id,
                    **result,
                    status="transcribed",
                    progress=100,
                    stage="Transcript ready",
                    summary=None,
                    error=None,
                )
        except Exception as error:
            with job_lock:
                if cancel_event.is_set() or isinstance(error, speech.TranscriptionCancelled):
                    mark_transcription_stopped(meeting_id)
                else:
                    store.update(
                        meeting_id, status="error", stage="Transcription failed", error=str(error)[:1000]
                    )
        finally:
            with job_lock:
                if transcription_cancellations.get(meeting_id) is cancel_event:
                    transcription_cancellations.pop(meeting_id, None)
                    transcription_futures.pop(meeting_id, None)

    @app.post("/api/meetings/{meeting_id}/transcribe/cancel", status_code=202)
    def cancel_transcription(meeting_id: str):
        with job_lock:
            meeting = get_meeting(meeting_id)
            event = transcription_cancellations.get(meeting_id)
            if meeting["status"] != "transcribing" or event is None:
                raise HTTPException(409, "This meeting has no active transcription to stop.")
            event.set()
            future = transcription_futures.get(meeting_id)
            if future is not None and future.cancel():
                transcription_cancellations.pop(meeting_id, None)
                transcription_futures.pop(meeting_id, None)
                return mark_transcription_stopped(meeting_id)
            return store.update(meeting_id, stage="Stopping transcription…")

    @app.post("/api/meetings/{meeting_id}/transcribe", status_code=202)
    def transcribe(meeting_id: str, body: TranscribeRequest):
        with job_lock:
            meeting = get_meeting(meeting_id)
            require_idle(meeting)
            if install_state["installing"]:
                raise HTTPException(409, "Wait for model setup to finish.")
            ready = status()
            if not ready.get("ready"):
                raise HTTPException(
                    409, ready.get("detail") or "Download the local speech models in Settings first."
                )
            settings = store.settings()["transcription"]
            language = body.language or meeting["language"] or settings["language"]
            count = (
                body.speaker_count if "speaker_count" in body.model_fields_set else meeting["speaker_count"]
            )
            result = store.update(
                meeting_id,
                status="transcribing",
                progress=0,
                stage="Queued for local transcription",
                error=None,
                speaker_count=count,
            )
            cancel_event = threading.Event()
            transcription_cancellations[meeting_id] = cancel_event
            transcription_futures[meeting_id] = executor.submit(
                run_transcription, meeting_id, settings, language, count, cancel_event
            )
            return result

    def run_summary(meeting_id, meeting, settings, allow_remote):
        try:
            store.update(meeting_id, progress=30, stage="Preparing summary")
            result = summarization.summarize(meeting, settings, allow_remote=allow_remote)
            store.update(
                meeting_id, summary=result, status="complete", progress=100, stage="Summary ready", error=None
            )
        except Exception as error:
            message = (
                str(error)
                if isinstance(error, summarization.SummaryError)
                else "Summary failed. Check the provider configuration and try again."
            )
            store.update(meeting_id, status="error", stage="Summary failed", error=message[:1000])

    @app.post("/api/meetings/{meeting_id}/summary", status_code=202)
    def summarize(meeting_id: str, body: SummaryRequest):
        with job_lock:
            meeting = get_meeting(meeting_id)
            require_idle(meeting)
            if not meeting["segments"]:
                raise HTTPException(409, "Create a transcript before generating a summary.")
            settings = store.settings()["summary"]
            if summarization.is_remote_provider(settings) and not body.allow_remote:
                raise HTTPException(
                    403, "Confirm sharing this transcript with your coding agent's model provider. Audio stays local."
                )
            result = store.update(
                meeting_id, status="summarizing", progress=0, stage="Queued for summary", error=None
            )
            executor.submit(run_summary, meeting_id, meeting, settings, body.allow_remote)
            return result

    @app.get("/api/meetings/{meeting_id}/export")
    def export(meeting_id: str, format: str = "md"):
        if format not in {"md", "json", "txt", "srt"}:
            raise HTTPException(422, "Choose md, json, txt, or srt.")
        meeting = get_meeting(meeting_id)
        name = re.sub(r"[^\w\- ]", "", meeting["title"]).strip()[:100] or "meeting"
        media_type = "application/json" if format == "json" else "text/plain; charset=utf-8"
        return Response(
            export_text(meeting, format),
            media_type=media_type,
            headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}.{format}"},
        )

    @app.get("/api/models/status")
    def models_status():
        return status()

    def run_install(model):
        def progress(value, stage):
            install_state.update(progress=value, detail=stage)

        try:
            speech.install_models(model_dir, model, progress)
            install_state.update(installing=False, progress=100, error=None)
        except Exception as error:
            install_state.update(
                installing=False, error=str(error)[:1000], detail="Model setup failed. Try again."
            )

    @app.post("/api/models/install", status_code=202)
    def install(body: InstallRequest):
        with job_lock:
            if install_state["installing"] or any(m["status"] in BUSY for m in store.list()):
                raise HTTPException(409, "Wait for current processing to finish before installing models.")
            install_state.update(
                installing=True, progress=0, error=None, detail="Preparing local model download"
            )
            store.save_settings({"transcription": {"model": body.model}})
            executor.submit(run_install, body.model)
            return {"status": "installing"}

    frontend_dist = PROJECT_ROOT / "frontend" / "dist"
    if frontend_dist.is_dir():
        app.mount("/", StaticFiles(directory=frontend_dist, html=True), name="frontend")
    else:

        @app.get("/")
        def setup_page():
            return {
                "message": "Build the interface: cd frontend && npm install && npm run build. Then restart Stillnote."
            }

    return app


def run():
    import uvicorn

    uvicorn.run(
        "meeting_app.main:create_app",
        factory=True,
        host="127.0.0.1",
        port=int(os.environ.get("STILLNOTE_PORT", "8765")),
    )


if __name__ == "__main__":
    run()
