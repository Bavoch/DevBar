# Changelog

## 0.14.1 — Unreleased

- Add an application-update setup entry that remains available when configuration
  is missing or invalid, and allow automatic updates to be disabled in that state.
- Offer reviewed recovery drafts from the selected project's previous successful
  update; saving never overwrites an existing configuration.
- Pause automatic updates for missing/changed targets and mismatched installation
  paths, and show version uncertainty instead of claiming an outdated build.
- Ignore delayed update events after automatic updates have been disabled.
- Add contributor/reporting templates, isolated product checks and macOS CI.

Earlier local development releases are described in the existing release and
platform documentation; they are not retroactively certified public releases.
