#!/usr/bin/env bash
# Regression test: plugin content outside skills/ (agents, commands, scripts)
# is hashed into a "plugin shell" ledger entry, and the gate checks it for
# plugin skills (Skill tool), plugin commands (Skill tool) and plugin agents
# (Agent tool). Runs against a throwaway HOME; touches nothing real.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="$here/../scripts"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export SKILLSPECTOR_GATE_HOME="$tmp/data"
mkdir -p "$HOME/.claude/plugins" "$SKILLSPECTOR_GATE_HOME"
HOME="$(cd "$HOME" && pwd -P)"   # macOS: /var -> /private/var, match resolve-skill.sh's readlink -f
export HOME

plug="$HOME/.claude/plugins/cache/mkt/demo/1.0.0"
mkdir -p "$plug/skills/alpha" "$plug/agents" "$plug/commands" "$plug/scripts" "$plug/.in_use"
printf 'alpha\n'  > "$plug/skills/alpha/SKILL.md"
printf 'writer\n' > "$plug/agents/writer.md"
printf 'reader\n' > "$plug/agents/reader.md"
printf 'cmd\n'    > "$plug/commands/go.md"
printf 'print(1)\n' > "$plug/scripts/validate.py"
printf '{"pid":1}\n' > "$plug/.in_use/1"
cat > "$HOME/.claude/plugins/installed_plugins.json" <<EOF
{"plugins": {"demo@mkt": [{"installPath": "$plug"}]}}
EOF

pass=0; fail=0
check() {  # check <expected allow|deny> <description> <hook-input-json>
  local want="$1" desc="$2" got
  got=$(printf '%s' "$3" | bash "$scripts/gate-skill.sh" | python3 -c "import json,sys; print(json.load(sys.stdin)['hookSpecificOutput']['permissionDecision'])")
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "ok   $desc"
  else fail=$((fail+1)); echo "FAIL $desc (want $want, got $got)"; fi
}
skill() { printf '{"tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"%s"}' "$1" "$tmp"; }
agent() { printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s","prompt":"x"},"cwd":"%s"}' "$1" "$tmp"; }
approve() { python3 "$scripts/approve.py" "$@" --skip-scan --note test >/dev/null; }

# Shell hash excludes skills/ and .in_use/, includes everything else.
h0=$(bash "$scripts/hash-skill.sh" --shell "$plug")
printf '{"pid":2}\n' > "$plug/.in_use/2"
printf 'alpha edited\n' > "$plug/skills/alpha/SKILL.md"
[ "$(bash "$scripts/hash-skill.sh" --shell "$plug")" = "$h0" ] \
  && { pass=$((pass+1)); echo "ok   shell hash ignores skills/ and .in_use/"; } \
  || { fail=$((fail+1)); echo "FAIL shell hash moved on skills/ or .in_use/ change"; }
printf 'alpha\n' > "$plug/skills/alpha/SKILL.md"
[ "$(bash "$scripts/hash-skill.sh" "$plug/skills/alpha")" != "$(bash "$scripts/hash-skill.sh" --shell "$plug")" ] \
  && { pass=$((pass+1)); echo "ok   skill and shell hashes differ"; } \
  || { fail=$((fail+1)); echo "FAIL skill and shell hashes collide"; }

# Skill approved, shell not: everything plugin-side is denied.
approve "$plug/skills/alpha" --verdict APPROVE
check deny  "plugin skill denied while shell unapproved"   "$(skill demo:alpha)"
check deny  "plugin agent denied while shell unapproved"   "$(agent demo:writer)"
check deny  "plugin command denied while shell unapproved" "$(skill demo:go)"

# A skill-mode entry on the install dir does not count as a shell approval.
approve "$plug" --verdict APPROVE
check deny  "skill-mode entry on install dir is not a shell approval" "$(agent demo:writer)"

# Approve the shell, rejecting one agent.
approve --shell "$plug" --verdict CAUTION --member-verdict writer=REJECT
check allow "plugin skill allowed (skill + shell approved)" "$(skill demo:alpha)"
check allow "plugin command allowed (shell approved)"       "$(skill demo:go)"
check allow "plugin agent allowed (shell approved)"         "$(agent demo:reader)"
check deny  "member_verdicts REJECT blocks one agent"       "$(agent demo:writer)"
check deny  "unknown member of installed plugin denied"     "$(skill demo:nope)"
check deny  "unknown agent of installed plugin denied"      "$(agent demo:nope)"
check deny  "glob in member name denied"                    "$(agent 'demo:*')"
check deny  "path traversal in member name denied"          "$(skill demo:..)"

# Per-session lock files do not invalidate the shell.
printf '{"pid":3}\n' > "$plug/.in_use/3"
check allow ".in_use churn keeps shell valid" "$(agent demo:reader)"

# Gap (b): a plugin-level script changes -> shell stale -> skill and agent denied.
printf 'print(2)\n' > "$plug/scripts/validate.py"
check deny  "edited plugin script denies plugin skill" "$(skill demo:alpha)"
check deny  "edited plugin script denies plugin agent" "$(agent demo:reader)"
approve --shell "$plug" --verdict APPROVE
# Gap (a): an agent file changes -> shell stale.
printf 'reader edited\n' > "$plug/agents/reader.md"
check deny  "edited agent file denies that agent" "$(agent demo:reader)"
approve --shell "$plug" --verdict APPROVE
check allow "re-approved shell allows again"      "$(agent demo:reader)"

# Shell REJECT blocks everything in the plugin.
approve --shell "$plug" --verdict REJECT
check deny  "shell REJECT blocks plugin skill" "$(skill demo:alpha)"
approve --shell "$plug" --verdict APPROVE

# Out of scope stays allowed.
check allow "built-in agent type not gated"          "$(agent Explore)"
check allow "plugin not installed (synced) not gated" "$(skill other:thing)"
check allow "bundled skill name not gated"           "$(skill update-config)"
check allow "other tools pass through"               '{"tool_name":"Read","tool_input":{"file_path":"/x"},"cwd":"/"}'

# Global skills still use the per-skill path only.
mkdir -p "$HOME/.claude/skills/solo"
printf 'solo\n' > "$HOME/.claude/skills/solo/SKILL.md"
check deny  "unapproved global skill denied" "$(skill solo)"
approve "$HOME/.claude/skills/solo" --verdict APPROVE
check allow "approved global skill allowed"  "$(skill solo)"

# --- Adversarial-review regressions (PR 17 review, 2026-11-10) ---
approve --shell "$plug" --verdict APPROVE
check allow "baseline before adversarial cases" "$(agent demo:reader)"

# 1. Symlinks are hashed: an inside link's text is part of the hash...
ln -s validate.py "$plug/scripts/link.py"
check deny  "new inside symlink makes shell stale" "$(agent demo:reader)"
approve --shell "$plug" --verdict APPROVE
ln -sfn ../agents/reader.md "$plug/scripts/link.py"
check deny  "retargeted symlink makes shell stale" "$(agent demo:reader)"
rm "$plug/scripts/link.py"
approve --shell "$plug" --verdict APPROVE
# ...and a link pointing outside the plugin cannot be hashed: fail closed.
printf 'outside\n' > "$tmp/outside.sh"
ln -s "$tmp/outside.sh" "$plug/scripts/run.sh"
check deny  "symlink pointing outside the plugin denied" "$(agent demo:reader)"
bash "$scripts/hash-skill.sh" --shell "$plug" >/dev/null 2>&1 \
  && { fail=$((fail+1)); echo "FAIL hash-skill.sh hashed an outward symlink"; } \
  || { pass=$((pass+1)); echo "ok   hash-skill.sh refuses an outward symlink"; }
rm "$plug/scripts/run.sh"

# 2. Loose files under skills/ (outside any skill dir) are in the shell hash.
printf 'helper\n' > "$plug/skills/helper.sh"
check deny  "new loose file under skills/ makes shell stale" "$(agent demo:reader)"
approve --shell "$plug" --verdict APPROVE
printf 'helper edited\n' > "$plug/skills/helper.sh"
check deny  "edited loose file under skills/ makes shell stale" "$(agent demo:reader)"
approve --shell "$plug" --verdict APPROVE

# 3. Only .in_use/<pid> lock files are skipped; other .in_use content is hashed.
printf 'echo pwned\n' > "$plug/.in_use/payload.sh"
check deny  "non-lock file under .in_use/ makes shell stale" "$(agent demo:reader)"
rm "$plug/.in_use/payload.sh"
check allow "removing it restores the approved shell" "$(agent demo:reader)"

# 4. A plugin name under two marketplaces: every install dir is checked.
plug2="$HOME/.claude/plugins/cache/other/demo/9.9.9"
mkdir -p "$plug2/agents"
printf 'impostor\n' > "$plug2/agents/reader.md"
cp "$HOME/.claude/plugins/installed_plugins.json" "$tmp/installed.bak"
cat > "$HOME/.claude/plugins/installed_plugins.json" <<EOF
{"plugins": {"demo@mkt": [{"installPath": "$plug"}], "demo@other": [{"installPath": "$plug2"}]}}
EOF
check deny  "second unapproved install of the same plugin name denied" "$(agent demo:reader)"
cat > "$HOME/.claude/plugins/installed_plugins.json" <<EOF
{"plugins": {"demo@mkt": [{"installPath": "$plug"}, {"installPath": "$tmp/gone"}]}}
EOF
check deny  "listed plugin with a missing install dir denied" "$(agent demo:reader)"
check deny  "listed plugin with a missing install dir denies skills too" "$(skill demo:alpha)"
cp "$tmp/installed.bak" "$HOME/.claude/plugins/installed_plugins.json"

# 5. A ledger shipped next to the scripts is ignored.
mkdir -p "$tmp/scripts-copy"
cp "$scripts"/*.sh "$scripts"/approve.py "$tmp/scripts-copy/"
# A copy of the real, approving ledger: if the gate read it, demo:alpha would be allowed.
cp "$SKILLSPECTOR_GATE_HOME/ledger.json" "$tmp/scripts-copy/ledger.json"
check allow "control: the real ledger allows demo:alpha" "$(skill demo:alpha)"
got=$(env -u SKILLSPECTOR_GATE_HOME bash -c 'printf "%s" "$1" | bash "$2"' _ "$(skill demo:alpha)" "$tmp/scripts-copy/gate-skill.sh" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['hookSpecificOutput']['permissionDecision'])")
[ "$got" = deny ] && { pass=$((pass+1)); echo "ok   ledger next to the scripts is ignored"; } \
  || { fail=$((fail+1)); echo "FAIL ledger next to the scripts was used"; }

# 7. Unparseable input is denied.
check deny  "non-JSON hook input denied" 'not json'
check deny  "tool_input as a list denied" '{"tool_name":"Skill","tool_input":["x"],"cwd":"/"}'

# 9. An agent named by frontmatter name: (file name differs) is found.
printf -- '---\nname: scout-two\n---\nbody\n' > "$plug/agents/scout_2.md"
approve --shell "$plug" --verdict APPROVE
check allow "agent found by frontmatter name" "$(agent demo:scout-two)"
check deny  "frontmatter match is exact, not a regex" "$(agent demo:scout.two)"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
