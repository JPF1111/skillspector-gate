#!/usr/bin/env bash
# Resolve a Claude Code Skill-tool `skill` argument to its real on-disk
# directory. Prints the resolved absolute path (symlinks followed) on
# stdout and exits 0, or exits 1 with nothing on stdout if the skill
# does not correspond to a locally-installed, file-backed skill (e.g.
# a Claude Code bundled/built-in skill, or a claude.ai-synced skill —
# neither has a directory this gate controls; see the README).
#
# Usage: resolve-skill.sh <skill-name> <cwd>
set -uo pipefail

name="${1:-}"
cwd="${2:-$PWD}"

[ -z "$name" ] && exit 1

resolve_real() {
  readlink -f "$1" 2>/dev/null
}

# Plugin-qualified form: "<plugin>:<skill>"
if [[ "$name" == *:* ]]; then
  plugin="${name%%:*}"
  skill="${name#*:}"
  installed_json="$HOME/.claude/plugins/installed_plugins.json"
  [ -f "$installed_json" ] || exit 1

  install_path=$(INSTALLED_JSON="$installed_json" PLUGIN_NAME="$plugin" python3 -c "
import json, os, sys
try:
    with open(os.environ['INSTALLED_JSON']) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
plugins = data.get('plugins', {})
target = os.environ['PLUGIN_NAME']
for key, entries in plugins.items():
    if key.split('@', 1)[0] == target and entries:
        print(entries[0].get('installPath', ''))
        sys.exit(0)
sys.exit(1)
" 2>/dev/null)
  [ -z "$install_path" ] && exit 1

  candidate="$install_path/skills/$skill"
  if [ -d "$candidate" ]; then
    resolve_real "$candidate"
    exit 0
  fi

  # Fallback: search the plugin install path for a matching skill dir.
  found=$(find "$install_path" -maxdepth 4 -type d -name "$skill" -exec test -f "{}/SKILL.md" \; -print 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    resolve_real "$found"
    exit 0
  fi
  exit 1
fi

# Global skill.
if [ -d "$HOME/.claude/skills/$name" ] && [ -f "$HOME/.claude/skills/$name/SKILL.md" ]; then
  resolve_real "$HOME/.claude/skills/$name"
  exit 0
fi

# Project-level skill: walk up from cwd looking for .claude/skills/<name>.
dir="$cwd"
while [ -n "$dir" ]; do
  candidate="$dir/.claude/skills/$name"
  if [ -d "$candidate" ] && [ -f "$candidate/SKILL.md" ]; then
    resolve_real "$candidate"
    exit 0
  fi
  [ "$dir" = "/" ] && break
  dir=$(dirname "$dir")
done

# Not a locally-installed, file-backed skill (likely a Claude Code
# bundled/built-in skill, or a claude.ai-synced one) — nothing to resolve.
exit 1
