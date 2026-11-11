"""Launch the real native app on an isolated CI iPhone simulator and capture its home screen."""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*arguments, **options):
    try:
        return subprocess.run(arguments, text=True, check=True, **options)
    except subprocess.CalledProcessError as error:
        if error.stdout:
            print(error.stdout, flush=True)
        if error.stderr:
            print(error.stderr, file=sys.stderr, flush=True)
        raise


def main():
    output = ROOT / "output" / "simulator-smoke"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / "ClassroomSimulator.ipa"
    run(sys.executable, str(ROOT / "tools/package-ios-app.py"), str(archive), "--simulator")
    with zipfile.ZipFile(archive) as source:
        source.extractall(output)
    app = output / "Payload" / "ClassroomApp.app"
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j", capture_output=True, timeout=60).stdout)["devices"]
    candidates = [(runtime, device) for runtime, entries in devices.items()
                  if ".iOS-" in runtime for device in entries
                  if device.get("isAvailable") and device["name"].startswith("iPhone")]
    if not candidates:
        raise RuntimeError("No available iPhone simulator runtime on this runner")
    runtime, template = candidates[0]
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j", capture_output=True, timeout=60).stdout)["runtimes"]
    selected_runtime = next(item for item in runtimes if item["identifier"] == runtime)
    launch_environment = os.environ.copy()
    workaround = False
    # Apple-confirmed Xcode 16.4/iOS 18.5 simulator loader bug, not an app or device library change.
    # https://developer.apple.com/forums/thread/785964
    if selected_runtime.get("version") == "18.5":
        swift_libraries = Path(selected_runtime["bundlePath"]) / "Contents/Resources/RuntimeRoot/System/Cryptexes/OS/usr/lib/swift"
        if (swift_libraries / "libswiftWebKit.dylib").is_file():
            launch_environment["SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH"] = str(swift_libraries)
            workaround = True
            print("Applying Apple's iOS 18.5 simulator WebKit library search workaround", flush=True)
    device_type = template.get("deviceTypeIdentifier", "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro")
    device = run("xcrun", "simctl", "create", "Classroom native smoke", device_type, runtime, capture_output=True, timeout=60).stdout.strip()
    try:
        run("xcrun", "simctl", "boot", device, timeout=90)
        run("xcrun", "simctl", "bootstatus", device, "-b", timeout=240)
        run("xcrun", "simctl", "status_bar", device, "override", "--time", "09:41", "--batteryState", "charged", "--batteryLevel", "100", timeout=60)
        run("xcrun", "simctl", "install", device, str(app), timeout=90)
        launch = run("xcrun", "simctl", "launch", device, "top.lzso.classroom", capture_output=True, timeout=90, env=launch_environment)
        print(launch.stdout, flush=True)
        match = re.search(r"top\.lzso\.classroom:\s*(\d+)", launch.stdout)
        if not match:
            raise RuntimeError("Simulator did not report a running application PID")
        time.sleep(5)
        run("xcrun", "simctl", "spawn", device, "/bin/kill", "-0", match.group(1))
        run("xcrun", "simctl", "io", device, "screenshot", str(output / "native-home.png"), timeout=30)
        (output / "result.json").write_text(json.dumps({"bundle_id": "top.lzso.classroom", "runtime": runtime,
            "device": template["name"], "launched": True, "process_alive_after_5_seconds": True,
            "apple_ios_18_5_simulator_library_workaround": workaround}, indent=2), encoding="utf-8")
        print("Native iPhone simulator app launch and home screenshot passed")
    except Exception as error:
        details = [str(error), str(getattr(error, "stdout", "") or ""), str(getattr(error, "stderr", "") or "")]
        try:
            diagnostic = subprocess.run(["xcrun", "simctl", "spawn", device, "log", "show", "--last", "3m",
                "--style", "compact", "--predicate", 'eventMessage CONTAINS "top.lzso.classroom" OR process == "ClassroomApp"'],
                text=True, capture_output=True, timeout=45)
            details += [diagnostic.stdout, diagnostic.stderr]
        except subprocess.TimeoutExpired:
            details.append("Simulator diagnostic log service did not respond within 45 seconds")
        diagnostic_text = "\n".join(details)
        (output / "launch-diagnostics.txt").write_text(diagnostic_text, encoding="utf-8")
        for report in (Path.home() / "Library/Logs/DiagnosticReports").glob("ClassroomApp*.ips"):
            shutil.copy2(report, output / report.name)
        print(diagnostic_text[-16000:], flush=True)
        raise
    finally:
        for operation in ["shutdown", "delete"]:
            try:
                subprocess.run(["xcrun", "simctl", operation, device], check=False, timeout=30)
            except subprocess.TimeoutExpired:
                print(f"Cleanup of isolated simulator timed out: {operation}", flush=True)


if __name__ == "__main__":
    main()
