"""Fetch the pinned official sherpa-onnx iOS binary, validating its release digest."""
import hashlib
import json
import argparse
import subprocess
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.12.20"
NAME = f"sherpa-onnx-v{VERSION}-ios-no-tts.tar.bz2"
SHA256 = "09fd8d60340ccc191a70abb8c896695cdb4cf0511137fe4db6428d90bc1a70c2"
URL = f"https://github.com/k2-fsa/sherpa-onnx/releases/download/v{VERSION}/{NAME}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["ios", "macos"], default="ios")
    args = parser.parse_args()
    name, expected = NAME, SHA256
    if args.platform == "macos":
        name = f"sherpa-onnx-v{VERSION}-osx-universal2-shared-no-tts.tar.bz2"
        expected = "1d0f6fdda1f8d9d785be70359f62f56c135016711ee739e9616861e47e00fc7c"
    cache = ROOT / "output" / "vad-runtime"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / name
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        partial = cache / (name + ".partial")
        url = f"https://github.com/k2-fsa/sherpa-onnx/releases/download/v{VERSION}/{name}"
        subprocess.run(["curl", "--fail", "--location", "--connect-timeout", "20", "--max-time", "300",
                        "--retry", "2", "--output", str(partial), url], check=True)
        if hashlib.sha256(partial.read_bytes()).hexdigest() != expected:
            raise RuntimeError("sherpa-onnx download digest does not match the official release")
        partial.replace(archive)
    destination = cache / ("sherpa-onnx-" + VERSION + "-" + args.platform)
    marker = destination / "runtime.json"
    if not marker.exists():
        destination.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive, "r:bz2") as source:
            source.extractall(destination, filter="data")
        files = [str(path.relative_to(destination)) for path in destination.rglob("*") if path.is_file()]
        marker.write_text(json.dumps({"version": VERSION, "sha256": expected, "files": files}, indent=2), encoding="utf-8")
    manifest = json.loads(marker.read_text(encoding="utf-8"))
    for name in manifest["files"]:
        if name.endswith((".a", ".dylib", "c-api.h", "module.modulemap")):
            print(name)


if __name__ == "__main__":
    main()
