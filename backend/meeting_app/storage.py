"""Local SQLite store for recordings, meeting content, and preferences."""

import json
import os
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from .agents import DEFAULT_EFFORT, DEFAULT_MODELS, DEFAULT_PROVIDER

DEFAULT_SETTINGS = {
    "transcription": {"model": "moss-0.9b", "language": "auto", "speaker_count": None},
    "summary": {
        "provider": DEFAULT_PROVIDER,
        "model": DEFAULT_MODELS[DEFAULT_PROVIDER],
        "reasoning_effort": DEFAULT_EFFORT,
    },
}
BUSY = {"transcribing", "summarizing"}


def now():
    return datetime.now(timezone.utc).isoformat()


class Store:
    def __init__(self, directory: Path):
        self.directory = directory
        self.audio_dir = directory / "audio"
        self.audio_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.video_dir = directory / "video"
        self.video_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = directory / "stillnote.sqlite3"
        self.lock = threading.RLock()
        with self.db() as db:
            db.execute("CREATE TABLE IF NOT EXISTS meetings (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY, data TEXT NOT NULL)")
        os.chmod(self.path, 0o600)
        # Jobs cannot survive a process restart; make interrupted work visibly retryable.
        for meeting in self.list():
            if meeting["status"] in BUSY:
                self.update(
                    meeting["id"],
                    status="error",
                    stage="Interrupted",
                    error="The app stopped during processing. Your audio is safe; retry the operation.",
                )

    @contextmanager
    def db(self):
        with self.lock:
            connection = sqlite3.connect(self.path, timeout=30)
            try:
                yield connection
                connection.commit()
            finally:
                connection.close()

    def list(self):
        with self.db() as db:
            items = [json.loads(row[0]) for row in db.execute("SELECT data FROM meetings")]
        for item in items:
            item.setdefault("context_links", [])
            item.setdefault("video_url", None)
        return sorted(items, key=lambda item: item["created_at"], reverse=True)

    def get(self, meeting_id):
        with self.db() as db:
            row = db.execute("SELECT data FROM meetings WHERE id=?", (meeting_id,)).fetchone()
        if row is None:
            raise KeyError(meeting_id)
        meeting = json.loads(row[0])
        meeting.setdefault("context_links", [])
        meeting.setdefault("video_url", None)
        return meeting

    def create(self, title, audio_name, language, speaker_count, duration, meeting_id=None, video_name=None, error=None):
        meeting_id = meeting_id or uuid4().hex
        meeting = dict(
            id=meeting_id,
            title=title,
            created_at=now(),
            updated_at=now(),
            duration=duration,
            status="ready",
            progress=0,
            stage="Ready to transcribe",
            error=error,
            audio_name=audio_name,
            audio_url=f"/api/meetings/{meeting_id}/audio",
            video_url=f"/api/meetings/{meeting_id}/video" if video_name else None,
            language=language,
            speaker_count=speaker_count,
            speakers={},
            segments=[],
            summary=None,
            notes="",
            context_links=[],
        )
        with self.db() as db:
            db.execute("INSERT INTO meetings VALUES (?, ?)", (meeting_id, json.dumps(meeting)))
        return meeting

    def update(self, meeting_id, **changes):
        with self.lock:
            meeting = self.get(meeting_id)
            meeting.update(changes, updated_at=now())
            with self.db() as db:
                db.execute("UPDATE meetings SET data=? WHERE id=?", (json.dumps(meeting), meeting_id))
            return meeting

    def delete(self, meeting_id):
        with self.db() as db:
            db.execute("DELETE FROM meetings WHERE id=?", (meeting_id,))

    def settings(self):
        with self.lock:
            with self.db() as db:
                row = db.execute("SELECT data FROM settings WHERE id=1").fetchone()
            settings = json.loads(row[0]) if row else json.loads(json.dumps(DEFAULT_SETTINGS))
            original = json.dumps(settings)
            if settings["transcription"]["model"] in {"tiny", "base", "small", "tiny.en", "base.en", "small.en"}:
                settings["transcription"]["model"] = "moss-0.9b"
            summary = settings.get("summary", {})
            provider = summary.get("provider", DEFAULT_PROVIDER)
            if provider not in DEFAULT_MODELS:
                provider = "claude-code" if provider == "anthropic" else DEFAULT_PROVIDER
                summary = {}
            # Replace retired API settings, including keys, while keeping saved
            # meeting summaries and all unrelated preferences untouched.
            settings["summary"] = {
                "provider": provider,
                "model": summary.get("model") or DEFAULT_MODELS[provider],
                "reasoning_effort": summary.get("reasoning_effort") or DEFAULT_EFFORT,
            }
            if json.dumps(settings) != original:
                with self.db() as db:
                    db.execute("INSERT OR REPLACE INTO settings VALUES (1, ?)", (json.dumps(settings),))
            return settings

    def save_settings(self, changes):
        with self.lock:
            settings = self.settings()
            for section, values in changes.items():
                if (
                    section == "summary"
                    and values.get("provider", settings[section]["provider"]) != settings[section]["provider"]
                ):
                    settings[section]["model"] = DEFAULT_MODELS[values["provider"]]
                settings[section].update(values)
                if section == "summary" and not settings[section]["model"]:
                    settings[section]["model"] = DEFAULT_MODELS[settings[section]["provider"]]
            with self.db() as db:
                db.execute("INSERT OR REPLACE INTO settings VALUES (1, ?)", (json.dumps(settings),))
            return settings
