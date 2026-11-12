#!/usr/bin/env bash
# Audit loop: feed every live, gate-controlled invocable through
# gate-skill.sh exactly as the PreToolUse hook would, and report the
# decision for each. Walks live resolvers, not ledger keys, so stale
# ledger entries for deleted skills do not count and new skills do.
#
#   - every ~/.claude/skills/<name>/SKILL.md (synced/ excluded)
#   - for every root of every installed or claude.ai-synced plugin
#     (plugin-index.py list; plugin.json skills/commands/agents paths honoured):
#       each skill dir          -> Skill  "<plugin>:<name>"
#       each command .md        -> Skill  "<plugin>:<name>"
#       each agent .md          -> Agent  "<plugin>:<name>"
#
# A deny caused by a recorded REJECT verdict is the gate doing what it was
# told, so it is counted as "rejected", not as a failure.
#
# Usage: [AUDIT_GATE=<gate-skill.sh>] audit.sh [--quiet]   (exit 1 if anything is denied for any other reason)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# AUDIT_GATE runs the same walk through another gate script (e.g. the one
# installed before an upgrade), so before/after decisions can be compared.
GATE="${AUDIT_GATE:-$SCRIPT_DIR/gate-skill.sh}"
quiet=0; [ "${1:-}" = "--quiet" ] && quiet=1

allow=0; deny=0; rejected=0
run() {  # run <Skill|Agent> <name>
  local input decision reason
  if [ "$1" = Skill ]; then
    input=$(printf '{"tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"%s"}' "$2" "$HOME")
  else
    input=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s","prompt":"audit"},"cwd":"%s"}' "$2" "$HOME")
  fi
  read -r decision reason < <(printf '%s' "$input" | bash "$GATE" | python3 -c "
import json, sys
o = json.load(sys.stdin)['hookSpecificOutput']
print(o['permissionDecision'], o.get('permissionDecisionReason', ''))")
  if [ "$decision" = allow ]; then
    allow=$((allow+1)); [ "$quiet" -eq 1 ] || printf 'allow  %-6s %s\n' "$1" "$2"
  elif [[ "$reason" == *REJECTED* ]]; then
    rejected=$((rejected+1)); printf 'reject %-6s %s (recorded REJECT verdict)\n' "$1" "$2"
  else
    deny=$((deny+1)); printf 'DENY   %-6s %s — %s\n' "$1" "$2" "$reason"
  fi
}

for d in "$HOME"/.claude/skills/*/; do
  n=$(basename "$d")
  [ "$n" = synced ] && continue
  [ -f "$d/SKILL.md" ] || continue
  run Skill "$n"
done

# Every root of every installed or synced plugin. A skill and a command
# with the same name are one Skill call, and a name with several roots is
# one call that checks them all, so each tool:plugin:member runs once.
seen=$'\n'
index_out=$(python3 "$SCRIPT_DIR/plugin-index.py" list 2>"${TMPDIR:-/tmp}/audit-index.$$")
index_status=$?
if [ "$index_status" -ne 0 ]; then
  deny=$((deny+1))
  printf 'DENY   index  %s\n' "$(tr '\n' ' ' < "${TMPDIR:-/tmp}/audit-index.$$")"
fi
rm -f "${TMPDIR:-/tmp}/audit-index.$$"
while IFS=$'\t' read -r plugin root; do
  [ -d "$root" ] || continue
  while IFS=$'\t' read -r kind member; do
    [ -n "$member" ] || continue
    tool=Skill; [ "$kind" = agent ] && tool=Agent
    key="$tool:$plugin:$member"
    case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
    seen="$seen$key"$'\n'
    run "$tool" "$plugin:$member"
  done < <(python3 "$SCRIPT_DIR/plugin-index.py" members "$root")
done <<< "$index_out"

echo "audit: $allow allowed, $rejected rejected by verdict, $deny denied"
[ "$deny" -eq 0 ]
