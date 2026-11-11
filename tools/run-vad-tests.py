"""Run production Swift VAD against the same pinned sherpa runtime on macOS."""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    subprocess.run([sys.executable, str(ROOT / "tools/prepare-vad-runtime.py"), "--platform", "macos"], check=True)
    runtime = ROOT / "output/vad-runtime/sherpa-onnx-1.12.20-macos"
    header = next(runtime.rglob("c-api.h"))
    library = next(runtime.rglob("libsherpa-onnx-c-api.dylib"))
    output = ROOT / "output/vad-tests"
    output.mkdir(parents=True, exist_ok=True)
    fixture = output / "synthetic-speech.aiff"
    subprocess.run(["say", "-o", str(fixture), "This is a synthetic classroom test. We explain the important concepts and then discuss the assignment. Please check the recording and the final sentence."], check=True)
    executable = output / "vad-tests"
    subprocess.run(["swiftc", "-D", "CLASSROOM_SHERPA", "-import-objc-header", str(header),
                    str(ROOT / "ios/ClassroomApp/SileroVoiceDetector.swift"), str(ROOT / "ios/ClassroomApp/ClassroomSliceBuffer.swift"),
                    str(ROOT / "ios/ClassroomApp/Models.swift"), str(ROOT / "ios/ClassroomApp/PCMUtilities.swift"),
                    str(ROOT / "ios/ClassroomApp/OfflineAudioSegmenter.swift"),
                    str(ROOT / "ios/ClassroomApp/AudioCompressor.swift"),
                    str(ROOT / "tests/classroom_vad_tests.swift"),
                    "-L", str(library.parent), "-lsherpa-onnx-c-api", "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
                    "-o", str(executable)], check=True)
    env = os.environ.copy()
    env["DYLD_LIBRARY_PATH"] = str(library.parent)
    subprocess.run([str(executable), str(ROOT / "ios/ClassroomApp/VADAssets/silero_vad.int8.onnx"), str(fixture)], env=env, check=True)


if __name__ == "__main__":
    main()
