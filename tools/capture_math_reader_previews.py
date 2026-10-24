#!/usr/bin/env python3
"""Capture synthetic DEBUG fixtures using native iOS Simulator, never local banks."""
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/math-experience-previews"
BUNDLE = "local.xkl.study"
CASES = [(case, 26) for case in (
    "familiar", "question", "hint", "answer", "details", "card", "undo", "resume",
    "diagram", "matrix", "piecewise")] + [("question", 34), ("details", 34)]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def sim(*args):
    return run("xcrun", "simctl", *args, capture_output=True).stdout


def select_device():
    data = json.loads(sim("list", "--json"))
    types = {d["identifier"]: d for d in data["devicetypes"]}
    runtimes = {r["identifier"]: r for r in data["runtimes"]
                if r.get("isAvailable")
                and ".iOS-" in r["identifier"]}
    candidates = []
    # Prefer compact screens; derive identifiers exclusively from installed inventory.
    preferred = ["iPhone SE (3rd generation)", "iPhone SE (2nd generation)",
                 "iPhone 16", "iPhone 15", "iPhone 14", "iPhone 13 mini", "iPhone 12 mini"]
    for runtime, devices in data["devices"].items():
        if runtime not in runtimes:
            continue
        for device in devices:
            kind = device.get("deviceTypeIdentifier")
            if not device.get("isAvailable") or kind not in types:
                continue
            name = types[kind]["name"]
            if not name.startswith("iPhone"):
                continue
            rank = preferred.index(name) if name in preferred else len(preferred)
            candidates.append((rank, name, runtime, kind))
    if not candidates:
        raise RuntimeError("No available installed iPhone Simulator device/runtime; cannot capture previews")
    _, name, runtime, kind = sorted(candidates)[0]
    return name, runtime, kind, runtimes[runtime]


def simulator_webkit_workaround(runtime_info):
    """Official iOS 18.5 Simulator-only workaround; never alter the app bundle."""
    evidence = {"official_url": "https://bugs.webkit.org/show_bug.cgi?id=293831#c2",
                "scope": "Simulator launch child process only", "applied": False}
    if runtime_info.get("version") != "18.5":
        return {}, evidence
    bundle = runtime_info.get("bundlePath")
    if not bundle:
        raise RuntimeError("iOS 18.5 runtime bundlePath missing; cannot verify official WebKit workaround")
    directory = Path(bundle) / "Contents/Resources/RuntimeRoot/System/Cryptexes/OS/usr/lib/swift"
    library = directory / "libswiftWebKit.dylib"
    if not library.is_file():
        raise RuntimeError(f"Official runtime WebKit library missing: {library}")
    evidence.update({"applied": True, "library": str(library),
                     "library_sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
                     "fallback_library_path": str(directory)})
    return {"SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH": str(directory)}, evidence


def read_ready_receipt(container, receipt, capture_id, case, font, launched_at):
    """Accept only a fresh atomic receipt from this app container and launch UUID."""
    container, receipt = Path(container).resolve(), Path(receipt)
    temporary = container / "tmp"
    expected = temporary / f"math-preview-ready-{capture_id}.json"
    if str(uuid.UUID(capture_id)) != capture_id or receipt != expected:
        raise RuntimeError("Invalid capture UUID or readiness receipt filename")
    if temporary.resolve().parent != container or receipt.resolve().parent != temporary.resolve():
        raise RuntimeError("Readiness receipt escaped the app data container tmp directory")
    if not receipt.exists():
        return None
    info = receipt.stat()
    if receipt.is_symlink() or not receipt.is_file() or info.st_size > 8192 or info.st_mtime < launched_at:
        raise RuntimeError("Stale or invalid readiness receipt")
    payload = json.loads(receipt.read_text(encoding="utf-8"))
    if (not isinstance(payload, dict) or payload.get("captureID") != capture_id
            or payload.get("suite") != "math" or payload.get("case") != case
            or type(payload.get("font")) is not int or payload.get("font") != font
            or payload.get("ready") is not True):
        raise RuntimeError("Readiness receipt does not match this synthetic capture")
    return payload


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Native iOS Simulator capture requires macOS/Xcode; not verified on Windows")
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    name, runtime, kind, runtime_info = select_device()
    launch_environment, workaround = simulator_webkit_workaround(runtime_info)
    run("python3", "tools/generate_xcode_project.py", "--without-personal-resources")
    run("xcodebuild", "-project", "XKLStudy.xcodeproj", "-scheme", "XKLStudy",
        "-configuration", "Debug", "-sdk", "iphonesimulator",
        "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", "build/DerivedData",
        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "build")
    app = ROOT / "build/DerivedData/Build/Products/Debug-iphonesimulator/XKLStudy.app"
    if not app.is_dir():
        raise RuntimeError("Simulator Debug app missing")
    device = sim("create", "MathExperiencePreview-" + uuid.uuid4().hex[:12], kind, runtime).strip()
    manifest = {"capture_type": "native iOS Simulator (not physical hardware)",
                "experience_format": "xkl-math-experience-v2", "synthetic_only": True, "readiness": "Per-launch atomic app tmp receipt after true WK/font readiness and layout; console is diagnostic only",
                "device": name, "device_type": kind,
                "runtime": runtime_info, "simulator_workaround": workaround,
                "status": "incomplete", "fixtures": []}
    try:
        sim("boot", device)
        sim("bootstatus", device, "-b")
        sim("install", device, str(app))
        container = Path(sim("get_app_container", device, BUNDLE, "data").strip()).resolve()
        for case, font in CASES:
            started = time.monotonic()
            readiness_timeout = 90 if (case, font) == ("question", 26) else 45
            log = OUT / f"{case}-{font}.log"
            marker = f"MATH_EXPERIENCE_PREVIEW_RENDERED case={case} font={font}"
            capture_id = str(uuid.uuid4())
            receipt = container / "tmp" / f"math-preview-ready-{capture_id}.json"
            if receipt.exists():
                raise RuntimeError("Unexpected preexisting readiness receipt for fresh UUID")
            launched_at = time.time()
            with log.open("w", encoding="utf-8") as stream:
                process = subprocess.Popen(
                    ["xcrun", "simctl", "launch", "--console", "--terminate-running-process",
                     device, BUNDLE, "--math-experience-preview", "--math-experience-case", case,
                     "--math-experience-font", str(font), "--preview-capture-id", capture_id], stdout=stream, stderr=subprocess.STDOUT,
                    env={**os.environ, "SIMCTL_CHILD_NSUnbufferedIO": "YES", **launch_environment})
                try:
                    deadline = time.monotonic() + readiness_timeout
                    while True:
                        ready_receipt = read_ready_receipt(container, receipt, capture_id, case, font, launched_at)
                        if ready_receipt is not None:
                            break
                        console_code = process.poll()
                        if console_code not in (None, 0):
                            raise RuntimeError(f"simctl console command failed before receipt: {case}; exit code={console_code}; app state unknown; see {log}")
                        if time.monotonic() > deadline:
                            raise RuntimeError(f"Fixture readiness receipt timed out: {case}; simctl console code={console_code}; app state unknown; see {log}")
                        time.sleep(0.2)
                    ready_elapsed = time.monotonic() - started
                    # Renderer/font readiness marker precedes native compositing settling.
                    time.sleep(1.0)
                    screenshot = OUT / f"{case}-{font}.png"
                    sim("io", device, "screenshot", "--type=png", str(screenshot))
                    with screenshot.open("rb") as image:
                        header = image.read(24)
                    if header[:8] != b"\x89PNG\r\n\x1a\n":
                        raise RuntimeError("Simulator screenshot is not PNG")
                    width, height = struct.unpack(">II", header[16:24])
                    if width < 320 or not 1.5 <= height / width <= 2.5:
                        raise RuntimeError(f"Expected portrait phone screenshot, got {width}x{height}")
                    manifest["fixtures"].append({"case": case, "font_pt": font,
                        "file": screenshot.name, "pixels": [width, height], "ready_marker": marker,
                        "capture_id": capture_id, "ready_receipt": ready_receipt,
                        "receipt_relative_to_app_data": str(receipt.relative_to(container)),
                        "simctl_console_exit_code_at_ready": process.poll(),
                        "capture_elapsed_seconds": round(time.monotonic() - started, 3),
                        "readiness_elapsed_seconds": round(ready_elapsed, 3),
                        "readiness_timeout_seconds": readiness_timeout,
                        "timing_scope": "diagnostic only; does not establish acceptable product loading speed"})
                except Exception as error:
                    # Only this launch's synthetic fixture console, never host/user files.
                    print(f"Synthetic fixture failure: {error}", flush=True)
                    print("\n".join(log.read_text(encoding="utf-8", errors="replace").splitlines()[-80:]), flush=True)
                    failure = {"case": case, "font_pt": font, "error": str(error),
                               "capture_id": capture_id, "receipt_relative_to_app_data": str(receipt.relative_to(container)),
                               "simctl_exit_code": process.poll(), "console": log.name,
                               "elapsed_seconds": round(time.monotonic() - started, 3),
                               "readiness_timeout_seconds": readiness_timeout,
                               "phase_trace": [line for line in log.read_text(encoding="utf-8", errors="replace").splitlines()
                                               if "MATH_" in line][-80:]}
                    try:
                        failure_image = OUT / f"failure-{case}-{font}.png"
                        sim("io", device, "screenshot", "--type=png", str(failure_image))
                        failure["diagnostic_screenshot"] = failure_image.name
                    except Exception as screenshot_error:
                        failure["screenshot_error"] = str(screenshot_error)
                    manifest["failure"] = failure
                    raise
                finally:
                    subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE],
                                   capture_output=True, text=True)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        process.wait(timeout=5)
        manifest["status"] = "complete"
    finally:
        (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        # Only touch the ephemeral device created by this script, including on failure.
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, text=True)
        subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True, text=True)


if __name__ == "__main__":
    main()
