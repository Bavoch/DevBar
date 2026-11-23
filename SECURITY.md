# Security policy

The latest published DevBar version is the supported version for security
fixes. Please check [GitHub Releases](https://github.com/Bavoch/DevBar/releases)
for its version and distribution status.

## Report privately

Use [Report a vulnerability](https://github.com/Bavoch/DevBar/security/advisories/new)
on GitHub. Include the DevBar and macOS versions, prerequisites, impact, and a
minimal reproduction. Redact credentials, personal paths, and unrelated project
data. Keep vulnerability details and full logs out of public issues.

## Local execution and data

DevBar inspects local processes and can run project commands. Review unfamiliar
projects and their `.devbar.json` before running them. Adding and discovering
projects does not execute their commands. DevBar checks process identity and
project ownership before controlling a running instance.

The core app requires no account and sends no project telemetry. Project lists
and logs stay under `~/Library/Application Support/DevBar` unless you share them.
Commands that you run through DevBar retain their own behavior and permissions.
