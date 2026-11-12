#!/usr/bin/env bash
# PreToolUse hook for the Skill and Agent tools. Blocks any invocation
# whose on-disk content is not in the approval ledger with a matching
# content hash and a verdict of APPROVE or CAUTION.
#
# Skill tool:
#   - a global/project skill: its directory must be approved.
#   - a "<plugin>:<skill>" from an installed plugin: the skill directory
#     AND the plugin's shell entry (everything outside its skill dirs:
#     agents, commands, scripts, hooks, rules, mcp.json, loose files under
#     skills/ ... — see hash-skill.sh --shell) must both be approved. A
#     plugin name listed under several marketplaces or scopes is checked at
#     every install dir it maps to.
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
# named member cannot be found, a listed plugin whose install dir is
# missing, and hook input that cannot be parsed are denied fail-closed.
#
# Not covered: this hook fires only on Skill/Agent/Task. A plugin's own
# hooks and MCP servers run on their own events and are never stopped
# here, even though their files are in the shell hash. See the README for
# the full scope rationale.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$SCRIPT_DIR/resolve-skill.sh"
HASH="$SCRIPT_DIR/hash-skill.sh"

# Ledger location, home paths only (never the scripts' own install dir, so
# a release or fork cannot ship a ledger that replaces yours):
# $SKILLSPECTOR_GATE_HOME if set; else ~/.claude/skillspector-gate if it
# holds a ledger; else the standalone install ~/.claude/skillspector if it
# holds one; else ~/.claude/skillspector-gate.
if [ -n "${SKILLSPECTOR_GATE_HOME:-}" ]; then
  DATA_DIR="$SKILLSPECTOR_GATE_HOME"
elif [ -f "$HOME/.claude/skillspector-gate/ledger.json" ]; then
  DATA_DIR="$HOME/.claude/skillspector-gate"
elif [ -f "$HOME/.claude/skillspector/ledger.json" ]; then
  DATA_DIR="$HOME/.claude/skillspector"
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
if not isinstance(d, dict) or not isinstance(ti, dict):
    sys.exit(1)
vals = [d.get('tool_name', ''), ti.get('skill', ''), ti.get('subagent_type', ''), d.get('cwd', '')]
# \x1f, not tab: tab is IFS whitespace, so an empty field would collapse and shift the rest.
print('\x1f'.join(str(v or '').replace('\x1f', ' ').replace('\n', ' ') for v in vals))
" 2>/dev/null)
parse_status=$?
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

# This hook is registered only for Skill|Agent|Task: input it cannot read
# is denied, not waved through.
[ "$parse_status" -eq 0 ] && [ -n "$fields" ] \
  || deny "skillspector-gate: could not parse the hook input — blocked fail-closed."

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

# Plugin-qualified name. resolve-skill.sh --plugin-root: 0 = installed (one
# install dir per line), 1 = not an installed plugin, 2 = listed but broken.
if [[ "$name" == *:* ]]; then
  plugin_roots=$("$RESOLVE" --plugin-root "$name" 2>/dev/null)
  roots_status=$?
  [ "$roots_status" -eq 2 ] && deny "skillspector-gate: plugin '${name%%:*}' is listed in installed_plugins.json but an install dir is missing or unreadable — blocked fail-closed."
fi
if [[ "$name" == *:* ]] && [ "${roots_status:-1}" -eq 0 ] && [ -n "$plugin_roots" ]; then
  plugin="${name%%:*}"
  member="${name#*:}"
  if ! [[ "$member" =~ ^[A-Za-z0-9_][A-Za-z0-9._:-]*$ ]] || [[ "$member" == *..* ]]; then
    deny "skillspector-gate: '$name' is not a valid plugin member name — blocked fail-closed."
  fi
  member_path="${member//://}"
  member_base="${member##*:}"

  while IFS= read -r plugin_root; do
    [ -n "$plugin_root" ] || continue
    require_ok "$plugin_root" shell "plugin '$plugin' shell" "$member"

    if [ "$kind" = agent ]; then
      agent_file=$(find "$plugin_root" -maxdepth 3 -path "$plugin_root/skills" -prune \
        -o -type f -path "*/agents/$member_path.md" -print 2>/dev/null | head -1)
      if [ -z "$agent_file" ]; then
        # Claude Code may name an agent by its frontmatter name: rather than its file.
        agent_file=$(find "$plugin_root" -maxdepth 3 -path "$plugin_root/skills" -prune \
          -o -type f -path "*/agents/*.md" -print 2>/dev/null \
          | while IFS= read -r f; do
              awk -v m="$member_base" '/^name:/ { sub(/^name:[ \t]*/, ""); gsub(/["\047]/, ""); sub(/[ \t]+$/, ""); found = ($0 == m); exit } END { exit !found }' "$f" 2>/dev/null && { echo "$f"; break; }
            done)
      fi
      [ -n "$agent_file" ] || deny "skillspector-gate: agent '$name' was not found under installed plugin $plugin_root — blocked fail-closed."
      continue
    fi

    skill_dir=""
    if [ -d "$plugin_root/skills/$member_path" ] && [ -f "$plugin_root/skills/$member_path/SKILL.md" ]; then
      skill_dir="$plugin_root/skills/$member_path"
    else
      skill_dir=$(find "$plugin_root" -maxdepth 4 -type d -name "$member_base" -exec test -f "{}/SKILL.md" \; -print 2>/dev/null | head -1)
    fi
    if [ -n "$skill_dir" ]; then
      require_ok "$(readlink -f "$skill_dir")" skill "'$name'"
      continue
    fi

    command_file=$(find "$plugin_root" -maxdepth 3 -path "$plugin_root/skills" -prune \
      -o -type f -path "*/commands/$member_path.md" -print 2>/dev/null | head -1)
    [ -n "$command_file" ] && continue

    deny "skillspector-gate: '$name' is in installed plugin $plugin_root but no skill or command of that name was found there — blocked fail-closed."
  done <<< "$plugin_roots"
  allow
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
