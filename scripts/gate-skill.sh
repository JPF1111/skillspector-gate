#!/usr/bin/env bash
# PreToolUse hook for the Skill tool. Blocks any skill invocation whose
# resolved directory is not in the approval ledger with a matching
# content hash and a verdict of APPROVE or CAUTION.
#
# A skill name that does not resolve to a local, file-backed directory
# (Claude Code's own bundled/built-in skills, or claude.ai-synced skills)
# is allowed through unmodified — there is nothing on disk here to scan
# or approve. See the README for the full scope rationale.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$SCRIPT_DIR/resolve-skill.sh"
HASH="$SCRIPT_DIR/hash-skill.sh"

DATA_DIR="${SKILLSPECTOR_GATE_HOME:-$HOME/.claude/skillspector-gate}"
LEDGER="$DATA_DIR/ledger.json"
APPROVE_PY="$SCRIPT_DIR/approve.py"

input=$(cat)

skill_name=$(printf '%s' "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('skill',''))" 2>/dev/null)
cwd=$(printf '%s' "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null)

allow() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
  exit 0
}

deny() {
  local reason="$1"
  python3 -c "
import json, sys
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': sys.argv[1],
    }
}))
" "$reason"
  exit 0
}

[ -z "$skill_name" ] && allow

resolved_dir=$("$RESOLVE" "$skill_name" "$cwd" 2>/dev/null)
resolve_status=$?

# Not a locally-installed, file-backed skill (bundled/built-in/synced) — nothing to gate.
[ $resolve_status -ne 0 ] && allow
[ -z "$resolved_dir" ] && allow

current_hash=$("$HASH" "$resolved_dir" 2>/dev/null)
if [ -z "$current_hash" ]; then
  deny "skillspector-gate: could not hash skill directory $resolved_dir — blocked fail-closed."
fi

[ -f "$LEDGER" ] || deny "skillspector-gate: '$skill_name' has never been scanned (no ledger yet). Review it with the skill-inspector skill, then: python3 $APPROVE_PY '$resolved_dir' --verdict APPROVE --note '...'"

ledger_result=$(LEDGER_PATH="$LEDGER" RESOLVED_DIR="$resolved_dir" CURRENT_HASH="$current_hash" python3 -c "
import json, os
try:
    with open(os.environ['LEDGER_PATH']) as f:
        ledger = json.load(f)
except Exception:
    print('MISSING')
    raise SystemExit
entry = ledger.get(os.environ['RESOLVED_DIR'])
if entry is None:
    print('MISSING')
elif entry.get('hash') != os.environ['CURRENT_HASH']:
    print('STALE:' + entry.get('verdict', '?'))
elif entry.get('verdict') == 'REJECT':
    print('REJECTED')
elif entry.get('verdict') in ('APPROVE', 'CAUTION'):
    print('OK:' + entry.get('verdict'))
else:
    print('MISSING')
")

case "$ledger_result" in
  OK:*)
    allow
    ;;
  MISSING)
    deny "skillspector-gate: '$skill_name' ($resolved_dir) has never been scanned/approved. Review it with the skill-inspector skill, then: python3 $APPROVE_PY '$resolved_dir' --verdict APPROVE --note '...'"
    ;;
  STALE:*)
    deny "skillspector-gate: '$skill_name' ($resolved_dir) changed since its last scan (content hash mismatch) — its prior verdict no longer applies. Re-review and re-approve before use."
    ;;
  REJECTED)
    deny "skillspector-gate: '$skill_name' ($resolved_dir) was scanned and REJECTED. It will not run unless re-reviewed and re-approved."
    ;;
  *)
    deny "skillspector-gate: could not evaluate '$skill_name' ($resolved_dir) — blocked fail-closed."
    ;;
esac
