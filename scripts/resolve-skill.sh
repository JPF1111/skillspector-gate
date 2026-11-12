#!/usr/bin/env bash
# Resolve a Claude Code Skill-tool `skill` argument to its real on-disk
# directory. Prints the resolved absolute path (symlinks followed) on
# stdout and exits 0, or exits 1 with nothing on stdout if the skill
# does not correspond to a file-backed skill this gate controls (e.g.
# a Claude Code bundled/built-in skill, or one synced into
# ~/.claude/skills/synced/; see the README).
#
# Usage: resolve-skill.sh <skill-name> <cwd>
#        resolve-skill.sh --plugin-root <plugin>:<member>
#
# A "<plugin>:<skill>" name is looked up in every root plugin-index.py
# gives for <plugin>: installed (installed_plugins.json, all marketplaces
# and scopes) and claude.ai-synced (~/.claude/plugins/synced/, the live
# generation). The first root holding the skill wins here; the gate itself
# checks every root.
#
# --plugin-root prints every distinct real root of the plugin, one per
# line (installed first, then synced). Exit codes:
#   0  found, all listed install dirs present
#   1  not an installed or synced plugin (the gate leaves it alone)
#   2  listed in installed_plugins.json but an install dir is missing or
#      the file is unreadable (the gate denies: fail closed)
set -uo pipefail

plugin_root_only=0
if [ "${1:-}" = "--plugin-root" ]; then
  plugin_root_only=1
  shift
fi

name="${1:-}"
cwd="${2:-$PWD}"

[ -z "$name" ] && exit 1

resolve_real() {
  readlink -f "$1" 2>/dev/null
}

# Plugin-qualified form: "<plugin>:<skill>", installed or claude.ai-synced.
if [[ "$name" == *:* ]]; then
  plugin="${name%%:*}"
  skill="${name#*:}"
  index="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plugin-index.py"

  if [ "$plugin_root_only" -eq 1 ]; then
    python3 "$index" roots "$plugin"
    exit $?
  fi

  roots=$(python3 "$index" roots "$plugin" 2>/dev/null) || exit 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    python3 "$index" find "$root" "$skill" skill 2>/dev/null && exit 0
  done <<< "$roots"
  exit 1
fi

[ "$plugin_root_only" -eq 1 ] && exit 1

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

# Not a file-backed skill this gate controls (likely a Claude Code
# bundled/built-in skill, or one under ~/.claude/skills/synced/).
exit 1
