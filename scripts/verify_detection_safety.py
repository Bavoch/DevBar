"""Read-only launch selection: no deploy, preview, project scripts or app replacement."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get("DEVBAR_TEST_BINARY", str(ROOT / ".build/release/DevBar"))
(ROOT / "work").mkdir(exist_ok=True)

with tempfile.TemporaryDirectory(prefix="Detection safety ", dir=ROOT / "work") as folder:
    base = Path(folder)
    env = dict(os.environ, DEVBAR_DATA_DIR=str(base / "state"), DEVBAR_HEADLESS="1")

    def write(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(content) if isinstance(content, dict) else content)

    def project(name, scripts, **metadata):
        path = base / name
        write(path / "package.json", dict(metadata, scripts=scripts))
        return path

    def cli(*args, codes=(0,)):
        result = subprocess.run([BINARY, *map(str, args)], env=env, text=True,
                                capture_output=True, timeout=30)
        assert result.returncode in codes, (result.returncode, result.stdout, result.stderr)
        return json.loads(result.stdout)

    def targets(path):
        return cli("--profile-project", path)["targets"]

    rejected = {
        "Deploy script": {"dev": "wrangler deploy"},
        "Preview script": {"dev": "vite preview", "start": "next start"},
        "Build alias": {"dev": "npm run build", "build": "vite build"},
        "Deploy alias": {"dev": "npm run release", "release": "wrangler deploy"},
        "Lifecycle deploy": {"dev": "node server.js", "predev": "wrangler deploy"},
        "Additional target deploy": {"dev:backend": "vercel deploy"},
    }
    for name, scripts in rejected.items():
        path = project(name, scripts)
        assert targets(path) == [], (name, targets(path))
        diagnosis = cli("doctor", path, "--json", codes=(0, 2))
        assert diagnosis["state"] == "unconfirmed", (name, diagnosis)
        assert any(issue["code"] == "launchCommandRejected" for issue in diagnosis["issues"]), diagnosis

    fallback = project("Safe fallback", {"dev": "wrangler deploy", "start": "node server.js"})
    assert [target["id"] for target in targets(fallback)] == ["start"]
    draft = cli("init", fallback, "--target", "start", "--plan")
    entry = draft["configuration"]["targets"]["start"]
    assert entry["strategy"] == "process" and entry["launchTarget"] == "start", entry
    assert not any(key in entry for key in ("installPath", "artifact", "buildCommand", "runtimeWitness")), entry
    assert not (fallback / ".devbar.json").exists()

    desktop = project("Desktop", {"dev": "node electron/dev.mjs"},
                      devDependencies={"electron": "1"},
                      build={"appId": "local.devbar.readonly", "productName": "Existing app"})
    draft = cli("init", desktop, "--target", "dev", "--plan")
    entry = draft["configuration"]["targets"]["dev"]
    assert entry["strategy"] == "process" and "installPath" not in entry, entry

    workspace = project("Workspace", {}, workspaces=["apps/*"])
    child = workspace / "apps/Child with spaces"
    write(child / "package.json", {"scripts": {"dev:worker": "npm run publish", "publish": "wrangler deploy"}})
    assert targets(workspace) == [], targets(workspace)
    write(child / "package.json", {"scripts": {"dev:worker": "node server.js"}})
    # Each CLI invocation starts with an empty discovery cache.
    selected = targets(workspace)
    assert len(selected) == 1 and selected[0]["id"] == "apps/Child with spaces:dev:worker", selected
    draft = cli("init", workspace, "--target", selected[0]["id"], "--plan")
    assert draft["configuration"]["targets"][selected[0]["id"]]["strategy"] == "process", draft

    outside = base / "Other project"
    write(outside / "main.py", "print('outside')\n")
    write(outside / "index.html", "<title>Outside</title>")
    write(outside / "package.json", {"scripts": {"dev": "node server.js"}})
    for name in ("main.py", "index.html", "package.json"):
        linked = base / ("Linked " + name)
        linked.mkdir()
        (linked / name).symlink_to(outside / name)
        assert targets(linked) == [], (name, targets(linked))
    linked_source = base / "Linked source"
    write(linked_source / "Package.swift", 'let package=Package(targets:[.executableTarget(name:"Example")])')
    (linked_source / "Sources").symlink_to(outside, target_is_directory=True)
    assert targets(linked_source) == [], targets(linked_source)
    internal = base / "Internal link"
    write(internal / "source/task.py", "print('inside')\n")
    (internal / "main.py").symlink_to(internal / "source/task.py")
    assert targets(internal)[0]["kind"] == "script", targets(internal)

    for name in ("package.json", "Package.swift", "Cargo.toml", "pyproject.toml", "project.yml", "Info.plist", "pnpm-workspace.yaml", "main.py", "index.html"):
        special = base / ("FIFO " + name)
        special.mkdir()
        os.mkfifo(special / name)
        assert targets(special) == [], (name, targets(special))
    desktop_fifo = base / "FIFO desktop metadata"
    write(desktop_fifo / "package.json", {"devDependencies": {"electron": "1"}})
    os.mkfifo(desktop_fifo / "electron-builder.yml")
    os.mkfifo(desktop_fifo / "Info.plist")
    write(desktop_fifo / "build/Fixture.app/Contents/MacOS/Fixture", "#!/bin/sh\nexit 0\n")
    (desktop_fifo / "build/Fixture.app/Contents/MacOS/Fixture").chmod(0o700)
    os.mkfifo(desktop_fifo / "build/Fixture.app/Contents/Info.plist")
    cli("--desktop-project", desktop_fifo)

    sync_fifo = base / "FIFO sync configuration"
    sync_fifo.mkdir()
    os.mkfifo(sync_fifo / ".devbar.json")
    diagnosis = cli("doctor", sync_fifo, "--json", codes=(0, 2))
    assert diagnosis["state"] == "unconfirmed", diagnosis
    (sync_fifo / ".devbar.json").unlink()

    assert not (base / "state").exists(), "Read-only discovery must not create user state"
    assert not list(base.rglob(".devbar.json")), "Plans must not write project configuration"
    print("PASS: unsafe entries and lifecycle hooks rejected; safe fallback/workspace targets; no inferred installed replacement; outside-root links and FIFO metadata rejected without blocking; all discovery read-only")
