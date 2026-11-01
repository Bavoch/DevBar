"""DevBar repository's own dev command; never used to launch other projects."""
from pathlib import Path
import json
import os
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / '.build/dev-watch.json'
action = sys.argv[1] if len(sys.argv) > 1 else 'run'

def signature(pid):
    return subprocess.run(['ps', '-p', str(pid), '-o', 'lstart='], capture_output=True, text=True).stdout.strip()

if action in ('status', 'stop'):
    try:
        state = json.loads(STATE.read_text())
        active = bool(state['signature']) and signature(state['pid']) == state['signature']
    except (OSError, ValueError, KeyError):
        active = False
    if action == 'stop' and active:
        os.kill(state['pid'], signal.SIGTERM)
        print('DevBar development stop requested')
    else:
        print('DevBar development running' if active else 'DevBar development stopped')
    sys.exit(0)

try:
    existing = json.loads(STATE.read_text())
    if existing['signature'] and signature(existing['pid']) == existing['signature']:
        print('DevBar development already running')
        sys.exit(0)
except (OSError, ValueError, KeyError):
    pass

stopping = False
def stop(*_):
    global stopping
    stopping = True
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

def snapshot():
    result = {}
    for base in (ROOT/'Sources', ROOT/'drivers', ROOT/'Package.swift'):
        files = [base] if base.is_file() else base.rglob('*')
        for path in files:
            if path.is_symlink() or not path.is_file():
                continue
            try:
                stat = path.stat(); result[str(path)] = (stat.st_mtime_ns, stat.st_size)
            except FileNotFoundError:
                pass
    return result

def end(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=4)
    except subprocess.TimeoutExpired:
        process.kill(); process.wait()

ROOT.joinpath('.build').mkdir(exist_ok=True)
STATE.write_text(json.dumps({'pid': os.getpid(), 'signature': signature(os.getpid())}))
child = None
try:
    previous = None
    while not stopping:
        current = snapshot()
        if current != previous:
            time.sleep(.3)
            previous = snapshot()
            end(child); child = None
            print('DevBar dev: building debug sources…', flush=True)
            build = subprocess.Popen(['swift', 'build'], cwd=ROOT)
            while build.poll() is None and not stopping:
                time.sleep(.1)
            if stopping:
                end(build); break
            if build.returncode == 0:
                child = subprocess.Popen([str(ROOT/'.build/debug/DevBar')], cwd=ROOT)
                print('DevBar dev: running; watching this repository only', flush=True)
            else:
                print('DevBar dev: build failed; waiting for a source change', flush=True)
        time.sleep(.4)
finally:
    end(child)
    try:
        STATE.unlink()
    except FileNotFoundError:
        pass
