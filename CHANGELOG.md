# Changelog

## 0.5.0 — 2026-11-13

### Added
- **Approval carry-forward across plugin versions.** The ledger is keyed by real path, so every
  plugin update (a new `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`) re-blocked
  byte-identical skills and shells and left dead entries (seen 2026-11-13: `mcp-server-dev` ×3
  and `playground` moved `ea10b213686c` → `f75f5b25ae94` with identical hashes and had to be
  re-approved by hand). `scripts/carry.py` now lets the gate allow a directory with no entry of
  its own when an entry for the same marketplace, plugin directory and relative path, the same
  kind and an identical hash is `APPROVE`/`CAUTION`, and no entry with that kind and hash is
  `REJECT`. A carried shell keeps the union of its sources' `member_verdicts` REJECTs. Only
  installed plugins whose root is exactly `<cache>/<mkt>/<plugin>/<version>` carry; synced
  plugins, other install paths and global/project skills do not.
- `approve.py --carry-forward [--apply]` records carried approvals at their new paths
  (`carried_from`, `carried_by`, `carried_at`); `approve.py --prune [--apply]` removes dead
  `APPROVE`/`CAUTION` entries that carry nothing. Both are dry runs without `--apply`. Prune
  never removes a `REJECT` or an entry still carrying an approval to a live directory.
- `tests/test-carry-forward.sh` (run in CI).

### Changed
- The gate's ledger lookup moved from inline Python in `gate-skill.sh` to `carry.py`. Exact-path
  behaviour is unchanged: an entry at the exact path always decides, and carry-forward is
  considered only when there is none. The gate still never writes the ledger.

### Upgrade note
- Install `carry.py` alongside the other scripts; `gate-skill.sh` 0.5.0 denies everything
  (fail-closed) without it.
- A release that bumps `plugin.json`'s version string changes the shell hash, so the shell still
  needs review; unchanged skills carry.

## 0.4.0 — 2026-11-11

### Added
- **claude.ai-synced plugins are gated.** Plugins synced from a claude.ai account into
  `~/.claude/plugins/synced/<account>/` were not in `installed_plugins.json`, so every
  `<plugin>:<member>` from them resolved to nothing and was allowed. `scripts/plugin-index.py`
  now maps a plugin name to every root it has: installed (all marketplaces and scopes) and synced
  (the live directory the account's `manifest.json` names, `<name>~g<N>` for generation N > 1;
  older generations on disk are ignored). Synced skills, commands and agents need their skill
  entry and the plugin's shell entry, exactly like installed ones.
- `plugin.json` `"skills"`, `"commands"` and `"agents"` paths are honoured when finding a member
  (e.g. a plugin whose commands live in `flows/`).
- `audit.sh` walks synced plugins; `tests/test-synced-plugins.sh` (52 checks, run in CI).

### Security (judge review of this release)
- A command or agent file must be a regular file inside the plugin root and outside every
  `skills/` skill directory. `hash-skill.sh --shell` skips skill directories, so a `plugin.json`
  `"commands"`/`"agents"` path (or a symlink) pointing into one would otherwise have run with
  no hash covering it. Applies to installed plugins too.
- A broken synced manifest entry fails closed: a non-integer generation, or a live `~g<N>` dir
  missing while another generation is on disk, denies that plugin's name; an unreadable manifest,
  a malformed entry or a non-string `plugin.json` name denies every plugin-qualified name the
  index cannot resolve. `plugin-index.py list` and `audit.sh` report and fail on a broken source
  (including an unreadable `installed_plugins.json`, which 0.3.0's audit skipped silently).
- `plugin.json` paths that are absolute or leave the plugin root are ignored.

### Changed
- A name with several roots (installed and synced, two accounts) is checked at every root: every
  shell approved, plus the member's own entry in each root that holds it. The member need only
  exist in one root (0.3.0 denied when any install dir lacked it): which root Claude Code serves
  a name from is not stated, so each root that could serve it is checked.
- Member lookup (skills, commands, agents incl. frontmatter `name:`) moved from `gate-skill.sh`
  and `resolve-skill.sh` into `plugin-index.py`, so the gate, the resolver and the audit share one
  implementation. Behaviour for installed plugins is unchanged (`tests/test-plugin-shell.sh`
  passes unmodified apart from one label).

### Upgrade note
- After updating, every member of every synced plugin is denied until reviewed and approved:
  `approve.py --shell <synced dir>` per plugin plus `approve.py <skill dir>` per skill. Ledger
  entries are keyed by path, so a later generation bump (a new `~g<N>` directory) or a re-sync
  that changes content denies again until re-approved.
- Not covered, as before: synced plugins' hooks and MCP servers load on their own events, not
  through `Skill`/`Agent`. Remove or disable a plugin on claude.ai to stop those.

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
- `approve.py --risk-score/--risk-severity`; a standalone install's ledger at
  `~/.claude/skillspector/ledger.json` is found when `~/.claude/skillspector-gate` has none.

### Security (adversarial review of this release)
- Symlinks are hashed (by link text) in both modes; a symlink resolving outside the hashed
  directory makes `hash-skill.sh` exit 3 and the gate deny. Previously `find -type f` skipped
  them, so a symlinked script's target could change under an approved hash. No existing ledger
  entry contained a symlink, so per-skill hashes are unchanged.
- The shell hash covers loose files under `skills/` (anything not inside a directory holding a
  `SKILL.md`), and skips only `.in_use/<pid>` lock files, not the whole `.in_use/` directory.
- A plugin name listed under several marketplaces or scopes is checked at every install dir; a
  listed plugin whose install dir is missing is denied.
- The ledger is read only from home paths (`$SKILLSPECTOR_GATE_HOME`, `~/.claude/skillspector-gate`,
  then the standalone `~/.claude/skillspector`), never from the scripts' own install dir.
- Unparseable hook input is denied instead of allowed.
- Plugin agents are also found by their frontmatter `name:`.

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
