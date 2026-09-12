"""Native capture subprocess lifecycle and recoverable, bounded-memory audio mixing."""

import heapq
import json
import os
import platform
import shutil
import subprocess
import threading
import wave
from contextlib import ExitStack
from pathlib import Path
from uuid import uuid4

import av
import numpy as np

RATE = 48_000
MAX_SECONDS = 90 * 60
HELPER = Path(__file__).resolve().parents[2] / "native/build/Stillnote Capture.app/Contents/MacOS/stillnote-capture"
ACTIVE = {"starting", "recording", "paused", "stopping"}


class RecordingError(Exception):
    def __init__(self, message, status=409):
        super().__init__(message)
        self.status = status


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as target:
        os.chmod(temporary, 0o600)
        json.dump(value, target)
    temporary.replace(path)


def capabilities():
    result = {"available": False, "microphones": [], "displays": [], "default_display_id": None}
    if platform.system() != "Darwin" or int(platform.mac_ver()[0].split(".")[0] or 0) < 15:
        return {**result, "reason": "Native capture requires macOS 15 or newer. Browser recording is available."}
    if not HELPER.is_file() or not os.access(HELPER, os.X_OK):
        return {**result, "reason": "Build the native helper with ./scripts/build-capture.sh, then refresh devices."}
    try:
        response = subprocess.run([str(HELPER), "devices"], capture_output=True, text=True, timeout=10)
        if response.returncode:
            raise ValueError("Device discovery failed")
        return {**result, **json.loads(response.stdout), "available": True, "reason": None}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {**result, "reason": "Could not list native devices. Rebuild the capture helper and retry."}


def mix_audio(directory, destination):
    """Mix time-aligned PCM files in one-second blocks; never load a meeting into RAM."""
    with ExitStack() as stack:
        inputs = []
        for name in ("microphone.wav", "system.wav"):
            path = directory / name
            if not path.is_file() or path.stat().st_size <= 44:
                continue
            try:
                source = stack.enter_context(wave.open(str(path), "rb"))
            except (wave.Error, EOFError):
                raise RecordingError("A captured audio file is damaged. The original files remain on disk.", 422) from None
            if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, RATE):
                raise RecordingError("The captured audio format is invalid. The original files remain on disk.", 422)
            inputs.append(source)
        if not inputs:
            raise RecordingError("No audio was captured. Check microphone permissions and start a new recording.", 422)
        frames = max(source.getnframes() for source in inputs)
        if frames > RATE * (MAX_SECONDS + 2):
            raise RecordingError("The captured audio exceeds the recording limit.", 422)
        with wave.open(str(destination), "wb") as output:
            os.chmod(destination, 0o600)
            output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
            for offset in range(0, frames, RATE):
                length = min(RATE, frames - offset)
                mixed = np.zeros(length, dtype=np.int32)
                for source in inputs:
                    samples = np.frombuffer(source.readframes(length), dtype="<i2")
                    mixed[:len(samples)] += samples
                # Equal gain leaves headroom even with both voices at full scale.
                output.writeframes((mixed / len(inputs)).clip(-32768, 32767).astype("<i2").tobytes())
        return frames / RATE


def mux_screen(screen, audio, destination):
    """Copy H.264 screen frames and interleave mixed AAC audio without buffering the movie."""
    with av.open(str(screen)) as picture, av.open(str(audio)) as sound, av.open(str(destination), "w", format="mp4") as output:
        if not picture.streams.video:
            raise ValueError("No video stream")
        video = output.add_stream_from_template(picture.streams.video[0])
        voice = output.add_stream("aac", rate=RATE)
        voice.layout = "mono"
        voice.bit_rate = 128_000
        resampler = av.AudioResampler(format="fltp", layout="mono", rate=RATE)

        def video_packets():
            for packet in picture.demux(video=0):
                if packet.dts is not None:
                    packet.stream = video
                    yield packet

        def audio_packets():
            for frame in sound.decode(audio=0):
                for converted in resampler.resample(frame):
                    yield from voice.encode(converted)
            for converted in resampler.resample(None):
                yield from voice.encode(converted)
            yield from voice.encode(None)

        for packet in heapq.merge(video_packets(), audio_packets(), key=lambda packet: packet.dts * packet.time_base):
            output.mux(packet)
    os.chmod(destination, 0o600)


class RecordingManager:
    def __init__(self, store):
        self.store = store
        self.directory = store.directory / "recordings"
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock = threading.RLock()
        self.operation = threading.RLock()
        self.process = None
        self.reader = None
        self.session = None
        self.closing = False
        self._recover()

    def _recover(self):
        for path in sorted(self.directory.glob("*/session.json")):
            try:
                session = json.loads(path.read_text())
                if session["id"] != path.parent.name:
                    continue
                try:
                    self.store.get(session["id"])
                except KeyError:
                    self.session = {**session, "status": "stopped", "levels": {},
                                    "error": "Recording was interrupted. Save the captured audio or discard it."}
                    return
                else:
                    shutil.rmtree(path.parent)
            except (OSError, ValueError, KeyError):
                continue

    def _persist(self):
        write_json(self.directory / self.session["id"] / "session.json", self.session)

    def current(self):
        with self.lock:
            return dict(self.session) if self.session else None

    def _require(self, session_id):
        if not self.session or self.session["id"] != session_id:
            raise RecordingError("This recording session was not found.", 404)

    def start(self, options):
        with self.operation, self.lock:
            if self.closing:
                raise RecordingError("The server is shutting down.")
            if self.session:
                raise RecordingError("Save or discard the current recording before starting another.")
            available = capabilities()
            if not available["available"]:
                raise RecordingError(available["reason"], 503)
            if options["microphone_id"] and options["microphone_id"] not in {d["id"] for d in available["microphones"]}:
                raise RecordingError("That microphone is no longer available. Refresh devices and retry.", 422)
            options = dict(options)
            options["display_id"] = options["display_id"] or available["default_display_id"]
            if options["display_id"] not in {d["id"] for d in available["displays"]}:
                raise RecordingError("That display is no longer available. Refresh devices and retry.", 422)
            session_id = uuid4().hex
            directory = self.directory / session_id
            directory.mkdir(mode=0o700)
            write_json(directory / "options.json", options)
            self.session = {"id": session_id, "status": "starting", "elapsed": 0, "levels": {},
                            "error": None, "options": options}
            self._persist()
            try:
                self.process = subprocess.Popen(
                    [str(HELPER), "record", str(directory)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, text=True, bufsize=1,
                )
            except OSError:
                self.session = None
                shutil.rmtree(directory)
                raise RecordingError("The native capture helper could not start. Rebuild it and retry.", 503) from None
            self.reader = threading.Thread(target=self._read, args=(self.process, session_id), daemon=True)
            self.reader.start()
            return dict(self.session)

    def _read(self, process, session_id):
        try:
            for line in process.stdout:
                try:
                    event = json.loads(line)
                    with self.lock:
                        if not self.session or self.session["id"] != session_id:
                            break
                        if event.get("event") == "state" and event.get("status") in ACTIVE | {"stopped"}:
                            self.session.update({key: event[key] for key in ("status", "elapsed", "error") if key in event})
                            self._persist()
                        elif event.get("event") == "levels":
                            self.session.update(levels=event.get("levels", {}), elapsed=event.get("elapsed", 0))
                except (ValueError, TypeError):
                    continue
        finally:
            process.stdout.close()
            process.wait()
            with self.lock:
                if self.session and self.session["id"] == session_id:
                    if self.session["status"] != "stopped":
                        self.session.update(status="stopped", error="Native capture exited unexpectedly. Save the captured audio or discard it.")
                    self.session["levels"] = {}
                    self._persist()

    def _send(self, command):
        if self.process and self.process.poll() is None:
            try:
                self.process.stdin.write(command + "\n")
                self.process.stdin.flush()
            except (BrokenPipeError, OSError):
                raise RecordingError("The capture helper stopped. Save the captured audio or discard it.") from None

    def control(self, session_id, command):
        with self.operation, self.lock:
            self._require(session_id)
            expected = "recording" if command == "pause" else "paused"
            target = "paused" if command == "pause" else "recording"
            if self.session["status"] == target:
                return dict(self.session)
            if self.session["status"] != expected:
                raise RecordingError(f"Cannot {command} a recording while it is {self.session['status']}.")
            self._send(command)
            # The helper emits the authoritative state after applying the command.
            return dict(self.session)

    def _stop_process(self):
        process = self.process
        if process:
            if process.poll() is None:
                try:
                    self._send("stop")
                except RecordingError:
                    pass
                # EOF also stops capture, including when it is waiting for OS permissions.
                process.stdin.close()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=3)
            if self.reader:
                self.reader.join(timeout=5)
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            self.process = None
        with self.lock:
            if self.session:
                self.session["status"] = "stopped"
                self._persist()

    def finish(self, session_id):
        with self.operation:
            # Idempotent retries avoid duplicates if the HTTP response was lost.
            try:
                return self.store.get(session_id)
            except KeyError:
                pass
            with self.lock:
                self._require(session_id)
            self._stop_process()
            with self.lock:
                session = dict(self.session)
            directory = self.directory / session_id
            audio = self.store.audio_dir / session_id
            temporary = directory / "mixed.wav"
            duration = mix_audio(directory, temporary)
            warning = session.get("error")
            screen = directory / "screen.mp4"
            video_name = None
            if session["options"]["screen_video"]:
                try:
                    with av.open(str(screen)) as container:
                        if not container.streams.video or not next(container.decode(video=0), None):
                            raise ValueError("No video frames")
                    video_name = "screen.mp4"
                    mux_screen(screen, temporary, self.store.video_dir / session_id)
                except (OSError, ValueError, av.FFmpegError):
                    video_name = None
                    (self.store.video_dir / session_id).unlink(missing_ok=True)
                    warning = "Screen video could not be recovered. Your audio was saved."
            temporary.replace(audio)
            options = session["options"]
            try:
                meeting = self.store.create(options["title"], "recording.wav", options["language"],
                                            options["speaker_count"], duration, session_id,
                                            video_name=video_name, error=warning)
            except Exception:
                # Keep the source session available for a retry if database persistence fails.
                audio.unlink(missing_ok=True)
                (self.store.video_dir / session_id).unlink(missing_ok=True)
                raise
            with self.lock:
                self.session = None
            shutil.rmtree(directory)
            self._recover()
            return meeting

    def discard(self, session_id):
        with self.operation:
            with self.lock:
                self._require(session_id)
            self._stop_process()
            shutil.rmtree(self.directory / session_id)
            with self.lock:
                self.session = None
            self._recover()

    def close(self):
        with self.operation:
            self.closing = True
            self._stop_process()
