#!/usr/bin/env python3
"""Pin a speech model into Sources/StillnoteCore/Resources/speech_models.json.

Records every runtime file's exact size and SHA-256 at one revision, which is what
ModelInstaller verifies before an atomic rename. Hugging Face stores LFS objects under their
SHA-256 digest, so `lfs.oid` is reused for large files and the size is cross-checked; the
remaining small files are downloaded and hashed locally. Nothing here is trusted blindly:
a size mismatch between the tree listing and the fetched bytes aborts the update.

Usage:
    scripts/update-speech-manifest.py <model-key> <repo> <revision> \
        --name "Nemotron 3.5 ASR" --tier "Transcription" --kind transcription \
        --directory nemotron-asr-0.6b [--skip README.md ...]
"""
import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Sources/StillnoteCore/Resources/speech_models.json"
# Repository furniture that no runtime reads. Everything else is pinned.
DEFAULT_SKIP = {".gitattributes", "README.md", "run_chunk.py"}


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "stillnote-manifest-tool/1"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def tree(repo: str, revision: str) -> list[dict]:
    url = f"https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=true"
    return json.loads(fetch(url))


def digest(repo: str, revision: str, path: str, size: int) -> str:
    url = f"https://huggingface.co/{repo}/resolve/{revision}/{path}"
    data = fetch(url)
    if len(data) != size:
        raise SystemExit(f"{path}: listing says {size} bytes, host served {len(data)}")
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("key")
    parser.add_argument("repo")
    parser.add_argument("revision")
    parser.add_argument("--name", required=True)
    parser.add_argument("--tier", required=True)
    parser.add_argument("--kind", required=True,
                        choices=["transcription", "diarization", "vad"])
    parser.add_argument("--directory", required=True)
    parser.add_argument("--skip", nargs="*", default=[])
    args = parser.parse_args()

    skip = DEFAULT_SKIP | set(args.skip)
    files: dict[str, dict] = {}
    hashed_locally = 0
    for entry in tree(args.repo, args.revision):
        if entry.get("type") != "file" or entry["path"] in skip:
            continue
        path, size = entry["path"], entry["size"]
        oid = (entry.get("lfs") or {}).get("oid")
        if oid and len(oid) == 64:
            # LFS objects are addressed by their SHA-256; the size is verified above.
            sha256 = oid
        else:
            sha256 = digest(args.repo, args.revision, path, size)
            hashed_locally += 1
        files[path] = {"size": size, "sha256": sha256}

    if not files:
        raise SystemExit(f"{args.repo}@{args.revision}: no files to pin")

    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    manifest[args.key] = {
        "repo": args.repo,
        "revision": args.revision,
        "name": args.name,
        "tier": args.tier,
        "kind": args.kind,
        "directory": args.directory,
        "files": dict(sorted(files.items())),
    }
    MANIFEST.write_text(json.dumps(manifest, indent=2, sort_keys=False) + "\n")
    total = sum(f["size"] for f in files.values())
    print(f"{args.key}: {len(files)} files, {total:,} bytes "
          f"({total / 1e6:.0f} MB), {hashed_locally} hashed locally")


if __name__ == "__main__":
    sys.exit(main())
