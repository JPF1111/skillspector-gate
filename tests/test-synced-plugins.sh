#!/usr/bin/env bash
# Regression test: claude.ai-synced plugins (~/.claude/plugins/synced/<account>/)
# are gated like installed ones. The live directory is the generation the
# account manifest names; a stale older generation is ignored; plugin.json
# "commands" pointing elsewhere is honoured; a name that is both installed and
# synced needs both roots approved. Runs against a throwaway HOME.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="$here/../scripts"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export SKILLSPECTOR_GATE_HOME="$tmp/data"
mkdir -p "$HOME/.claude/plugins" "$SKILLSPECTOR_GATE_HOME"
HOME="$(cd "$HOME" && pwd -P)"
export HOME

acct="$HOME/.claude/plugins/synced/acct-1"
mk_plugin() {  # mk_plugin <dir> <plugin name> [plugin.json extra]
  mkdir -p "$1/.claude-plugin" "$1/skills/alpha" "$1/agents" "$1/flows" "$1/.in_use"
  printf '{"name": "%s"%s}\n' "$2" "${3:-}" > "$1/.claude-plugin/plugin.json"
  printf 'alpha\n'  > "$1/skills/alpha/SKILL.md"
  printf 'helper\n' > "$1/agents/helper.md"
  printf 'flow\n'   > "$1/flows/go-flow.md"
}
# Generation 2 is live; the generation-1 copy is stale but identical.
mk_plugin "$acct/uuid-a~g2" synco ', "commands": "./flows/"'
mk_plugin "$acct/uuid-a"    synco ', "commands": "./flows/"'
# A plain (generation 1) synced plugin.
mk_plugin "$acct/plain" plainy
# A synced plugin that shares its name with an installed one.
mk_plugin "$acct/uuid-dup" dual
inst="$HOME/.claude/plugins/cache/mkt/dual/1.0.0"
mk_plugin "$inst" dual
printf 'beta\n' > "$inst/skills/alpha/SKILL.md"   # different content from the synced copy
cat > "$acct/manifest.json" <<'EOF'
{"plugins": [
  {"name": "uuid-a", "generation": 2},
  {"name": "plain"},
  {"name": "uuid-dup"},
  {"name": "missing-dir", "generation": 3}
]}
EOF
cat > "$HOME/.claude/plugins/installed_plugins.json" <<EOF
{"plugins": {"dual@mkt": [{"installPath": "$inst"}]}}
EOF

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
check() {  # check <expected allow|deny> <description> <hook-input-json>
  local want="$1" desc="$2" got
  got=$(printf '%s' "$3" | bash "$scripts/gate-skill.sh" | python3 -c "import json,sys; print(json.load(sys.stdin)['hookSpecificOutput']['permissionDecision'])")
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc (want $want, got $got)"; fi
}
skill() { printf '{"tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"%s"}' "$1" "$tmp"; }
agent() { printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s","prompt":"x"},"cwd":"%s"}' "$1" "$tmp"; }
approve() { python3 "$scripts/approve.py" "$@" --skip-scan --note test >/dev/null; }
idx() { python3 "$scripts/plugin-index.py" "$@"; }

# Index: live generation only, plugin.json names, missing dirs skipped.
[ "$(idx roots synco)" = "$acct/uuid-a~g2" ] && ok "synced root is the manifest's generation" || bad "synced root: $(idx roots synco)"
[ "$(idx roots dual | wc -l | tr -d ' ')" = 2 ] && ok "installed+synced name has two roots" || bad "dual roots: $(idx roots dual)"
[ "$(idx roots dual | head -1)" = "$inst" ] && ok "installed root listed first" || bad "dual order"
idx roots uuid-a >/dev/null && bad "manifest uuid is not a plugin name" || ok "manifest uuid is not a plugin name"
[ "$(idx find "$acct/uuid-a~g2" go-flow command)" = "$acct/uuid-a~g2/flows/go-flow.md" ] && ok "plugin.json commands dir honoured" || bad "commands dir"
[ "$(bash "$scripts/resolve-skill.sh" --plugin-root synco:alpha)" = "$acct/uuid-a~g2" ] && ok "resolve --plugin-root finds synced root" || bad "resolve --plugin-root"
[ "$(bash "$scripts/resolve-skill.sh" synco:alpha "$tmp")" = "$acct/uuid-a~g2/skills/alpha" ] && ok "resolve finds synced skill" || bad "resolve synced skill"

# Nothing approved: every synced member is denied (was: allowed, unresolvable).
check deny  "unapproved synced skill denied"   "$(skill synco:alpha)"
check deny  "unapproved synced command denied" "$(skill synco:go-flow)"
check deny  "unapproved synced agent denied"   "$(agent synco:helper)"

# Skill + shell approved on the live generation.
approve "$acct/uuid-a~g2/skills/alpha" --verdict APPROVE
check deny  "synced skill denied while shell unapproved" "$(skill synco:alpha)"
approve --shell "$acct/uuid-a~g2" --verdict CAUTION --member-verdict helper=REJECT
check allow "synced skill allowed (skill + shell)"         "$(skill synco:alpha)"
check allow "synced flows/ command allowed (shell)"        "$(skill synco:go-flow)"
check deny  "synced agent REJECTed by member verdict"      "$(agent synco:helper)"
check deny  "unknown member of synced plugin denied"       "$(skill synco:nope)"

# Approving the stale generation does not help, and its edits do not matter.
approve --shell "$acct/uuid-a" --verdict APPROVE
printf 'stale edit\n' > "$acct/uuid-a/agents/helper.md"
check allow "stale generation edits ignored" "$(skill synco:alpha)"

# A re-sync that changes content invalidates the approval.
printf 'alpha v2\n' > "$acct/uuid-a~g2/skills/alpha/SKILL.md"
check deny  "re-synced skill content denied until re-approved" "$(skill synco:alpha)"
printf 'alpha\n' > "$acct/uuid-a~g2/skills/alpha/SKILL.md"
printf '{"pid":9,"procStart":"Wed Nov 11 01:49:15 2026"}' > "$acct/uuid-a~g2/.in_use/9"
check allow ".in_use churn does not invalidate the synced shell" "$(skill synco:alpha)"

# A generation bump moves the live directory: the old approval no longer applies.
mk_plugin "$acct/uuid-a~g3" synco ', "commands": "./flows/"'
sed -i.bak 's/"generation": 2/"generation": 3/' "$acct/manifest.json"
check deny  "generation bump denies until the new directory is approved" "$(skill synco:alpha)"
mv "$acct/manifest.json.bak" "$acct/manifest.json"

# Installed + synced under one name: both roots must be approved.
approve --shell "$inst" --verdict APPROVE
approve "$inst/skills/alpha" --verdict APPROVE
check deny  "dual name denied while synced root unapproved" "$(skill dual:alpha)"
approve --shell "$acct/uuid-dup" --verdict APPROVE
check deny  "dual name denied while synced skill unapproved" "$(skill dual:alpha)"
approve "$acct/uuid-dup/skills/alpha" --verdict APPROVE
check allow "dual name allowed once both roots approved"   "$(skill dual:alpha)"
approve --shell "$acct/uuid-dup" --verdict REJECT
check deny  "REJECT on the synced root blocks the dual name" "$(skill dual:alpha)"

# Out of scope stays allowed.
mkdir -p "$HOME/.claude/skills/synced/s1"
printf 's1\n' > "$HOME/.claude/skills/synced/s1/SKILL.md"
check allow "unknown plugin name not gated"   "$(skill nowhere:thing)"
check allow "built-in agent type not gated"   "$(agent Explore)"

# audit.sh walks synced plugins too, and counts the member REJECT as rejected.
printf -- '---\nname: "fm-agent"\n---\n' > "$acct/plain/agents/file-name.md"
approve --shell "$acct/plain" --verdict APPROVE
approve "$acct/plain/skills/alpha" --verdict APPROVE
check allow "synced agent found by frontmatter name" "$(agent plainy:fm-agent)"
check deny  "synced agent name not in any file denied" "$(agent plainy:ghost)"
out=$(bash "$scripts/audit.sh" --quiet 2>&1 || true)
echo "$out" | grep -q 'reject Agent  synco:helper' && ok "audit reports synced member REJECT" || bad "audit synco:helper: $out"
echo "$out" | grep -q 'reject Skill  dual:alpha' && ok "audit reports dual-name REJECT" || bad "audit dual: $out"
echo "$out" | grep -q 'plainy:go-flow' && bad "audit invented a command" || ok "audit lists only real members"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
