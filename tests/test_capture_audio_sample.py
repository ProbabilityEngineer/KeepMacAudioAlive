import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "capture", Path(__file__).resolve().parents[1] / "scripts/capture-audio-sample.py"
)
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class CaptureTests(unittest.TestCase):
    def test_pid_and_event_match(self):
        line = "date pid=123 session=abc STATE Started running=true generation=4"
        self.assertTrue(capture.is_started(line, 123))
        self.assertFalse(capture.is_started(line, 12))
        self.assertFalse(capture.is_started(line.replace("STATE", "UI applied"), 123))
        self.assertFalse(capture.is_started(line.replace("true", "false"), 123))

    def test_old_entries_partial_lines_and_rotation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lifecycle.log"
            path.write_text("old Started event\n")
            tail = capture.LogTail(path)
            self.assertEqual(tail.read(), [])
            with path.open("a") as output:
                output.write("new partial")
            self.assertEqual(tail.read(), [])
            with path.open("a") as output:
                output.write(" entry\n")
            self.assertEqual(tail.read(), ["new partial entry"])
            path.rename(path.with_suffix(".previous"))
            path.write_text("rotated entry\n")
            self.assertEqual(tail.read(), ["rotated entry"])

    def test_missing_file_then_created(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lifecycle.log"
            tail = capture.LogTail(path)
            self.assertEqual(tail.read(), [])
            path.write_text("first entry\n")
            self.assertEqual(tail.read(), ["first entry"])


if __name__ == "__main__":
    unittest.main()
