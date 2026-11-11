"""Compile the classroom iOS client with Xcode and package it for device signing."""

import argparse
import plistlib
import shutil
import subprocess
import sys
import tempfile
import hashlib
import json
import platform
from pathlib import Path
from vad_build_support import ios_runtime_arguments

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ios" / "ClassroomApp"
MINIMUM_IOS = "15.0"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Path to a new .ipa file")
    parser.add_argument("--simulator", action="store_true", help="Compile for a local iOS simulator instead of an iPhone")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.exit(1, "An iPhoneOS SDK from Xcode on macOS is required. No IPA was written.\n")

    output = args.output.resolve()
    if output.suffix.lower() != ".ipa" or output.exists():
        parser.error("Output must be a new .ipa file.")
    sdk_name = "iphonesimulator" if args.simulator else "iphoneos"
    architecture = platform.machine() if args.simulator else "arm64"
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True
    ).strip()
    subprocess.run([sys.executable, str(ROOT / "tools" / "prepare-vad-runtime.py")], check=True)
    vad_arguments = ios_runtime_arguments(ROOT / "output" / "vad-runtime" / "sherpa-onnx-1.12.20-ios", args.simulator, architecture)
    model = SOURCE / "VADAssets" / "silero_vad.int8.onnx"
    if hashlib.sha256(model.read_bytes()).hexdigest() != "c36d490aff5ab924ca6c7aeec4d8f6bd3d22db6fa17611b9c5b17eae58ac3a20":
        raise RuntimeError("Silero model integrity check failed")
    with tempfile.TemporaryDirectory(prefix="classroom-ios-") as temporary:
        root = Path(temporary)
        bundle = root / "Payload" / "ClassroomApp.app"
        bundle.mkdir(parents=True)
        shutil.copytree(SOURCE / "MathAssets", bundle / "MathAssets")
        shutil.copy2(ROOT / "ios" / "Vendor" / "ZIPFoundation" / "LICENSE", bundle / "ZIPFoundation-LICENSE.txt")
        shutil.copy2(model, bundle / model.name)
        shutil.copytree(SOURCE / "VADAssets", bundle / "VADAssets")
        executable = bundle / "ClassroomApp"
        swift_sources = [str(p) for p in sorted(SOURCE.glob("*.swift"))]
        swift_sources += [str(p) for p in sorted((ROOT / "ios" / "Vendor" / "ZIPFoundation").glob("*.swift"))]
        try:
            subprocess.run(
                [
                    "xcrun", "--sdk", sdk_name, "swiftc", "-sdk", sdk,
                    "-target", f"{architecture}-apple-ios{MINIMUM_IOS}" + ("-simulator" if args.simulator else ""), "-O", "-parse-as-library",
                    "-module-name", "ClassroomApp",
                    *swift_sources,
                    *vad_arguments,
                    "-o", str(executable),
                ],
                capture_output=True,
                text=True,
                check=True,
            )
        except subprocess.CalledProcessError as err:
            if err.stderr:
                for line in err.stderr.splitlines():
                    print(f"::error::{line}", file=sys.stderr)
            raise
        with (SOURCE / "Info.plist").open("rb") as file:
            info = plistlib.load(file)
        info.update(MinimumOSVersion=MINIMUM_IOS, CFBundleSupportedPlatforms=["iPhoneSimulator" if args.simulator else "iPhoneOS"])
        with (bundle / "Info.plist").open("wb") as file:
            plistlib.dump(info, file)
        manifest = {
            "version": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"],
            "bundle_id": info["CFBundleIdentifier"],
            "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "baseline_commit": "a3daa14594bb101b5016707ca61e2b44ddddc7dd",
            "baseline_version": "1.4.3 (22)",
            "silero_model_sha256": hashlib.sha256(model.read_bytes()).hexdigest(),
            "sherpa_onnx_version": "1.12.20",
            "platform": sdk_name,
        }
        (bundle / "ClassroomBuild.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        if args.simulator:
            subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
        subprocess.run(["xcrun", "vtool", "-show-build", str(executable)], check=True)
        archive = root / "classroom.ipa"
        subprocess.run(
            ["ditto", "-c", "-k", "--keepParent", str(bundle.parent), str(archive)],
            check=True,
        )
        output.parent.mkdir(parents=True, exist_ok=True)
        with archive.open("rb") as source, output.open("xb") as destination:
            shutil.copyfileobj(source, destination)
        manifest["ipa_sha256"] = hashlib.sha256(output.read_bytes()).hexdigest()
        output.with_suffix(".json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"{output} (requires device signing)")


if __name__ == "__main__":
    main()
