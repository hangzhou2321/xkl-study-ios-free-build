#!/usr/bin/env python3
"""Capture effective-time UI with synthetic data in a disposable iOS Simulator."""
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import time
import uuid

from capture_professional_question_previews import select_device, simulator_webkit_workaround

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/effective-time-previews"
BUNDLE = "local.xkl.study"
CASES = ("home", "records")
EXPECTED = {"vocabulary": 125, "publicQuestions": 67, "math": 300, "computer": 580,
            "power": 725, "circuit": 460, "mechanics": 180}


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def sim(*args):
    return run("xcrun", "simctl", *args, capture_output=True).stdout


def read_receipt(container, path, capture_id, case, launched_at):
    container, path = Path(container).resolve(), Path(path)
    temporary = container / "tmp"
    expected_path = temporary / f"effective-time-preview-ready-{capture_id}.json"
    if str(uuid.UUID(capture_id)) != capture_id or path != expected_path or case not in CASES:
        raise RuntimeError("Invalid synthetic receipt identity")
    if temporary.resolve().parent != container or path.resolve().parent != temporary.resolve():
        raise RuntimeError("Synthetic receipt escaped the app container")
    if not path.exists():
        return None
    stat = path.stat()
    if path.is_symlink() or not path.is_file() or stat.st_size > 8192 or stat.st_mtime < launched_at:
        raise RuntimeError("Stale or invalid synthetic receipt")
    value = json.loads(path.read_text(encoding="utf-8"))
    if (value.get("suite") != "effective-time" or value.get("case") != case
            or value.get("captureID") != capture_id or value.get("ready") is not True
            or value.get("syntheticOnly") is not True or value.get("areaCount") != 7
            or value.get("todaySeconds") != EXPECTED or value.get("todayTotalSeconds") != sum(EXPECTED.values())
            or value.get("idleLimitSeconds") != 60 or value.get("counting") is not False
            or value.get("layoutWidth", 0) <= 0 or value.get("layoutHeight", 0) <= 0):
        raise RuntimeError("Synthetic receipt contents do not match the fixture")
    return value


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Native iOS Simulator capture requires macOS/Xcode")
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    name, runtime, kind, runtime_info = select_device()
    launch_environment, workaround = simulator_webkit_workaround(runtime_info)
    run("python3", "tools/generate_xcode_project.py", "--without-personal-resources")
    derived = "build/EffectiveTimePreviewDerivedData"
    run("xcodebuild", "-project", "XKLStudy.xcodeproj", "-scheme", "XKLStudy", "-configuration", "Debug",
        "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
        "CODE_SIGN_IDENTITY=", "ARCHS=" + platform.machine(), "ONLY_ACTIVE_ARCH=YES", "build")
    app = ROOT / derived / "Build/Products/Debug-iphonesimulator/XKLStudy.app"
    if not app.is_dir():
        raise RuntimeError("Synthetic simulator app was not built")
    device = sim("create", "EffectiveTimePreview-" + uuid.uuid4().hex[:12], kind, runtime).strip()
    manifest = {"capture_type": "native iOS Simulator (not physical hardware)", "suite": "effective-time",
                "synthetic_only": True, "device": name, "device_type": kind, "runtime": runtime_info,
                "simulator_workaround": workaround, "status": "incomplete", "fixtures": []}
    try:
        sim("boot", device)
        sim("bootstatus", device, "-b")
        sim("install", device, str(app))
        container = Path(sim("get_app_container", device, BUNDLE, "data").strip()).resolve()
        for case in CASES:
            capture_id = str(uuid.uuid4())
            receipt = container / "tmp" / f"effective-time-preview-ready-{capture_id}.json"
            if receipt.exists():
                raise RuntimeError("Fresh capture UUID already has a receipt")
            log = OUT / f"{case}-{capture_id}.log"
            launched_at = time.time()
            with log.open("w", encoding="utf-8") as stream:
                process = subprocess.Popen(
                    ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", device, BUNDLE,
                     "--effective-time-preview", f"--case={case}", f"--capture-id={capture_id}"],
                    stdout=stream, stderr=subprocess.STDOUT,
                    env={**os.environ, "SIMCTL_CHILD_NSUnbufferedIO": "YES", **launch_environment})
                try:
                    deadline = time.monotonic() + 90
                    while True:
                        ready = read_receipt(container, receipt, capture_id, case, launched_at)
                        if ready is not None:
                            break
                        if process.poll() not in (None, 0):
                            raise RuntimeError(f"Synthetic app exited before readiness: {case}, {process.poll()}")
                        if time.monotonic() > deadline:
                            raise RuntimeError(f"Synthetic effective-time preview timed out: {case}")
                        time.sleep(0.2)
                    time.sleep(0.8)
                    screenshot = OUT / f"{case}.png"
                    sim("io", device, "screenshot", "--type=png", str(screenshot))
                    data = screenshot.read_bytes()
                    if data[:8] != b"\x89PNG\r\n\x1a\n":
                        raise RuntimeError("Screenshot is not PNG")
                    width, height = struct.unpack(">II", data[16:24])
                    if width < 320 or not 1.5 <= height / width <= 2.5:
                        raise RuntimeError(f"Unexpected phone screenshot dimensions {width}x{height}")
                    manifest["fixtures"].append({"case": case, "file": screenshot.name,
                        "pixels": [width, height], "screenshot_sha256": hashlib.sha256(data).hexdigest(),
                        "capture_id": capture_id, "ready_receipt": ready})
                except Exception as error:
                    manifest["failure"] = {"case": case, "error": str(error), "capture_id": capture_id, "console": log.name}
                    print("Synthetic preview failure:", error, flush=True)
                    print("\n".join(log.read_text(encoding="utf-8", errors="replace").splitlines()[-60:]), flush=True)
                    raise
                finally:
                    subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE], capture_output=True, text=True)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.terminate(); process.wait(timeout=5)
        if {item["case"] for item in manifest["fixtures"]} != set(CASES):
            raise RuntimeError("Synthetic effective-time capture set is incomplete")
        manifest["status"] = "complete"
    finally:
        (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, text=True)
        subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True, text=True)


if __name__ == "__main__":
    main()
