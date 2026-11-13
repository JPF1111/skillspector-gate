# skillspector-gate

**A mandatory pre-execution security gate for Claude Code Skills.**

AI agent skills execute with your permissions and read your files. This plugin makes sure
none of them run until [NVIDIA SkillSpector](https://github.com/NVIDIA/skillspector) has
scanned them and a human (or Claude's own source-aware review) has approved them — and it
re-blocks automatically the instant an approved skill's content changes.

```
$ claude
> [skill invocation for something never scanned]
✗ skillspector-gate: 'shady-skill' has never been scanned/approved.
  Review it with the skill-inspector skill, then:
  python3 .../approve.py '/path/to/shady-skill' --verdict APPROVE --note '...'
```

## Why

Skills are just files — anyone can publish one, and a session invokes them with the same
trust it gives its own tools. [SkillSpector's research](https://github.com/NVIDIA/skillspector#overview)
found vulnerabilities in **26.1%** of a large sample of published skills and likely-malicious
intent in **5.2%**. SkillSpector itself is a scanner you run by hand; this plugin turns "you
should scan skills before installing them" into "skills that haven't been scanned and
approved simply don't run."

## What's in the box

- **The gate** — a `PreToolUse` hook on the `Skill` and `Agent` tools. Before any skill runs, it
  resolves the skill's name to its real on-disk directory, hashes the directory's contents, and
  checks a local approval ledger. No entry, a hash mismatch (content changed since approval), or a
  `REJECT` verdict → blocked, with the exact command to unblock it printed in the error. For a
  plugin, the gate also checks the plugin's **shell** — everything in its install directory
  outside `skills/` (agents, commands, scripts, hooks, rules, MCP config) — so a plugin agent, a
  plugin command, or a plugin-level script a skill runs cannot change without re-approval.
- **`audit.sh`** — runs every skill, plugin command and plugin agent (installed and claude.ai-synced) through the gate
  and prints each decision.
- **`skill-inspector`** — SkillSpector's own companion Claude Code Skill (vendored verbatim,
  see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)), which runs the static scan and then
  a source-aware semantic read, and reports `APPROVE` / `CAUTION` / `REJECT`.
- **`approve.py`** — records a verdict into the ledger so the gate lets that skill run.
  `--carry-forward` and `--prune` maintain the ledger across plugin updates (below).
- **`carry.py`** — the ledger lookup the gate uses, including approval carry-forward.

Nothing here requires an LLM API key. Both the gate's own hashing/lookup and
`skill-inspector`'s scripted scan step run with `skillspector --no-llm` — the *semantic*
review layer is Claude reading the source itself, not a second model call.

## Install

**Prerequisite** — the SkillSpector CLI:

```bash
uv tool install git+https://github.com/NVIDIA/skillspector.git
# or: pipx install skillspector  (see SkillSpector's own README for other options)
```

**Claude Code:**

```
/plugin marketplace add JPF1111/skillspector-gate
/plugin install skillspector-gate
```

That's it — the hook is wired automatically (no manual `settings.json` editing). Restart or
reload hooks (`/hooks`) to pick it up in an already-running session.

## Usage

**Review a skill:**

> "Is this skill safe to install: `<path-or-repo-url>`"

fires `skill-inspector`, which runs the static scan, reads the source itself, and reports a
verdict with evidence. This does *not* by itself unblock the skill — reviewing and approving
are separate steps, so a skill can be inspected without granting it the ability to run.

**Approve a skill so it can run:**

```bash
python3 <plugin-dir>/scripts/approve.py "<resolved skill dir>" \
  --verdict APPROVE --note "why — cite what was actually checked"
```

- `--verdict` is required: `APPROVE`, `CAUTION`, or `REJECT`. `CAUTION` still lets the skill
  run — it's a flag that something wasn't fully hand-verified, not a block.
- Omit `--skip-scan` (default) to have it re-run `skillspector scan` and record the current
  score/severity/recommendation alongside your verdict.
- `<plugin-dir>` — find it with `claude plugin details skillspector-gate`, or use the exact
  command the gate's own deny message prints the first time it blocks the skill.

**Approve a plugin's shell** (needed once per installed plugin version before any of its
skills, commands or agents run):

```bash
python3 <plugin-dir>/scripts/approve.py --shell "<plugin install dir>" \
  --verdict CAUTION --note "agents/, scripts/, mcp.json read; ..." \
  [--member-verdict some-agent=REJECT]
```

`--member-verdict NAME=REJECT` blocks one skill, command or agent of an otherwise approved
plugin. The install dir is the plugin's `installPath` in `~/.claude/plugins/installed_plugins.json`,
or the path the gate's deny message prints. A plugin update installs to a new versioned path.

**Plugin updates (carry-forward, 0.5.0+).** The ledger is keyed by real path, and a plugin update
installs to a new `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`. When a skill or
shell there has no entry of its own, the gate carries the approval forward from an earlier
version, but only when all of these hold:

- the plugin root has exactly that cache shape (any other `installPath`, claude.ai-synced
  plugins, and global or project skills never carry);
- the source entry has the same marketplace, plugin directory and path inside the version root,
  the same kind (skill or plugin shell), an identical content hash, and verdict `APPROVE` or
  `CAUTION`;
- no entry anywhere with that kind and hash is `REJECT`;
- the skill's real path is inside its plugin root.

An entry at the exact path always decides (a stale hash or a `REJECT` there denies). A carried
shell keeps every `member_verdicts` REJECT of its sources. The shell hash covers
`.claude-plugin/plugin.json`, so a release that bumps the plugin's version string changes the
shell hash and still needs a fresh shell review; skills that did not change carry. The gate itself
never writes the ledger. To record carried approvals at their new paths and then drop dead entries:

```bash
python3 <plugin-dir>/scripts/approve.py --carry-forward           # dry run: what would be recorded
python3 <plugin-dir>/scripts/approve.py --carry-forward --apply   # record them (carried_from, carried_by)
python3 <plugin-dir>/scripts/approve.py --prune                   # dry run
python3 <plugin-dir>/scripts/approve.py --prune --apply
```

A recorded carried entry takes `CAUTION` if any source was `CAUTION`, and it still yields to a
later `REJECT` of the same bytes anywhere. `--prune` removes an entry only when it is in the plugin
cache, its directory is gone, its verdict is `APPROVE` or `CAUTION`, it holds no member `REJECT`,
and it is not still carrying an approval to a live directory. `REJECT` entries are never pruned.
`approve.py` locks `ledger.json.lock` for every write.

**Audit everything:** `bash <plugin-dir>/scripts/audit.sh --quiet` — exits non-zero if anything is
denied for a reason other than a recorded `REJECT`.

**Re-approve after a skill changes:** same command — the ledger is keyed by content hash, so
editing a skill's files already invalidated the old entry.

**Check a skill's status:**

```bash
jq --arg p "$(<plugin-dir>/scripts/resolve-skill.sh <name> "$PWD")" '.[$p]' \
  ~/.claude/skillspector-gate/ledger.json
```

## How it works

`PreToolUse` on the `Skill` tool receives only `{"skill": "<name>", "args": "..."}` — no
resolved path. `scripts/resolve-skill.sh` maps a name to a real directory (global
`~/.claude/skills/<name>`, project-level `.claude/skills/<name>` walking up from `cwd`, or
`<plugin>:<skill>` resolved by `scripts/plugin-index.py` against
`~/.claude/plugins/installed_plugins.json` and the claude.ai-synced plugins under
`~/.claude/plugins/synced/<account>/`).
`scripts/hash-skill.sh` produces a SHA-256 over every file's path+content, sorted, so it's
order-independent and changes on any edit. It pins `LC_ALL=C`, so the sort order (and the hash)
is the same whether it runs from your shell or from a hook with no `LANG` set. `scripts/gate-skill.sh` ties it together and emits
the hook's `allow`/`deny` decision.

**What's gated:** anything under `~/.claude/skills/` (except `synced/`), project-level
`.claude/skills/`, and — for any plugin listed in `installed_plugins.json` (at every install
directory its name maps to: all marketplaces and scopes) or synced from your claude.ai account
(`~/.claude/plugins/synced/<account>/`, at the live directory the account's `manifest.json`
names: `<name>`, or `<name>~g<N>` for generation N > 1; older generations left on disk are not
loaded and not checked) — its skills
(`Skill` tool), its commands (`Skill` tool, `commands/<name>.md` or the directory `plugin.json`
`"commands"` names) and its agents (`Agent` tool, `agents/<name>.md` or by frontmatter `name:`).
A name that is both installed and synced (or synced under two accounts) is checked at every root:
each shell must be approved, plus the member's own entry in each root that holds it. A re-sync
that changes content, or a generation bump that moves the live directory, denies until the new
content is re-approved. A command or agent file inside a skill directory is not found (the
shell hash leaves skill directories to their own entries). A broken synced manifest fails
closed: a bad entry denies that plugin's name, and an unreadable manifest or a malformed entry
whose name cannot be read denies *every* plugin-qualified name the index cannot resolve until it
is fixed; `python3 scripts/plugin-index.py list` names the cause. Every plugin member also needs the plugin's shell entry
(`hash-skill.sh --shell`: the install dir minus its skill directories and Claude Code's
`.in_use/<pid>` lock files). Symlinks are hashed by link text; a symlink pointing outside the
hashed directory fails the hash, so the gate denies. Unparseable hook input, and a listed plugin
whose install dir is missing, are denied. Compiled Python (`__pycache__/`) is hashed, so a
plugin whose hooks run Python goes stale once after its first run (and after a Python upgrade)
and needs re-approval then. A plugin-qualified name from an installed or synced plugin that matches no skill, command or
agent on disk is denied.

**Not covered — stated so no one mistakes this for more than it is:**
- A file reached by *reading* it (the `Read` tool, `cat`, a link one skill gives to another, or a
  skill downloaded at run time and then "read and followed") is not an invocation and is not
  gated. Content an approved skill reads from inside its own directory or its plugin's shell is
  covered by those hashes; anything else it fetches is governed by your instruction-source rules,
  not this ledger. A `Read` gate was considered and not built: it would also block the review step
  (`skill-inspector` has to read a skill before it can be approved).
- A skill that runs a file from a *sibling* skill directory of its plugin is not invalidated when
  that sibling changes; the sibling's own entry is. Loose files under `skills/` (outside any
  directory holding a `SKILL.md`) are in the shell hash.
- Plugin **hooks** run on their own events, not through `Skill` or `Agent`, so a `PreToolUse` gate
  cannot stop them. Their files are in the shell hash, which flags a change at the next skill or
  agent call from that plugin, but the hook itself has already run by then.
- Non-plugin subagent types (built-in, `~/.claude/agents/`, project `.claude/agents/`).
- Remote MCP servers a plugin's `mcp.json` points at: the config is hashed, the server is not.

**What's intentionally not gated:** Claude Code's own bundled/built-in skills (no on-disk
directory to hash) and skills synced from your claude.ai account under
`~/.claude/skills/synced/` (first-party content via an authenticated channel — same trust
tier as the CLI itself). Plugins synced from claude.ai are *not* in that tier: they are
third-party marketplace plugins delivered through the account, so they are gated like installed
ones (0.4.0). The gate controls *execution*, not installation — copying files into
`~/.claude/skills/` is unrestricted; only running them is blocked.

## A note on SkillSpector's raw scores

Static keyword-matching scanners produce false positives on documentation-heavy skills —
confirmed directly during this project's own testing: several large, entirely benign
reference-doc skills scored `CRITICAL`/100 purely from words like `credentials.json` or
`.env` appearing in prose (troubleshooting guides, API listings, `.gitignore` templates), not
in executable code. Treat the score as risk *posture*, not a verdict — read what actually
triggered a finding before deciding, which is exactly what `skill-inspector`'s semantic layer
is for.

## Troubleshooting

- **A skill I approved is still blocked** — almost always a hash mismatch: something in the
  skill directory changed since the last `approve.py` run (even a trailing newline). Re-run
  it. After a plugin update, check whether the old version's entry was pruned before
  `--carry-forward --apply` recorded the new one, or whether the update changed the shell
  (often just the `plugin.json` version).
- **Approved skills blocked after updating to the locale fix** — before `hash-skill.sh` pinned
  `LC_ALL=C`, the hash depended on the caller's collation: an approval run from a UTF-8 shell
  (e.g. `en_US.UTF-8`) sorted files differently from the hook, which runs with no `LANG`.
  Ledger entries recorded under a non-C locale will mismatch once; re-run `approve.py` for each
  to rehash. Entries recorded under `C`/no locale are unaffected.
- **`skillspector: command not found`** — install it (see above); `approve.py` checks `PATH`
  first, then `~/.local/bin/skillspector`.
- **Hook doesn't seem to fire after install/update** — run `/hooks` once to reload config, or
  restart the session.
- **Clean slate** — `~/.claude/skillspector-gate/ledger.json` is plain JSON; delete or hand-edit
  it, everything else resolves fresh from disk.

## License

Apache-2.0 for this project's own code — see [`LICENSE`](LICENSE). One vendored third-party
file (`skills/skill-inspector/SKILL.md`, from NVIDIA's SkillSpector, also Apache-2.0) is
documented in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). This project is not
affiliated with or endorsed by NVIDIA.

## Credits

Built on [NVIDIA/skillspector](https://github.com/NVIDIA/skillspector), part of the NVIDIA
Verified Skills pipeline.
