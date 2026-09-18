# Third-party notices

This project's own code (everything except the file listed below) is
licensed under Apache-2.0 — see [`LICENSE`](LICENSE).

## `skills/skill-inspector/SKILL.md`

Copied **verbatim, byte-for-byte, unmodified** from
[NVIDIA/skillspector](https://github.com/NVIDIA/skillspector)
at commit [`d162d9b3`](https://github.com/NVIDIA/skillspector/blob/d162d9b343e559be13df8ebba093df3bc9d58c90/skills/skill-inspector/SKILL.md)
(`skills/skill-inspector/SKILL.md`).

- **License:** Apache-2.0 (same license as this repository; the upstream
  project ships no separate `NOTICE` file to propagate).
- **Copyright:** NVIDIA Corporation and SkillSpector contributors.
- **Why it's vendored rather than fetched at install time:** Claude Code
  plugins are self-contained bundles with no install-time script hook to
  pull external content, so a working copy has to ship in the plugin
  itself. If you want the current upstream version, diff this file
  against the one at the URL above and open a PR here.

Everything else in this repository — `scripts/*.sh`, `scripts/approve.py`,
the plugin/marketplace/hook manifests, and this documentation — is
original work, not derived from SkillSpector's source, and is licensed
under Apache-2.0 in its own right. It depends on the `skillspector` CLI
as an external runtime dependency (installed separately, not vendored),
also Apache-2.0.
