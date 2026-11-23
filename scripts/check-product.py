"""Portable baseline for contributors and CI; never builds or opens browser windows."""
from pathlib import Path
import os
import subprocess
import sys
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
    for flag in ("--self-test", "--self-test-native-menu",
                 "--self-test-menu-refresh", "--self-test-freshness"):
        run([str(BINARY), flag])
    for script in ("verify_store_safety.py", "verify_detection_safety.py",
                   "verify_runtime_safety.py", "verify_unified_control.py", "verify_multi_target.py", "verify_interaction_latency.py",
                   "verify_product_portability.py", "verify_distribution.py", "verify_icons.py", "verify_sync.py",
                   "verify_permission_ownership.py", "verify_development_isolation.py", "verify_development_entry.py"):
        run([sys.executable, "scripts/" + script])
print("PASS: isolated product baseline (no publication or device acceptance)")
