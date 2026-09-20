#!/usr/bin/env python3
"""Build an offline wheel archive for CPython 3.13 / macOS 15+ / Apple silicon.

Run with Python 3.13 and pip, build, packaging installed. Only the two source
packages are built here; every other dependency must supply a compatible wheel.
"""
import argparse
import hashlib
import json
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

from packaging.tags import compatible_tags, cpython_tags, mac_platforms
from packaging.utils import canonicalize_name, parse_wheel_filename

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def validate_wheels(wheels, expected):
    platforms = list(mac_platforms((15, 0), "arm64"))
    supported = set(cpython_tags((3, 13), platforms=platforms))
    supported.update(compatible_tags((3, 13), interpreter="cp313", platforms=platforms))
    found = {}
    for wheel in wheels:
        name, version, _, tags = parse_wheel_filename(wheel.name)
        if not tags & supported:
            raise ValueError(f"Not compatible with Python 3.13 / macOS 15 arm64: {wheel.name}")
        if name in found:
            raise ValueError(f"Duplicate wheel: {name}")
        found[name] = str(version)
    if set(found) != set(expected):
        raise ValueError(f"Wheel inventory mismatch: {set(found) ^ set(expected)}")
    for name, version in expected.items():
        if version is not None and found[name] != version:
            raise ValueError(f"Unexpected version: {name} {found[name]} != {version}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/candidate")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64" or sys.version_info[:2] != (3, 13):
        parser.error("Build using Python 3.13 on an Apple silicon Mac")
    version = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="stillnote-runtime-") as temporary:
        work = Path(temporary)
        payload = work / "runtime"
        wheels = payload / "wheels"
        wheels.mkdir(parents=True)
        expected, binary, source = {"stillnote-moss-worker": None}, [], []
        for line in (ROOT / "requirements-moss.lock").read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            match = re.fullmatch(r"([\w-]+)==([^\s]+)", line)
            if match:
                expected[canonicalize_name(match[1])] = match[2]
                binary.append(line)
            elif re.fullmatch(r"mlx-audio @ git\+https://github.com/Blaizzy/mlx-audio.git@[0-9a-f]{40}", line):
                expected["mlx-audio"] = None
                source.append(line)
            else:
                raise ValueError(f"Unpinned or unsupported requirement: {line}")
        requirements = work / "binary.txt"
        requirements.write_text("\n".join(binary) + "\n")
        run(sys.executable, "-m", "pip", "download", "--only-binary=:all:", "--no-deps",
            "--platform", "macosx_15_0_arm64", "--python-version", "3.13", "--implementation", "cp",
            "--abi", "cp313", "--dest", wheels, "-r", requirements)
        for requirement in [*source, str(ROOT / "sidecar")]:
            run(sys.executable, "-m", "pip", "wheel", "--no-deps", "--wheel-dir", wheels, requirement)
        inventory = sorted(wheels.glob("*.whl"))
        validate_wheels(inventory, expected)
        # Retain all upstream wheel contents, including license files. Also check
        # native deployment targets: wheel filenames alone are not sufficient.
        for wheel in inventory:
            with zipfile.ZipFile(wheel) as archive:
                for entry in archive.infolist():
                    if not entry.filename.endswith((".so", ".dylib")):
                        continue
                    native = work / "native"
                    native.write_bytes(archive.read(entry))
                    output = subprocess.check_output(["otool", "-arch", "arm64", "-l", str(native)], text=True)
                    # Only deployment commands, not dylib compatibility versions.
                    blocks = re.split(r"Load command \d+", output)
                    minima = []
                    for block in blocks:
                        field = "minos" if "LC_BUILD_VERSION" in block else "version"
                        if "LC_BUILD_VERSION" in block or "LC_VERSION_MIN_MACOSX" in block:
                            minima.extend(re.findall(rf"^\s*{field} (\d+\.\d+(?:\.\d+)?)", block, re.MULTILINE))
                    if not minima or any(tuple(map(int, m.split(".")[:2])) > (15, 0) for m in minima):
                        raise ValueError(f"Unsupported deployment target in {wheel.name}: {entry.filename} {minima}")
        locked = []
        for wheel in inventory:
            digest = hashlib.sha256(wheel.read_bytes()).hexdigest()
            locked.append(f"./wheels/{wheel.name} --hash=sha256:{digest}")
        (payload / "requirements.txt").write_text("\n".join(locked) + "\n")
        (payload / "manifest.json").write_text(json.dumps({
            "version": version, "python": "3.13", "platform": "macos-15-arm64",
            "source_lock_sha256": hashlib.sha256((ROOT / "requirements-moss.lock").read_bytes()).hexdigest(),
            "wheels": [wheel.name for wheel in inventory],
        }, indent=2) + "\n")
        for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "requirements-moss.lock"]:
            shutil.copy2(ROOT / name, payload / name)
        shutil.copytree(ROOT / "packaging/licenses", payload / "licenses")
        shutil.copy2(ROOT / "scripts/runtime-smoke.py", payload / "runtime-smoke.py")
        env = work / "verify"
        run(sys.executable, "-m", "venv", env)
        python = env / "bin/python"
        run(python, "-m", "pip", "install", "--no-index", "--no-deps", "--require-hashes",
            "-r", "requirements.txt", cwd=payload)
        run(python, "-m", "pip", "check")
        run(python, payload / "runtime-smoke.py")
        destination = args.output / f"Stillnote-runtime-{version}-macos-arm64.tar.gz"
        with tarfile.open(destination, "w:gz") as archive:
            archive.add(payload, arcname="stillnote-runtime")
        print(destination)


if __name__ == "__main__":
    main()
