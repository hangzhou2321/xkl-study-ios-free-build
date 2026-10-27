#!/usr/bin/env python3
"""Capture production flashcard layout with only synthetic native fixtures."""
import hashlib
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
SUBJECTS = ("computer", "power")
CASES = ("front", "back", "table", "table-front", "long", "resume", "postponed", "completed", "missing-source", "normal-front", "normal-back", "focus-toggle",
         "multi-source", "lecture-only", "multi-source-pages", "lecture-only-pages", "diagram-branch", "diagram-flow", "diagram-switch")
CAPTURES = tuple((subject, case) for subject in SUBJECTS for case in CASES)


def selected_cases(raw):
    if not raw.strip():
        return CASES
    cases = tuple(x.strip() for x in raw.split(","))
    if len(cases) > len(CASES) or len(cases) != len(set(cases)) or any(x not in CASES for x in cases):
        raise ValueError("HANDBOOK_CARD_PREVIEW_CASES must contain distinct allowed cases")
    return cases


def read_receipt(container, receipt, capture_id, subject, case, launched_at):
    container, receipt = Path(container).resolve(), Path(receipt)
    expected = container / "tmp" / f"handbook-card-preview-ready-{capture_id}.json"
    if (str(uuid.UUID(capture_id)) != capture_id or receipt != expected
            or subject not in SUBJECTS or case not in CASES):
        raise RuntimeError("Invalid readiness receipt identity")
    temporary = container / "tmp"
    if temporary.resolve().parent != container or receipt.resolve().parent != temporary.resolve():
        raise RuntimeError("Readiness receipt escaped synthetic app container")
    if not receipt.exists():
        return None
    stat = receipt.stat()
    if receipt.is_symlink() or not receipt.is_file() or stat.st_size > 8192 or stat.st_mtime < launched_at:
        raise RuntimeError("Invalid or stale native readiness receipt")
    value = json.loads(receipt.read_text(encoding="utf8"))
    if (not isinstance(value, dict) or value.get("suite") != "handbook-cards" or value.get("captureID") != capture_id
            or value.get("subject") != subject or value.get("case") != case
            or value.get("ready") is not True or value.get("syntheticOnly") is not True):
        raise RuntimeError("Native receipt does not match this fixture launch")
    mode = "completed" if case == "completed" else ("front" if case in ("front", "table-front", "postponed", "normal-front") else "back")
    page, archive = (102, 117) if subject == "power" else (2, 3)
    supplemented = case.startswith(("multi-source", "lecture-only"))
    lecture_only = case.startswith("lecture-only")
    source_sheet = case.endswith("-pages")
    expected_state = {
        "route": "ProfessionalCoursesView", "selectedSubject": subject,
        "recallCueMode": subject == "power" and mode == "front",
        "fullScreen": case not in ("normal-front", "normal-back"), "rootTabShellFixture": True,
        "topicFrequencyLabel": ("宝典考点频率 ★★★★☆" if case in ("front", "back") else
                                ("宝典未单独标注" if case == "normal-front" else None)),
        "focusTogglePreservedRecord": case == "focus-toggle", "semicolonFormatting": True,
        "diagramExpanded": case in ("diagram-branch", "diagram-flow"),
        "diagramTogglePreservedRecord": case in ("diagram-branch", "diagram-flow", "diagram-switch"),
        "diagramSwitchStartedCollapsed": case == "diagram-switch",
        "diagramMode": "branch" if case == "diagram-switch" else (case.removeprefix("diagram-") if case.startswith("diagram-") else None),
        "mode": mode, "revealed": mode == "back", "ratingEnabled": mode == "back",
        "selfRatings": 2 if case == "completed" else 0,
        "cardID": None if case == "completed" else ("synthetic-handbook-second" if case in ("postponed", "diagram-switch") else "synthetic-handbook-first"),
        "sourceFilesPresent": False, "sourcePageNumbering": "physical-pdf", "textRenderingMode": "verbatim",
        "sourceSheetPresented": source_sheet, "sourceNavigationPreservedRecord": source_sheet,
        "selectedSourceID": "additional:synthetic-lecture" if source_sheet else None,
        "selectedSourceTitle": "纯合成讲义甲" if source_sheet else None,
        "selectedSourcePageNumbers": [7, 9] if source_sheet else [],
        "selectedSourceMissingPageNumbers": [7, 9] if source_sheet else [],
        "literalSymbolsFixture": subject == "power" and not supplemented,
        "cardSourcePageNumbers": [] if case == "completed" or lecture_only else [page],
        "cardAdditionalSourceReferences": [{"sourceID": "synthetic-lecture", "page": 7}] if supplemented else [],
        "cardSourceTitles": ([] if case == "completed" else
                             (["纯合成讲义甲"] if lecture_only else
                              (["纯合成来源", "纯合成讲义甲"] if supplemented else ["纯合成来源"]))),
        "allSourceTitles": ["纯合成来源", "纯合成讲义甲"] if supplemented else ["纯合成来源"],
        "supplementalExampleUsesOrdinaryBlock": supplemented,
        "sourceBlankCellsPreserved": subject == "power" and case in ("table", "table-front"),
        "allSourcePageNumbers": [page, archive] if case == "missing-source" else [archive],
        "archivalSourcePageNumbers": [archive],
    }
    for key, expected_value in expected_state.items():
        actual = value.get(key)
        if key not in value or type(actual) is not type(expected_value) or actual != expected_value:
            raise RuntimeError(f"Native receipt state mismatch: {subject}/{case} {key}")
    token = value.get("presentationID")
    if "presentationID" not in value:
        raise RuntimeError("Fixture omitted its presentation token state")
    if case == "completed":
        if token is not None:
            raise RuntimeError("Completed fixture retained a presentation token")
    elif not isinstance(token, str) or str(uuid.UUID(token)) != token:
        raise RuntimeError("Fixture presentation token is not a canonical UUID")
    return value


def validate_completed_captures(fixtures, captures):
    actual = [(item["subject"], item["case"]) for item in fixtures]
    if len(actual) != len(captures) or set(actual) != set(captures):
        raise RuntimeError("Native capture set is incomplete, duplicated or unexpected")
    ids = [item["capture_id"] for item in fixtures]
    if len(ids) != len(set(ids)):
        raise RuntimeError("Native captures reused a launch UUID")


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Real native iOS Simulator capture requires macOS/Xcode")
    cases = selected_cases(os.environ.get("HANDBOOK_CARD_PREVIEW_CASES", ""))
    captures = tuple((subject, case) for subject in SUBJECTS for case in cases)
    timeout = selected_timeout(os.environ.get("HANDBOOK_CARD_PREVIEW_TIMEOUT", "90"))
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    run_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:12]
    name, runtime, kind, runtime_info = select_device()
    launch_environment, workaround = simulator_webkit_workaround(runtime_info)
    run("python3", "tools/generate_xcode_project.py", "--without-personal-resources")
    run("xcodebuild", "-project", "XKLStudy.xcodeproj", "-scheme", "XKLStudy", "-configuration", "Debug",
        "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", "build/DerivedData", "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "ARCHS=" + platform.machine(),
        "ONLY_ACTIVE_ARCH=YES", "build")
    app = ROOT / "build/DerivedData/Build/Products/Debug-iphonesimulator/XKLStudy.app"
    if not app.is_dir():
        raise RuntimeError("Synthetic simulator app did not build")
    device = sim("create", "HandbookCardPreview-" + uuid.uuid4().hex[:12], kind, runtime).strip()
    manifest = {"capture_type": "native iOS Simulator (not physical hardware)",
                "suite": "handbook-cards", "synthetic_only": True, "device": name,
                "device_type": kind, "runtime": runtime_info, "simulator_workaround": workaround,
                "readiness": "Production ProfessionalCoursesView subject Picker and card layout with exact persisted self-rating state; other subject uses an isolated empty store; optional images never gate a text-card rating",
                "run_id": run_id, "requested_subjects": list(SUBJECTS),
                "requested_cases": list(cases), "requested_capture_count": len(captures),
                "status": "incomplete", "fixtures": []}
    try:
        sim("boot", device)
        sim("bootstatus", device, "-b")
        run("open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", device)
        sim("install", device, str(app))
        container = Path(sim("get_app_container", device, BUNDLE, "data").strip()).resolve()
        for subject, case in captures:
            started = time.monotonic()
            appearance = "dark" if case == "long" else "light"
            sim("ui", device, "appearance", appearance)
            capture_id = str(uuid.uuid4())
            receipt = container / "tmp" / f"handbook-card-preview-ready-{capture_id}.json"
            if receipt.exists():
                raise RuntimeError("Fresh capture UUID already has a readiness receipt")
            log = OUT / f"{subject}-{case}-{capture_id}.log"
            launched_at = time.time()
            with log.open("w", encoding="utf8") as stream:
                process = subprocess.Popen(
                    ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", device, BUNDLE,
                     "--handbook-card-preview", f"--subject={subject}", f"--case={case}", f"--capture-id={capture_id}"],
                    stdout=stream, stderr=subprocess.STDOUT,
                    env={**os.environ, "SIMCTL_CHILD_NSUnbufferedIO": "YES", **launch_environment})
                try:
                    retries = 0
                    deadline = time.monotonic() + timeout
                    while True:
                        ready = read_receipt(container, receipt, capture_id, subject, case, launched_at)
                        if ready is not None:
                            break
                        if process.poll() not in (None, 0):
                            raise RuntimeError(f"Native launch exited before readiness, code={process.poll()}")
                        if time.monotonic() > deadline:
                            debug = container / "tmp" / f"handbook-card-preview-debug-{capture_id}.json"
                            if debug.exists() and debug.stat().st_size < 65536:
                                trace = debug.read_text(encoding="utf8")
                                (OUT / f"failure-{subject}-{case}-{retries}.json").write_text(trace, encoding="utf8")
                                print("Native diagnostic:", trace, flush=True)
                            try:
                                sim("io", device, "screenshot", "--type=png", str(OUT / f"failure-{subject}-{case}-{retries}.png"))
                            except Exception as error:
                                print("Failure screenshot unavailable:", type(error).__name__, flush=True)
                            if retries == 0:
                                retries += 1
                                try:
                                    sim("terminate", device, BUNDLE)
                                except Exception:
                                    pass
                                if process.poll() is None:
                                    process.terminate()
                                    process.wait(timeout=10)
                                capture_id = str(uuid.uuid4())
                                receipt = container / "tmp" / f"handbook-card-preview-ready-{capture_id}.json"
                                assert not receipt.exists()
                                launched_at = time.time()
                                process = subprocess.Popen(
                                    ["xcrun", "simctl", "launch", "--console", "--terminate-running-process", device, BUNDLE,
                                     "--handbook-card-preview", f"--subject={subject}", f"--case={case}", f"--capture-id={capture_id}"],
                                    stdout=stream, stderr=subprocess.STDOUT,
                                    env={**os.environ, "SIMCTL_CHILD_NSUnbufferedIO": "YES", **launch_environment})
                                deadline = time.monotonic() + timeout
                                continue
                            raise RuntimeError(f"Native fixture readiness timed out: {subject}/{case}; app state unknown")
                        time.sleep(0.2)
                    ready_elapsed = time.monotonic() - started
                    time.sleep(0.8)
                    saved_receipt = OUT / f"ready-{subject}-{case}-{capture_id}.json"
                    saved_receipt.write_bytes(receipt.read_bytes())
                    screenshot = OUT / f"{subject}-{case}.png"
                    sim("io", device, "screenshot", "--type=png", str(screenshot))
                    with screenshot.open("rb") as f:
                        header = f.read(24)
                    if header[:8] != b"\x89PNG\r\n\x1a\n":
                        raise RuntimeError("Native capture is not a PNG")
                    width, height = struct.unpack(">II", header[16:24])
                    if width < 320 or not 1.5 <= height / width <= 2.5:
                        raise RuntimeError(f"Unexpected phone capture size {width}x{height}")
                    manifest["fixtures"].append({"subject": subject, "case": case,
                        "file": screenshot.name, "appearance": appearance, "pixels": [width, height],
                        "screenshot_sha256": hashlib.sha256(screenshot.read_bytes()).hexdigest(),
                        "capture_id": capture_id, "ready_receipt": ready,
                        "ready_receipt_file": saved_receipt.name, "console": log.name,
                        "receipt_relative_to_app_data": str(receipt.relative_to(container)),
                        "capture_elapsed_seconds": round(time.monotonic() - started, 3),
                        "readiness_elapsed_seconds": round(ready_elapsed, 3),
                        "readiness_timeout_seconds": timeout,
                        "simctl_console_exit_code_at_ready": process.poll(),
                        "timing_scope": "diagnostic only, not a product performance acceptance threshold"})
                except Exception as error:
                    failure = {"subject": subject, "case": case, "error": str(error), "capture_id": capture_id,
                               "console": log.name, "simctl_exit_code": process.poll(),
                               "receipt_exists_at_failure": receipt.exists(),
                               "elapsed_seconds": round(time.monotonic() - started, 3)}
                    try:
                        failure_image = OUT / f"failure-{subject}-{case}-{capture_id}.png"
                        sim("io", device, "screenshot", "--type=png", str(failure_image))
                        failure["diagnostic_screenshot"] = failure_image.name
                    except Exception as screenshot_error:
                        failure["diagnostic_error"] = str(screenshot_error)
                    manifest["failure"] = failure
                    try:
                        if receipt.is_file() and not receipt.is_symlink() and receipt.stat().st_size <= 8192:
                            failure_receipt = OUT / f"failure-receipt-{subject}-{case}-{capture_id}.json"
                            failure_receipt.write_bytes(receipt.read_bytes())
                            failure["raw_receipt_file"] = failure_receipt.name
                    except OSError as receipt_error:
                        failure["receipt_copy_error"] = str(receipt_error)
                    failure_record = OUT / f"failure-{subject}-{case}-{capture_id}.json"
                    failure_record.write_text(json.dumps(failure, ensure_ascii=False, indent=2) + "\n", encoding="utf8")
                    print("\n".join(log.read_text(encoding="utf8", errors="replace").splitlines()[-60:]), flush=True)
                    raise
                finally:
                    subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE], capture_output=True, text=True)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.terminate(); process.wait(timeout=5)
        validate_completed_captures(manifest["fixtures"], captures)
        manifest["status"] = "complete"
    finally:
        serialized = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
        (OUT / f"manifest-{run_id}.json").write_text(serialized, encoding="utf8")
        (OUT / "manifest.json").write_text(serialized, encoding="utf8")
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, text=True)
        subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True, text=True)


if __name__ == "__main__":
    main()
