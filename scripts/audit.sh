#!/usr/bin/env bash
# Audit loop: feed every live, gate-controlled invocable through
# gate-skill.sh exactly as the PreToolUse hook would, and report the
# decision for each. Walks live resolvers, not ledger keys, so stale
# ledger entries for deleted skills do not count and new skills do.
#
#   - every ~/.claude/skills/<name>/SKILL.md (synced/ excluded)
#   - for every plugin in installed_plugins.json:
#       each skills/<name>/  -> Skill  "<plugin>:<name>"
#       each commands/<name>.md -> Skill  "<plugin>:<name>"
#       each agents/<name>.md   -> Agent  "<plugin>:<name>"
#
# A deny caused by a recorded REJECT verdict is the gate doing what it was
# told, so it is counted as "rejected", not as a failure.
#
# Usage: audit.sh [--quiet]   (exit 1 if anything is denied for any other reason)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/gate-skill.sh"
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

installed="$HOME/.claude/plugins/installed_plugins.json"
if [ -f "$installed" ]; then
  while IFS=$'\x1f' read -r plugin root; do
    [ -d "$root" ] || continue
    for d in "$root"/skills/*/; do
      [ -f "$d/SKILL.md" ] && run Skill "$plugin:$(basename "$d")"
    done
    for f in "$root"/commands/*.md; do
      [ -f "$f" ] && run Skill "$plugin:$(basename "$f" .md)"
    done
    for f in "$root"/agents/*.md; do
      [ -f "$f" ] && run Agent "$plugin:$(basename "$f" .md)"
    done
  done < <(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
for key, entries in d.get('plugins', {}).items():
    if entries:
        print(key.split('@', 1)[0] + '\x1f' + entries[0].get('installPath', ''))
" "$installed")
fi

echo "audit: $allow allowed, $rejected rejected by verdict, $deny denied"
[ "$deny" -eq 0 ]
