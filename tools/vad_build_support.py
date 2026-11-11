"""Locate the exact platform slices in the verified sherpa-onnx release."""
import plistlib
from pathlib import Path


def ios_runtime_arguments(root: Path, simulator=False, architecture="arm64"):
    libraries = []
    header = None
    for name in ["sherpa-onnx.xcframework", "onnxruntime.xcframework"]:
        frameworks = sorted({path.resolve() for path in root.rglob(name)})
        if len(frameworks) != 1:
            raise RuntimeError(f"Expected one {name}, found {len(frameworks)}")
        framework = frameworks[0]
        info = plistlib.loads((framework / "Info.plist").read_bytes())
        variants = [item for item in info["AvailableLibraries"]
                    if item["SupportedPlatform"] == "ios"
                    and (item.get("SupportedPlatformVariant") or None) == ("simulator" if simulator else None)
                    and architecture in item["SupportedArchitectures"]]
        if len(variants) != 1:
            raise RuntimeError(f"Cannot identify the iPhone arm64 slice of {name}")
        variant = variants[0]
        directory = framework / variant["LibraryIdentifier"]
        library = directory / variant["LibraryPath"]
        if library.is_dir():
            library = library / library.stem
        if not library.is_file():
            raise RuntimeError(f"Missing iOS static library {library.name}")
        libraries.append(str(library))
        if name.startswith("sherpa"):
            headers = list((framework / "Headers").rglob("c-api.h"))
            if not headers:
                headers = list(directory.rglob("c-api.h"))
            if len(headers) != 1:
                raise RuntimeError("Missing sherpa-onnx C API header")
            header = str(headers[0])
    return ["-D", "CLASSROOM_SHERPA", "-import-objc-header", header, *libraries,
            "-lc++", "-framework", "Accelerate", "-framework", "CoreML"]
