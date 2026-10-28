#!/usr/bin/env python3
"""Read-only capture: new callback-confirmed Started event + five seconds."""
import datetime
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


class LogTail:
    """Ignore existing entries; follow replacement/rotation and partial lines."""
    def __init__(self, path):
        self.path = path
        self.identity = None
        self.offset = 0
        self.pending = b""
        if path.exists():
            stat = path.stat()
            self.identity = (stat.st_dev, stat.st_ino)
            self.offset = stat.st_size

    def read(self):
        try:
            with self.path.open("rb") as stream:
                stat = os.fstat(stream.fileno())
                identity = (stat.st_dev, stat.st_ino)
                if identity != self.identity or stat.st_size < self.offset:
                    self.identity, self.offset, self.pending = identity, 0, b""
                stream.seek(self.offset)
                data = self.pending + stream.read()
                self.offset = stream.tell()
            *lines, self.pending = data.split(b"\n")
            return [line.decode("utf-8", errors="replace") for line in lines]
        except FileNotFoundError:
            return []


def is_started(line, pid):
    return re.search(
        rf"\bpid={pid} session=\S+ STATE Started running=true\b", line
    ) is not None


def main(pid):
    home = Path.home()
    roots = {
        "sandboxed": home / "Library/Containers/com.github.openmac.KeepAudioAlive/Data/Library/Logs/KeepMacAudioAlive",
        "unsandboxed": home / "Library/Logs/KeepMacAudioAlive",
    }
    tails = [LogTail(root / "lifecycle.log") for root in roots.values()]
    destination = home / "Downloads/KeepMacAudioAlive-diagnostics" / (
        datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}"
    )
    destination.mkdir(parents=True)
    deadline = time.monotonic() + 90
    stop_at = deadline
    recovered = False
    child = None
    sample_number = 0
    reason = "90-second limit reached"
    print(f"Capturing PID {pid}: {destination}", flush=True)
    print("Now reproduce recovery/press Start. Waiting for a NEW Started event, then five more seconds.", flush=True)
    try:
        with (destination / "capture.txt").open("w") as notes:
            while time.monotonic() < stop_at:
                for tail in tails:
                    for line in tail.read():
                        if not recovered and is_started(line, pid):
                            recovered = True
                            requested_end = time.monotonic() + 5
                            stop_at = min(deadline, requested_end)
                            reason = ("Captured through five seconds after callback confirmation"
                                      if requested_end <= deadline else
                                      "Recovery arrived near capture limit; post-recovery window truncated")
                            notes.write(f"Recovery event: {line}\n")
                            notes.flush()
                            print("Callbacks confirmed; capturing five more seconds…", flush=True)
                if child is None or child.poll() is not None:
                    if child is not None and child.returncode != 0:
                        reason = f"sample exited with status {child.returncode}"
                        break
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        reason = "Target process exited"
                        break
                    sample_number += 1
                    duration = max(1, min(5, math.ceil(stop_at - time.monotonic())))
                    child = subprocess.Popen([
                        "/usr/bin/sample", str(pid), str(duration),
                        "-file", str(destination / f"process-sample-{sample_number:03d}.txt"),
                    ], stdout=subprocess.DEVNULL, stderr=notes)
                time.sleep(0.1)
            # sample normally finishes within the current five-second chunk.
            # Interrupt at the overall deadline rather than running unbounded.
            if child is not None and child.poll() is None:
                remaining = max(0.1, deadline - time.monotonic())
                try:
                    child.wait(timeout=min(6, remaining))
                except subprocess.TimeoutExpired:
                    child.terminate()
                    reason += "; final sample interrupted at capture limit"
            notes.write(f"Result: {reason}\n")
    except KeyboardInterrupt:
        reason = "Cancelled by user"
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for label, root in roots.items():
            for path in root.glob("lifecycle*.log"):
                target = destination / label
                target.mkdir(exist_ok=True)
                try:
                    shutil.copy2(path, target / path.name)
                except OSError as error:
                    print(f"Could not copy {path}: {error}", file=sys.stderr)
        print(f"{reason}. Saved samples and final logs: {destination}")


if __name__ == "__main__":
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        sys.exit("Usage: capture-audio-sample.py PID")
    main(int(sys.argv[1]))
