"""Verify stopping a project is fast and actually terminates desktop-like (SIGTERM-ignoring) processes.

Reproduces the slow/unresponsive "stop" reported for projects whose managed process
ignores SIGTERM (Electron/Chromium-style). The fixture process tree:
  - opens a TCP listener and accepts connections,
  - installs signal.signal(SIGTERM, SIG_IGN) so SIGTERM is ignored,
  - spawns a descendant in a new session that also ignores SIGTERM.

A plain python http.server fixture (which respects SIGTERM) must keep stopping fast.

The buggy binary performed two full Discovery.scan calls (~7s) during stop, sent only
SIGTERM, polled for 5s, then reported an error while leaving the SIGTERM-ignoring
process alive. The fix performs a single scan, waits a short grace, then escalates to
SIGKILL for a managed process group that refuses SIGTERM.

Because a single Discovery.scan dominates wall-clock time and its cost depends on the
machine's process/listener load, the harness measures each project's stop time
*relative to one baseline scan* taken with the same data directory. That isolates the
stop logic itself:

  delta = stop_wall_clock - baseline_scan

On the buggy binary delta is roughly two extra scans plus the 5s poll (several
seconds) and the process survives; with the fix delta is only the short grace period
and the process is gone. An absolute wall-clock backstop is also asserted.
"""
import json
import os
import pathlib
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(__file__).resolve().parents[1]
binary = str(root / '.build/release/DevBar')
assert pathlib.Path(binary).is_file(), f'Missing binary: {binary} (run zsh scripts/build.sh)'
(root / 'work').mkdir(exist_ok=True)

# Overhead allowed for `--stop-project` beyond one discovery scan. The fixed code
# adds only a short SIGKILL grace; the buggy code added two scans (~+8s) plus a 5s
# poll, so this bound cleanly separates them regardless of machine scan speed.
STUBBORN_DELTA_BOUND = 4.5
NORMAL_DELTA_BOUND = 3.0
# Absolute backstops so a machine whose scan is unusually slow still fails loudly
# instead of silently passing a multi-second stop.
STUBBORN_ABS_BOUND = 5.0
NORMAL_ABS_BOUND = 2.0

failures = []


def report(ok, message):
    print(f'{"PASS" if ok else "FAIL"}: {message}', flush=True)
    if not ok:
        failures.append(message)


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def listening(number):
    try:
        with socket.create_connection(('127.0.0.1', number), timeout=0.1):
            return True
    except OSError:
        return False


def until(predicate, message, attempts=200):
    for _ in range(attempts):
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError(message)


def listen_pids(number):
    """PIDs currently listening on the given TCP port (empty when closed)."""
    result = subprocess.run(['/usr/sbin/lsof', '-nP', f'-iTCP:{number}', '-sTCP:LISTEN', '-t'],
                            capture_output=True, text=True)
    return [int(tok) for tok in result.stdout.split() if tok.strip().isdigit()]


def kill_pids(pids):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


STUBBORN_APP = '''import socket
import signal
import subprocess
import sys
import time

# Emulate Electron/Chromium: SIGTERM is deliberately ignored by the whole tree.
signal.signal(signal.SIGTERM, signal.SIG_IGN)
descendant = subprocess.Popen(
    [sys.executable, '-c',
     'import signal, time\\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\\ntime.sleep(600)'],
    start_new_session=True)
# Record the descendant PID so the harness can always reap it, even though it
# lives in its own session/group and never listens on a port.
with open(PID_FILE, 'w') as handle:
    handle.write(str(descendant.pid))

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('127.0.0.1', PORT))
listener.listen(16)
print('stubborn fixture ready', flush=True)
while True:
    connection, _ = listener.accept()
    connection.sendall(b'ok')
    connection.close()
'''


def write_stubborn_fixture(project, number):
    script = project / 'app.py'
    pid_file = project / 'descendant.pid'
    source = STUBBORN_APP.replace('PORT', str(number)).replace('PID_FILE', repr(str(pid_file)))
    script.write_text(source)
    return script


with tempfile.TemporaryDirectory(prefix='Stop latency ', dir=root / 'work') as folder:
    base = pathlib.Path(folder)
    state = base / 'state'
    env = dict(os.environ, DEVBAR_DATA_DIR=str(state))
    runners = []
    tracked_ports = []
    tracked_pid_files = []

    def cli(*args, check=True, timeout=45):
        return subprocess.run([binary, *args], env=env, text=True,
                              capture_output=True, timeout=timeout, check=check)

    def baseline_scan():
        began = time.time()
        cli('--scan-json')
        return time.time() - began

    def start(ident, number, label):
        runner = subprocess.Popen([binary, '--start-project', ident, '--wait'], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        runners.append(runner)
        line = runner.stdout.readline().strip()
        assert line == 'Started', f'{label} launcher must report start, got {line!r}'
        until(lambda: listening(number), f'{label} fixture failed to start on port {number}')
        return runner

    def measure_stop(ident, number, label, baseline):
        """Run --stop-project, returning (elapsed, delta, rc, stderr, port_closed)."""
        began = time.time()
        result = cli('--stop-project', ident, check=False)
        elapsed = time.time() - began
        # Give the OS a brief moment to release the listening socket. Do not raise
        # when it stays open: a surviving process is the regression we want to
        # report as FAIL below, not crash on.
        for _ in range(20):
            if not listening(number):
                break
            time.sleep(0.1)
        closed = not listening(number)
        delta = elapsed - baseline
        print(f'  {label}: stop {elapsed:.2f}s (delta vs scan {delta:+.2f}s, rc={result.returncode}, '
              f'port {number} {"closed" if closed else "STILL OPEN"})', flush=True)
        return elapsed, delta, result.returncode, result.stderr.strip(), closed

    try:
        # --- Fixture A: stubborn, SIGTERM-ignoring desktop-like process tree ---
        stubborn = base / 'Stubborn Desktop'
        stubborn.mkdir()
        stubborn_port = port()
        script = write_stubborn_fixture(stubborn, stubborn_port)
        tracked_pid_files.append(stubborn / 'descendant.pid')
        stubborn_command = f'{shlex.quote(sys.executable)} -u {shlex.quote(str(script))}'
        stubborn_id = cli('--add-project', str(stubborn), '--name', 'Stubborn Desktop',
                          '--command', stubborn_command).stdout.strip()
        start(stubborn_id, stubborn_port, 'stubborn')
        tracked_ports.append(stubborn_port)
        print(f'  stubborn fixture listening on {stubborn_port}', flush=True)

        baseline = baseline_scan()
        elapsed, delta, code, stderr, closed = measure_stop(
            stubborn_id, stubborn_port, 'stubborn', baseline)

        # Core behavioural regression: the process must actually be gone.
        remaining = listen_pids(stubborn_port)
        if remaining:
            kill_pids(remaining)
        report(closed and not remaining,
               f'SIGTERM-ignoring process is terminated (port {stubborn_port} '
               f'{"closed" if closed and not remaining else "STILL OPEN"})')
        report(code == 0,
               f'stop reports success for a force-killed desktop process (rc={code})'
               + (f', stderr={stderr!r}' if stderr else ''))
        report(delta < STUBBORN_DELTA_BOUND,
               f'no redundant discovery scans on stop (delta {delta:+.2f}s < '
               f'{STUBBORN_DELTA_BOUND:.1f}s beyond one baseline scan)')
        report(elapsed < STUBBORN_ABS_BOUND,
               f'SIGTERM-ignoring stop is bounded ({elapsed:.2f}s < {STUBBORN_ABS_BOUND:.0f}s)')

        # --- Fixture B: normal, SIGTERM-respecting web server ---
        normal = base / 'Normal Web'
        normal.mkdir()
        normal_port = port()
        normal_command = f'{shlex.quote(sys.executable)} -m http.server {normal_port} --bind 127.0.0.1'
        normal_id = cli('--add-project', str(normal), '--name', 'Normal Web',
                        '--command', normal_command).stdout.strip()
        start(normal_id, normal_port, 'normal')
        tracked_ports.append(normal_port)
        print(f'  normal fixture listening on {normal_port}', flush=True)

        normal_baseline = baseline_scan()
        n_elapsed, n_delta, n_code, n_stderr, n_closed = measure_stop(
            normal_id, normal_port, 'normal', normal_baseline)
        n_remaining = listen_pids(normal_port)
        if n_remaining:
            kill_pids(n_remaining)
        report(n_code == 0 and n_closed,
               f'normal project stops cleanly (rc={n_code}, port '
               f'{"closed" if n_closed else "STILL OPEN"})')
        report(n_delta < NORMAL_DELTA_BOUND,
               f'normal project stop has no redundant scans (delta {n_delta:+.2f}s < '
               f'{NORMAL_DELTA_BOUND:.1f}s)')
        report(n_elapsed < NORMAL_ABS_BOUND,
               f'normal project stop is bounded ({n_elapsed:.2f}s < {NORMAL_ABS_BOUND:.0f}s)')

        # --- Persistence: projects remain registered after stop ---
        try:
            rows = json.loads(cli('--list-projects').stdout)
            ids = {row['id'] for row in rows}
            report(stubborn_id in ids and normal_id in ids,
                   'projects remain persisted after being stopped')
        except (subprocess.CalledProcessError, ValueError) as error:
            report(False, f'could not list projects after stop: {error}')

    finally:
        # Cleanup: always terminate leftover fixture processes and free their ports,
        # even on failure. Only fixture process groups and tracked ports are touched.
        for record_path in state.glob('*.run.json'):
            try:
                record = json.loads(record_path.read_text())
                if os.getpgid(record['pid']) == record['pid']:
                    os.killpg(record['pid'], signal.SIGKILL)
            except (ProcessLookupError, ValueError, OSError):
                pass
        for number in tracked_ports:
            kill_pids(listen_pids(number))
        # Descendants started in a new session never listen and are not part of the
        # managed group, so reap them from their recorded PID files explicitly.
        for pid_file in tracked_pid_files:
            try:
                kill_pids([int(pid_file.read_text().strip())])
            except (OSError, ValueError):
                pass
        for runner in runners:
            if runner.poll() is None:
                runner.kill()
            try:
                runner.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass

if failures:
    print(f'FAIL: {len(failures)} stop-latency check(s) failed', flush=True)
    sys.exit(1)
print('PASS: stop is fast and reliably terminates SIGTERM-ignoring desktop processes', flush=True)
