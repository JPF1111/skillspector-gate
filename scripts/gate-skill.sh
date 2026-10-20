#!/usr/bin/env bash
# PreToolUse hook for the Skill and Agent tools. Blocks any invocation
# whose on-disk content is not in the approval ledger with a matching
# content hash and a verdict of APPROVE or CAUTION.
#
# Skill tool:
#   - a global/project skill: its directory must be approved.
#   - a "<plugin>:<skill>" from an installed plugin: the skill directory
#     AND the plugin's shell entry (everything outside skills/: agents,
#     commands, scripts, hooks, rules, mcp.json ... — see
#     hash-skill.sh --shell) must both be approved.
#   - a "<plugin>:<command>" (commands/<command>.md): the shell entry.
# Agent tool:
#   - a "<plugin>:<agent>" (agents/<agent>.md): the shell entry.
#   - any other subagent type (built-in, user, project) is not gated.
#
# A shell entry may carry member_verdicts {"<member>": "REJECT"} to block
# one skill/command/agent of an otherwise approved plugin.
#
# A name that does not resolve to anything on disk this gate controls
# (Claude Code's own bundled/built-in skills, claude.ai-synced skills
# and plugins) is allowed through unmodified. An installed plugin whose
# named member cannot be found is denied fail-closed. See the README for
# the full scope rationale.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$SCRIPT_DIR/resolve-skill.sh"
HASH="$SCRIPT_DIR/hash-skill.sh"

# Ledger location: $SKILLSPECTOR_GATE_HOME if set; else next to these
# scripts when a ledger already lives there (a standalone install under
# ~/.claude/skillspector); else ~/.claude/skillspector-gate.
if [ -n "${SKILLSPECTOR_GATE_HOME:-}" ]; then
  DATA_DIR="$SKILLSPECTOR_GATE_HOME"
elif [ -f "$SCRIPT_DIR/ledger.json" ]; then
  DATA_DIR="$SCRIPT_DIR"
else
  DATA_DIR="$HOME/.claude/skillspector-gate"
fi
LEDGER="$DATA_DIR/ledger.json"
APPROVE_PY="$SCRIPT_DIR/approve.py"

input=$(cat)

fields=$(printf '%s' "$input" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ti = d.get('tool_input') or {}
vals = [d.get('tool_name', ''), ti.get('skill', ''), ti.get('subagent_type', ''), d.get('cwd', '')]
# \x1f, not tab: tab is IFS whitespace, so an empty field would collapse and shift the rest.
print('\x1f'.join(str(v or '').replace('\x1f', ' ').replace('\n', ' ') for v in vals))
" 2>/dev/null)
IFS=$'\x1f' read -r tool_name skill_arg agent_arg cwd <<< "$fields"

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

case "$tool_name" in
  Skill) kind=skill; name="$skill_arg" ;;
  Agent|Task) kind=agent; name="$agent_arg" ;;
  *) allow ;;
esac

[ -z "$name" ] && allow

# require_ok <dir> <skill|shell> <label> [member]
# Returns only if <dir>'s ledger entry is APPROVE/CAUTION with a matching
# hash (and, for a shell, <member> is not individually REJECTed); denies
# otherwise.
require_ok() {
  local dir="$1" mode="$2" label="$3" member="${4:-}"
  local hash approve_cmd result
  if [ "$mode" = shell ]; then
    hash=$("$HASH" --shell "$dir" 2>/dev/null)
    approve_cmd="python3 $APPROVE_PY --shell '$dir' --verdict APPROVE --note '...'"
  else
    hash=$("$HASH" "$dir" 2>/dev/null)
    approve_cmd="python3 $APPROVE_PY '$dir' --verdict APPROVE --note '...'"
  fi
  [ -n "$hash" ] || deny "skillspector-gate: could not hash $label ($dir) — blocked fail-closed."
  [ -f "$LEDGER" ] || deny "skillspector-gate: $label ($dir) has never been scanned (no ledger yet). Review it with the skill-inspector skill, then: $approve_cmd"

  result=$(LEDGER_PATH="$LEDGER" DIR="$dir" CURRENT_HASH="$hash" MODE="$mode" MEMBER="$member" python3 -c "
import json, os
try:
    with open(os.environ['LEDGER_PATH']) as f:
        ledger = json.load(f)
except Exception:
    print('MISSING')
    raise SystemExit
entry = ledger.get(os.environ['DIR'])
shell = os.environ['MODE'] == 'shell'
if entry is None or (entry.get('kind') == 'plugin-shell') != shell:
    print('MISSING')
elif entry.get('hash') != os.environ['CURRENT_HASH']:
    print('STALE')
elif entry.get('verdict') == 'REJECT':
    print('REJECTED')
elif shell and (entry.get('member_verdicts') or {}).get(os.environ['MEMBER']) == 'REJECT':
    print('MEMBER_REJECTED')
elif entry.get('verdict') in ('APPROVE', 'CAUTION'):
    print('OK')
else:
    print('MISSING')
")

  case "$result" in
    OK) return 0 ;;
    MISSING)
      deny "skillspector-gate: $label ($dir) has never been scanned/approved. Review it with the skill-inspector skill, then: $approve_cmd" ;;
    STALE)
      deny "skillspector-gate: $label ($dir) changed since its last scan (content hash mismatch) — its prior verdict no longer applies. Re-review and re-approve before use: $approve_cmd" ;;
    REJECTED)
      deny "skillspector-gate: $label ($dir) was scanned and REJECTED. It will not run unless re-reviewed and re-approved." ;;
    MEMBER_REJECTED)
      deny "skillspector-gate: '$member' is individually REJECTED in the shell entry of $label ($dir). It will not run unless re-reviewed and its member_verdicts entry removed." ;;
    *)
      deny "skillspector-gate: could not evaluate $label ($dir) — blocked fail-closed." ;;
  esac
}

# Plugin-qualified name from an installed plugin.
if [[ "$name" == *:* ]] && plugin_root=$("$RESOLVE" --plugin-root "$name" 2>/dev/null) && [ -n "$plugin_root" ]; then
  plugin="${name%%:*}"
  member="${name#*:}"
  if ! [[ "$member" =~ ^[A-Za-z0-9_][A-Za-z0-9._:-]*$ ]] || [[ "$member" == *..* ]]; then
    deny "skillspector-gate: '$name' is not a valid plugin member name — blocked fail-closed."
  fi
  member_path="${member//://}"

  require_ok "$plugin_root" shell "plugin '$plugin' shell" "$member"

  if [ "$kind" = agent ]; then
    agent_file=$(find "$plugin_root" -maxdepth 3 -path "$plugin_root/skills" -prune \
      -o -type f -path "*/agents/$member_path.md" -print 2>/dev/null | head -1)
    [ -n "$agent_file" ] || deny "skillspector-gate: agent '$name' was not found under installed plugin $plugin_root — blocked fail-closed."
    allow
  fi

  if resolved_dir=$("$RESOLVE" "$name" "$cwd" 2>/dev/null) && [ -n "$resolved_dir" ]; then
    require_ok "$resolved_dir" skill "'$name'"
    allow
  fi

  command_file=$(find "$plugin_root" -maxdepth 3 -path "$plugin_root/skills" -prune \
    -o -type f -path "*/commands/$member_path.md" -print 2>/dev/null | head -1)
  [ -n "$command_file" ] && allow

  deny "skillspector-gate: '$name' is in installed plugin $plugin_root but no skill or command of that name was found there — blocked fail-closed."
fi

# Non-plugin subagent types (built-in, user, project) are out of scope.
[ "$kind" = agent ] && allow

resolved_dir=$("$RESOLVE" "$name" "$cwd" 2>/dev/null)
resolve_status=$?

# Not a locally-installed, file-backed skill (bundled/built-in/synced) — nothing to gate.
[ $resolve_status -ne 0 ] && allow
[ -z "$resolved_dir" ] && allow

require_ok "$resolved_dir" skill "'$name'"
allow
