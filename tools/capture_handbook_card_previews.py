#!/usr/bin/env python3
"""Capture production flashcard layout with only synthetic native fixtures."""
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import time
import uuid

from capture_professional_question_previews import (
    run, sim, select_device, selected_timeout, simulator_webkit_workaround,
)

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/handbook-card-previews"
BUNDLE = "local.xkl.study"
CASES = ("front", "back", "table", "long", "resume", "postponed", "completed", "missing-source")


def selected_cases(raw):
    if not raw.strip():
        return CASES
    cases = tuple(x.strip() for x in raw.split(","))
    if len(cases) > len(CASES) or len(cases) != len(set(cases)) or any(x not in CASES for x in cases):
        raise ValueError("HANDBOOK_CARD_PREVIEW_CASES must contain distinct allowed cases")
    return cases


def read_receipt(container, receipt, capture_id, case, launched_at):
    expected = container / "tmp" / f"handbook-card-preview-ready-{capture_id}.json"
    if str(uuid.UUID(capture_id)) != capture_id or receipt != expected:
        raise RuntimeError("Invalid readiness receipt identity")
    if receipt.resolve().parent != (container / "tmp").resolve():
        raise RuntimeError("Readiness receipt escaped synthetic app container")
    if not receipt.exists():
        return None
    stat = receipt.stat()
    if receipt.is_symlink() or not receipt.is_file() or stat.st_size > 8192 or stat.st_mtime < launched_at:
        raise RuntimeError("Invalid or stale native readiness receipt")
    value = json.loads(receipt.read_text(encoding="utf8"))
    if (value.get("suite") != "handbook-cards" or value.get("captureID") != capture_id
            or value.get("subject") != "computer" or value.get("case") != case
            or value.get("ready") is not True or value.get("syntheticOnly") is not True):
        raise RuntimeError("Native receipt does not match this fixture launch")
    return value


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Real native iOS Simulator capture requires macOS/Xcode")
    cases = selected_cases(os.environ.get("HANDBOOK_CARD_PREVIEW_CASES", ""))
    timeout = selected_timeout(os.environ.get("HANDBOOK_CARD_PREVIEW_TIMEOUT", "90"))
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    name, runtime, kind, runtime_info = select_device()
    launch_environment, workaround = simulator_webkit_workaround(runtime_info)
    run("python3", "tools/generate_xcode_project.py", "--without-personal-resources")
    run("xcodebuild", "-project", "XKLStudy.xcodeproj", "-scheme", "XKLStudy", "-configuration", "Debug",
        "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", "build/DerivedData", "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "build")
    app = ROOT / "build/DerivedData/Build/Products/Debug-iphonesimulator/XKLStudy.app"
    if not app.is_dir():
        raise RuntimeError("Synthetic simulator app did not build")
    device = sim("create", "HandbookCardPreview-" + uuid.uuid4().hex[:12], kind, runtime).strip()
    manifest = {"capture_type": "native iOS Simulator (not physical hardware)",
                "suite": "handbook-cards", "synthetic_only": True, "device": name,
                "device_type": kind, "runtime": runtime_info, "simulator_workaround": workaround,
                "readiness": "Production View positive layout and exact persisted self-rating state; optional images never gate a text-card rating",
                "requested_cases": list(cases), "requested_capture_count": len(cases),
                "status": "incomplete", "fixtures": []}
    try:
        sim("boot", device)
        sim("bootstatus", device, "-b")
        sim("install", device, str(app))
        container = Path(sim("get_app_container", device, BUNDLE, "data").strip()).resolve()
        for case in cases:
            started = time.monotonic()
            appearance = "dark" if case == "long" else "light"
            sim("ui", device, "appearance", appearance)
            capture_id = str(uuid.uuid4())
            receipt = container / "tmp" / f"handbook-card-preview-ready-{capture_id}.json"
            if receipt.exists():
                raise RuntimeError("Fresh capture UUID already has a readiness receipt")
            log = OUT / f"computer-{case}.log"
            launched_at = time.time()
            with log.open("w", encoding="utf8") as stream:
                process = subprocess.Popen(
                    ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", device, BUNDLE,
                     "--handbook-card-preview", f"--case={case}", f"--capture-id={capture_id}"],
                    stdout=stream, stderr=subprocess.STDOUT,
                    env={**os.environ, "SIMCTL_CHILD_NSUnbufferedIO": "YES", **launch_environment})
                try:
                    deadline = time.monotonic() + timeout
                    while True:
                        ready = read_receipt(container, receipt, capture_id, case, launched_at)
                        if ready is not None:
                            break
                        if process.poll() not in (None, 0):
                            raise RuntimeError(f"Native launch exited before readiness, code={process.poll()}")
                        if time.monotonic() > deadline:
                            raise RuntimeError(f"Native fixture readiness timed out: {case}; app state unknown")
                        time.sleep(0.2)
                    ready_elapsed = time.monotonic() - started
                    time.sleep(0.8)
                    screenshot = OUT / f"computer-{case}.png"
                    sim("io", device, "screenshot", "--type=png", str(screenshot))
                    with screenshot.open("rb") as f:
                        header = f.read(24)
                    if header[:8] != b"\x89PNG\r\n\x1a\n":
                        raise RuntimeError("Native capture is not a PNG")
                    width, height = struct.unpack(">II", header[16:24])
                    if width < 320 or not 1.5 <= height / width <= 2.5:
                        raise RuntimeError(f"Unexpected phone capture size {width}x{height}")
                    manifest["fixtures"].append({"subject": "computer", "case": case,
                        "file": screenshot.name, "appearance": appearance, "pixels": [width, height],
                        "capture_id": capture_id, "ready_receipt": ready,
                        "receipt_relative_to_app_data": str(receipt.relative_to(container)),
                        "capture_elapsed_seconds": round(time.monotonic() - started, 3),
                        "readiness_elapsed_seconds": round(ready_elapsed, 3),
                        "readiness_timeout_seconds": timeout,
                        "simctl_console_exit_code_at_ready": process.poll(),
                        "timing_scope": "diagnostic only, not a product performance acceptance threshold"})
                except Exception as error:
                    failure = {"case": case, "error": str(error), "capture_id": capture_id,
                               "console": log.name, "simctl_exit_code": process.poll(),
                               "receipt_exists_at_failure": receipt.exists(),
                               "elapsed_seconds": round(time.monotonic() - started, 3)}
                    try:
                        failure_image = OUT / f"failure-computer-{case}.png"
                        sim("io", device, "screenshot", "--type=png", str(failure_image))
                        failure["diagnostic_screenshot"] = failure_image.name
                    except Exception as screenshot_error:
                        failure["diagnostic_error"] = str(screenshot_error)
                    manifest["failure"] = failure
                    print("\n".join(log.read_text(encoding="utf8", errors="replace").splitlines()[-60:]), flush=True)
                    raise
                finally:
                    subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE], capture_output=True, text=True)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.terminate(); process.wait(timeout=5)
        manifest["status"] = "complete"
    finally:
        (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf8")
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, text=True)
        subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True, text=True)


if __name__ == "__main__":
    main()
