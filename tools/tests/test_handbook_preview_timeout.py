"""Synthetic regression tests for a receipt written during timeout diagnostics."""
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from capture_handbook_card_previews import read_after_timeout_diagnostic, read_receipt


class TimeoutReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="handbook-timeout-synthetic-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "tmp").mkdir()
        self.capture = str(uuid.uuid4())
        self.path = self.root / "tmp" / f"handbook-card-preview-ready-{self.capture}.json"
        self.launched = time.time() - 1
        fixture = Path(__file__).parent / "fixtures" / "handbook-normal-front-synthetic.json"
        self.payload = json.loads(fixture.read_text(encoding="utf-8"))
        self.payload["captureID"] = self.capture

    def read(self):
        return read_receipt(self.root, self.path, self.capture, "power", "normal-front", self.launched)

    def write_atomically(self, payload):
        pending = self.path.with_suffix(".pending")
        pending.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        os.replace(pending, self.path)

    def late_during_diagnostic(self, payload):
        release = threading.Event()
        finished = threading.Event()
        errors = []

        def writer():
            try:
                if not release.wait(3):
                    raise RuntimeError("diagnostic did not release the writer")
                self.write_atomically(payload)
            except Exception as error:
                errors.append(error)
            finally:
                finished.set()

        worker = threading.Thread(target=writer)
        worker.start()
        self.assertIsNone(self.read(), "The ordinary poll must happen before the late write")

        def diagnostic():
            release.set()
            if not finished.wait(3):
                raise RuntimeError("synthetic receipt was not written during diagnostics")
            if errors:
                raise errors[0]

        try:
            return read_after_timeout_diagnostic(self.root, self.path, self.capture,
                                                 "power", "normal-front", self.launched, diagnostic)
        finally:
            release.set()
            worker.join(timeout=3)

    def test_valid_receipt_written_during_diagnostic_is_fully_validated(self):
        actual = self.late_during_diagnostic(self.payload)
        self.assertEqual(actual, self.payload)

    def test_invalid_late_receipt_is_rejected(self):
        invalid = dict(self.payload, selfRatings=1)
        with self.assertRaisesRegex(RuntimeError, "selfRatings"):
            self.late_during_diagnostic(invalid)

    def test_wrong_launch_identity_is_rejected(self):
        invalid = dict(self.payload, captureID=str(uuid.uuid4()))
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            self.late_during_diagnostic(invalid)

    def test_missing_receipt_still_returns_none(self):
        calls = []
        actual = read_after_timeout_diagnostic(self.root, self.path, self.capture, "power", "normal-front",
                                               self.launched, lambda: calls.append("screenshot"))
        self.assertIsNone(actual)
        self.assertEqual(calls, ["screenshot"])

    def test_stale_receipt_is_rejected_even_after_diagnostic(self):
        self.write_atomically(self.payload)
        os.utime(self.path, (self.launched - 5, self.launched - 5))
        with self.assertRaisesRegex(RuntimeError, "stale"):
            read_after_timeout_diagnostic(self.root, self.path, self.capture, "power", "normal-front",
                                         self.launched, lambda: None)


if __name__ == "__main__":
    unittest.main()
