#!/usr/bin/env python3
"""Run GUI checks in an isolated profile, with no model prompts."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
home = Path(tempfile.mkdtemp(prefix="emacs-pi-history-gui-"))
env = dict(os.environ, EMACS_TEST_HOME=str(home))
print(f"Test profile: {home}", flush=True)
try:
    result = subprocess.run(
        [os.environ.get("EMACS", "/Applications/MacPorts/Emacs.app/Contents/MacOS/Emacs"),
         "-Q", "-l", str(root / "tests/gui-pi-history-smoke.el")],
        env=env, capture_output=True, timeout=110,
    )
except subprocess.TimeoutExpired as error:
    print("GUI test timed out; test profile retained for diagnosis")
    raise SystemExit(1) from error
for name in ("failure", "passed"):
    path = home / name
    if path.exists():
        print(path.read_text())
if result.returncode:
    print(result.stderr.decode(errors="replace")[-2000:])
raise SystemExit(result.returncode)
