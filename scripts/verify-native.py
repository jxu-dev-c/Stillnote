#!/usr/bin/env python3
"""Maintainer acceptance test: synthetic speech, relocated app, offline native inference.

Requires a built app, macOS voices Samantha/Daniel, and the downloaded native model.
Python orchestrates testing only; it is never packaged or allowed in the worker sandbox.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "build/native-validation"
OUTPUT.mkdir(parents=True, exist_ok=True)
TURNS = [('Samantha',
  'Good morning everyone. Today we are reviewing the product launch. The design team has finished '
  'the first prototype and collected feedback from twelve customers. Most people found the new '
  'navigation easier to understand. We still need to improve the search page before Friday. '
  'Daniel, could you give us an update on the engineering work?'),
 ('Daniel',
  'Thank you. The engineering team has completed the database changes and the new login screen. We '
  'found two problems during testing yesterday. The first problem affects large uploads, and the '
  'second problem is a slow response on older computers. I expect both fixes to be ready tomorrow '
  'afternoon. After that we can ask the support team to test the release.'),
 ('Samantha',
  'That sounds good. Please send the test results before our next meeting. I will update the '
  'launch checklist and ask the designers to review the search changes. We should also prepare a '
  'short announcement for customers explaining the improvements. The launch date is still next '
  'Monday, provided the final tests pass.'),
 ('Daniel',
  'I agree with that schedule. I will send the results tomorrow and include a list of any '
  'remaining issues. We should keep the old version available for a few days in case customers '
  'need help. Thank you for the update. I will see you at the next planning meeting.')]


def speech(voice, text, destination):
    subprocess.run(["say", "-v", voice, "-r", "145", "-o", str(destination),
                    "--file-format=WAVE", "--data-format=LEF32@16000", text], check=True)
    data = destination.read_bytes()
    position = 12
    while position < len(data):
        name, size = struct.unpack_from("<4sI", data, position)
        position += 8
        if name == b"data":
            return data[position:position + size]
        position += size + size % 2
    raise AssertionError("Missing WAV samples")


def main():
    models = Path(os.environ.get("STILLNOTE_MODEL_DIR", str(Path.home() / "Library/Application Support/Stillnote/models")))
    model = models / "speech/moss-0.9b-mlx-8bit"
    spec = json.loads((ROOT / "Sources/StillnoteCore/Resources/speech_models.json").read_text())["moss-0.9b"]
    assert (model / ".verified").read_text() == spec["revision"], "Download the native model in Settings first"
    for name, expected in spec["files"].items():
        file = model / name
        assert file.stat().st_size == expected["size"], name
        digest = hashlib.sha256()
        with file.open("rb") as stream:
            while block := stream.read(1024 * 1024):
                digest.update(block)
        assert digest.hexdigest() == expected["sha256"], name

    with tempfile.TemporaryDirectory(prefix="stillnote-offline-") as temporary:
        directory = Path(temporary).resolve()
        app = directory / "Stillnote.app"
        subprocess.run(["ditto", str(ROOT / "build/Stillnote.app"), str(app)], check=True)
        worker = app / "Contents/MacOS/StillnoteSpeechWorker"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        for executable in [worker, app / "Contents/MacOS/Stillnote"]:
            libraries = subprocess.check_output(["otool", "-L", str(executable)], text=True)
            assert all(line.strip().startswith(("/usr/lib/", "/System/Library/"))
                       for line in libraries.splitlines()[1:]), libraries
        profile = directory / "offline.sb"
        profile.write_text(f'(version 1)\n(allow default)\n(deny network*)\n'
                           f'(deny file-read* (subpath "{ROOT}"))\n'
                           f'(deny process-exec)\n(allow process-exec (literal "{worker}"))\n')
        prefix = ["/usr/bin/sandbox-exec", "-f", str(profile), str(worker)]
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(directory), "TMPDIR": str(directory)}
        subprocess.run(prefix + ["--self-test"], env=environment, cwd=directory, check=True, capture_output=True)
        summary = {}
        short = speech("Samantha", "Hello world. This is a local transcription test. We will meet on Monday to review the project.", directory / "short.wav")
        multi = b"".join(speech(voice, text, directory / f"turn-{index}.wav") + bytes(64000)
                         for index, (voice, text) in enumerate(TURNS))
        for name, audio, speakers in [("short", short, 1), ("multi", multi, 2)]:
            pcm = directory / f"{name}.f32"
            pcm.write_bytes(audio)
            started = time.monotonic()
            run = subprocess.run(["/usr/bin/time", "-l"] + prefix + [str(pcm), str(model), "en", "0"],
                                 env=environment, cwd=directory, text=True, capture_output=True, timeout=180)
            (OUTPUT / f"offline-{name}.log").write_text(run.stdout + run.stderr)
            assert run.returncode == 0, run.stderr + run.stdout
            events = [json.loads(line.removeprefix("STILLNOTE_EVENT ")) for line in run.stdout.splitlines()
                      if line.startswith("STILLNOTE_EVENT ")]
            results = [event["text"] for event in events if event["type"] == "result"]
            assert len(results) == 1
            text = results[0]
            assert len(set(re.findall(r"\[S[0-9]+\]", text))) == speakers, text
            times = [float(value) for value in re.findall(r"\[([0-9]+(?:\.[0-9]+)?)\]", text)]
            duration = len(audio) / 64000
            assert max(times) >= duration * 0.95 and max(times) <= duration + 1, text
            assert "\ufffd" not in text
            if name == "multi":
                assert any("3/3" in event.get("detail", "") for event in events)
                # The alternating voices must keep the same identity across encoder windows.
                ids = re.findall(r"\[S([0-9]+)\]", text)
                runs = [value for index, value in enumerate(ids) if index == 0 or value != ids[index - 1]]
                assert runs == ["01", "02", "01", "02"], runs
            else:
                assert "hello world" in text.lower() and "monday" in text.lower(), text
            memory = int(re.search(r"([0-9]+)\s+peak memory footprint", run.stderr)[1])
            summary[name] = {"audio_seconds": duration, "elapsed_seconds": time.monotonic() - started,
                             "speakers": speakers, "peak_memory_bytes": memory}

        # The app's actual service must terminate its own packaged worker on cancellation.
        with wave.open(str(directory / "multi.wav"), "wb") as stream:
            stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(16000)
            stream.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, int(value[0] * 32767))))
                                        for value in struct.iter_unpack("<f", multi)))
        test_env = dict(os.environ, STILLNOTE_INTEGRATION="1", STILLNOTE_MODEL_DIR=str(models),
                        STILLNOTE_TEST_WORKER=str(worker), STILLNOTE_INTEGRATION_AUDIO=str(directory / "multi.wav"),
                        STILLNOTE_HOT_WORDS_AUDIO=str(directory / "short.wav"))
        test = subprocess.run(["swift", "test", "--no-parallel", "--filter", "TranscriptionIntegrationTests"],
                              cwd=ROOT, env=test_env, text=True, capture_output=True, timeout=300)
        (OUTPUT / "packaged-service-tests.log").write_text(test.stdout + test.stderr)
        assert test.returncode == 0, test.stdout + test.stderr
        diagnose = subprocess.run([str(app / "Contents/MacOS/Stillnote"), "--diagnose"],
                                  cwd=directory, text=True, capture_output=True, timeout=30)
        assert diagnose.returncode == 0 and "Transcription:   ready" in diagnose.stdout, diagnose.stdout
        summary["checks"] = ["signature", "system libraries only", "offline", "checkout denied", "child execution denied",
                             "full service transcription", "hot words", "silence", "cancellation", "relocated app diagnostics"]
        (OUTPUT / "acceptance.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
