# Changelog

## 0.3.0 — 2026-10-17

### Added
- **Plugin shell entries.** `hash-skill.sh --shell <install dir>` hashes a plugin's content outside
  `skills/` (agents, commands, scripts, hooks, rules, MCP config), skipping Claude Code's `.in_use/`
  lock files. `approve.py --shell` records it as a `kind: "plugin-shell"` ledger entry, with optional
  `--member-verdict NAME=REJECT` to block one member of an otherwise approved plugin.
- **Agent gate.** The hook now also runs on the `Agent` tool (`Skill|Agent|Task` matcher). A plugin
  agent (`<plugin>:<agent>`, `agents/<agent>.md`) needs its plugin's shell entry.
- **Plugin commands are gated.** `<plugin>:<command>` (`commands/<command>.md`) previously resolved
  to nothing and was allowed; it now needs the shell entry.
- `resolve-skill.sh --plugin-root`, `scripts/audit.sh`, `tests/test-plugin-shell.sh` (run in CI).
- `approve.py --risk-score/--risk-severity`; the ledger may live next to the scripts (standalone
  install), found before the `~/.claude/skillspector-gate` default.

### Changed
- Plugin skills now need both their skill entry and their plugin's shell entry. A plugin-qualified
  name from an installed plugin that matches no skill, command or agent on disk is denied.

### Upgrade note
- After updating, every plugin skill, command and agent is denied until its plugin's shell is
  approved: run `approve.py --shell` once per installed plugin. Per-skill entries are unchanged
  (the per-skill hash is byte-identical).

## 0.2.0 — 2026-10-17

### Fixed
- `scripts/hash-skill.sh` now pins `LC_ALL=C`. The skill content hash previously depended on
  the caller's collation, so an approval run from a UTF-8 shell (e.g. `en_US.UTF-8`) produced a
  different hash from the `PreToolUse` hook, which runs with no `LANG`, and approved, unchanged
  skills were denied as "changed since last scan" (#15).

### Added
- `tests/test-hash-locale.sh` regression test and a CI workflow running it on macOS and Ubuntu (#15).

### Upgrade note
- Ledger entries approved under a non-C locale mismatch once after updating. Re-run
  `approve.py` for each to rehash. Entries approved under `C`/no locale are unaffected.

## 0.1.0 — 2026-09-18

- Initial release: Claude Code plugin for the SkillSpector execution gate.
