#!/usr/bin/env python3
"""Capture synthetic DEBUG fixtures using native iOS Simulator, never local banks."""
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/math-reader-previews"
BUNDLE = "local.xkl.study"
CASES = [("options", 26), ("expressions", 26), ("matrix", 26),
         ("piecewise", 26), ("answer", 26), ("options", 34),
         ("diagram", 26), ("fallback", 26)]


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


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Native iOS Simulator capture requires macOS/Xcode; not verified on Windows")
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    name, runtime, kind, runtime_info = select_device()
    run("python3", "tools/generate_xcode_project.py", "--without-personal-resources")
    run("xcodebuild", "-project", "XKLStudy.xcodeproj", "-scheme", "XKLStudy",
        "-configuration", "Debug", "-sdk", "iphonesimulator",
        "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", "build/DerivedData",
        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "build")
    app = ROOT / "build/DerivedData/Build/Products/Debug-iphonesimulator/XKLStudy.app"
    if not app.is_dir():
        raise RuntimeError("Simulator Debug app missing")
    device = sim("create", "MathReaderPreview-" + uuid.uuid4().hex[:12], kind, runtime).strip()
    manifest = {"capture_type": "native iOS Simulator (not physical hardware)",
                "synthetic_only": True, "readiness": "onAppear marker plus 1 second native draw settling",
                "device": name, "device_type": kind,
                "runtime": runtime_info, "fixtures": []}
    try:
        sim("boot", device)
        sim("bootstatus", device, "-b")
        sim("install", device, str(app))
        for case, font in CASES:
            log = OUT / f"{case}-{font}.log"
            marker = f"MATH_READER_PREVIEW_READY case={case} font={font}"
            with log.open("w", encoding="utf-8") as stream:
                process = subprocess.Popen(
                    ["xcrun", "simctl", "launch", "--console", "--terminate-running-process",
                     device, BUNDLE, "--math-reader-preview", "--math-reader-case", case,
                     "--math-reader-font", str(font)], stdout=stream, stderr=subprocess.STDOUT,
                    env={**os.environ, "SIMCTL_CHILD_NSUnbufferedIO": "YES"})
                try:
                    deadline = time.monotonic() + 45
                    while marker not in log.read_text(encoding="utf-8", errors="replace"):
                        if process.poll() is not None:
                            raise RuntimeError(f"Fixture exited before readiness: {case}; see {log}")
                        if time.monotonic() > deadline:
                            raise RuntimeError(f"Fixture readiness timed out: {marker}; see {log}")
                        time.sleep(0.2)
                    # onAppear marker precedes the next native layout/drawing pass.
                    time.sleep(1.0)
                    screenshot = OUT / f"{case}-{font}.png"
                    sim("io", device, "screenshot", "--type=png", str(screenshot))
                    with screenshot.open("rb") as image:
                        header = image.read(24)
                    if header[:8] != b"\x89PNG\r\n\x1a\n":
                        raise RuntimeError("Simulator screenshot is not PNG")
                    width, height = struct.unpack(">II", header[16:24])
                    manifest["fixtures"].append({"case": case, "font_pt": font,
                        "file": screenshot.name, "pixels": [width, height], "ready_marker": marker})
                finally:
                    subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE],
                                   capture_output=True, text=True)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        process.wait(timeout=5)
        (OUT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    finally:
        # Only touch the ephemeral device created by this script, including on failure.
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, text=True)
        subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True, text=True)


if __name__ == "__main__":
    main()
