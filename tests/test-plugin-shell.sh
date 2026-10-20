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

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
