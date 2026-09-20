#!/usr/bin/env python3
"""Generate paired tap definitions from built, checksummed release assets."""
import hashlib
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    version = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
    candidate = ROOT / "build/candidate"
    assets = [f"Stillnote-{version}-macos-arm64.zip", f"Stillnote-runtime-{version}-macos-arm64.tar.gz",
              "Install-Stillnote.sh"]
    hashes = {name: hashlib.sha256((candidate / name).read_bytes()).hexdigest() for name in assets}
    values = {"VERSION": version, "APP_SHA256": hashes[assets[0]], "RUNTIME_SHA256": hashes[assets[1]]}
    for kind, name in [("Casks", "stillnote"), ("Formula", "stillnote-runtime")]:
        destination = candidate / "homebrew" / kind / f"{name}.rb"
        destination.parent.mkdir(parents=True, exist_ok=True)
        content = (ROOT / "packaging/homebrew" / f"{name}.rb.in").read_text()
        for key, value in values.items():
            content = content.replace(f"@{key}@", value)
        destination.write_text(content)
    import tarfile
    tap_archive = candidate / "Stillnote-homebrew.tar.gz"
    with tarfile.open(tap_archive, "w:gz") as archive:
        archive.add(candidate / "homebrew", arcname="homebrew")
    hashes[tap_archive.name] = hashlib.sha256(tap_archive.read_bytes()).hexdigest()
    (candidate / "SHA256SUMS").write_text("".join(f"{digest}  {name}\n" for name, digest in hashes.items()))


if __name__ == "__main__":
    main()
