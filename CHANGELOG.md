# Changelog

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
