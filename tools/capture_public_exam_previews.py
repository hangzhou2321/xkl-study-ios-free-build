#!/usr/bin/env python3
"""Synthetic production ExamView render smoke; no taps or physical device."""
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import time
import uuid

from capture_professional_question_previews import run, sim, select_device, simulator_webkit_workaround

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/public-exam-previews"
BUNDLE = "local.xkl.study"
CASES = ("home", "question")


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Requires macOS/Xcode iOS Simulator; this is not a physical-device test")
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    name, runtime, kind, runtime_info = select_device()
    launch_environment, workaround = simulator_webkit_workaround(runtime_info)
    run("python3", "tools/generate_xcode_project.py", "--without-personal-resources")
    run("xcodebuild", "-project", "XKLStudy.xcodeproj", "-scheme", "XKLStudy",
        "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", "build/DerivedData", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
        "CODE_SIGN_IDENTITY=", "build")
    app = ROOT / "build/DerivedData/Build/Products/Debug-iphonesimulator/XKLStudy.app"
    if not app.is_dir():
        raise RuntimeError("Synthetic simulator build did not produce an app")
    device = sim("create", "PublicExamPreview-" + uuid.uuid4().hex[:12], kind, runtime).strip()
    manifest = {"status": "incomplete", "suite": "public-exam", "synthetic_only": True,
                "scope": "production ExamView rendering only; no taps and no physical device",
                "device": name, "device_type": kind, "runtime": runtime_info,
                "simulator_workaround": workaround, "fixtures": []}
    try:
        sim("boot", device)
        sim("bootstatus", device, "-b")
        sim("install", device, str(app))
        container = Path(sim("get_app_container", device, BUNDLE, "data").strip()).resolve()
        for case in CASES:
            capture_id = str(uuid.uuid4())
            receipt = container / "tmp" / f"public-exam-preview-ready-{capture_id}.json"
            if receipt.exists() or receipt.resolve().parent != (container / "tmp").resolve():
                raise RuntimeError("Invalid or preexisting synthetic receipt")
            started = time.time()
            log = OUT / f"{case}.log"
            with log.open("w", encoding="utf-8") as stream:
                process = subprocess.Popen(
                    ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", device, BUNDLE,
                     "--public-exam-preview", f"--case={case}", f"--capture-id={capture_id}"],
                    stdout=stream, stderr=subprocess.STDOUT,
                    env={**os.environ, "SIMCTL_CHILD_NSUnbufferedIO": "YES", **launch_environment})
                try:
                    deadline = time.monotonic() + 90
                    while not receipt.exists():
                        if process.poll() not in (None, 0) or time.monotonic() >= deadline:
                            raise RuntimeError(f"Synthetic {case} did not become ready; see {log}")
                        time.sleep(0.2)
                    if receipt.is_symlink() or not receipt.is_file() or receipt.stat().st_mtime < started or receipt.stat().st_size > 8192:
                        raise RuntimeError("Synthetic receipt is stale or invalid")
                    ready = json.loads(receipt.read_text(encoding="utf-8"))
                    if not (ready.get("suite") == "public-exam" and ready.get("case") == case and
                            ready.get("captureID") == capture_id and ready.get("ready") is True and
                            ready.get("isDualFSRS") is True and ready.get("presentationPreserved") is True):
                        raise RuntimeError("Synthetic receipt did not match the requested case")
                    time.sleep(1)
                    image = OUT / f"{case}.png"
                    sim("io", device, "screenshot", "--type=png", str(image))
                    header = image.read_bytes()[:24]
                    if header[:8] != b"\x89PNG\r\n\x1a\n":
                        raise RuntimeError("Simulator screenshot is not PNG")
                    width, height = struct.unpack(">II", header[16:24])
                    if width < 320 or not 1.5 <= height / width <= 2.5:
                        raise RuntimeError("Simulator screenshot is not a portrait phone")
                    manifest["fixtures"].append({"case": case, "file": image.name, "pixels": [width, height],
                        "sha256": hashlib.sha256(image.read_bytes()).hexdigest(), "receipt": ready})
                finally:
                    subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE], capture_output=True, text=True)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        process.wait(timeout=5)
        manifest["status"] = "complete"
    finally:
        (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, text=True)
        subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True, text=True)


if __name__ == "__main__":
    main()
