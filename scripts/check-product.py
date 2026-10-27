"""Portable baseline for contributors and CI; never builds or opens browser windows."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "dist/DevBar.app/Contents/MacOS/DevBar"
if not BINARY.is_file():
    raise SystemExit("Build once first: zsh scripts/build.sh")
(ROOT / "work").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="DevBar product checks ") as folder:
    env = dict(os.environ, DEVBAR_DATA_DIR=folder, DEVBAR_HEADLESS="1",
               DEVBAR_TEST_BINARY=str(BINARY))
    def run(arguments):
        print("Checking: " + " ".join(arguments), flush=True)
        subprocess.run(arguments, cwd=ROOT, env=env, check=True, timeout=240)
    for flag in ("--self-test", "--self-test-auto-update", "--self-test-panel",
                 "--self-test-menu-refresh"):
        run([str(BINARY), flag])
    for script in ("verify_update_recovery.py", "verify_product_portability.py", "verify_distribution.py", "verify_sync.py"):
        run(["python3", "scripts/" + script])
print("PASS: isolated product baseline (no publication or device acceptance)")
