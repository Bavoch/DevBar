# Contributing to DevBar

DevBar is a distributable native macOS product for developers. Read
[product principles](docs/product-principles.md) and the
[platform matrix](docs/platform-matrix.md) before adding adapters.

## Development

Use macOS 13 or later with Xcode Command Line Tools and Swift 5.9 or later.
Some device and simulator checks require full Xcode or additional host tools;
they are not dependencies of the basic menu-bar app.

```sh
zsh scripts/build.sh
python3 scripts/check-product.py
```

Build once after a coherent change, then run relevant checks. The product check
uses isolated state and fixtures without foreground browser windows. It does not
require the maintainer's projects, installed DevBar, credentials, or devices.
For a specific adapter, add the relevant acceptance scripts documented in
[release checks](docs/release.md). Never run tests against personal host profiles.

`DEVBAR_DATA_DIR` selects isolated app state. Runtime adapters must obtain real
version evidence; do not infer successful updates from a running wrapper, expected
version, process count, or refreshed observation baseline. Discovery must remain
read-only and must never execute a newly discovered project's scripts.

Keep personal paths, project names, credentials, generated apps, build caches and
local acceptance records out of contributions. Project-specific absolute paths
may belong in local configuration, not product defaults. Preserve explicit user
configuration and other targets when changing setup or migrations.

## Pull requests

Explain the trigger, resulting behavior, relevant validation, and unverified
platforms. Fixes need focused regressions when they affect process ownership,
configuration, runtime proof, update recovery, or data preservation. UI changes
need offscreen inspection and human acceptance where applicable; headless checks
do not substitute for the latter.

## Release work

Development builds are ad-hoc signed. Public macOS distribution requires the
separate signing, notarization and Gatekeeper steps in [release.md](docs/release.md).
CI checks do not publish a release. Do not commit signing certificates or accounts.

Optional host checks require explicit test inputs: `DEVBAR_TEST_WRANGLER` points
to an installed Wrangler package, and `DEVBAR_DSH_HOST` to an installed official
DSH entry. No personal checkout is used as a default. `verify_environment.py`
requires VitePress project directories as arguments; `verify_icons.py` takes
optional project directories after completing its isolated fixtures. Host tests
can start the selected runtime, so use dedicated test installations.
