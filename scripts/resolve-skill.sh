#!/usr/bin/env bash
# Resolve a Claude Code Skill-tool `skill` argument to its real on-disk
# directory. Prints the resolved absolute path (symlinks followed) on
# stdout and exits 0, or exits 1 with nothing on stdout if the skill
# does not correspond to a locally-installed, file-backed skill (e.g.
# a Claude Code bundled/built-in skill, or a claude.ai-synced skill —
# neither has a directory this gate controls; see the README).
#
# Usage: resolve-skill.sh <skill-name> <cwd>
#        resolve-skill.sh --plugin-root <plugin>:<member>
#
# --plugin-root prints every distinct real install directory of the
# plugin named before the colon, one per line, across all marketplaces and
# scopes listed in installed_plugins.json (the Skill/Agent name carries no
# marketplace, so any of them may be the one that runs). Exit codes:
#   0  listed, all install dirs present
#   1  not listed (not an installed plugin; the gate leaves it alone)
#   2  listed but an install dir is missing or the file is unreadable
#      (the gate denies: fail closed)
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

# Plugin-qualified form: "<plugin>:<skill>"
if [[ "$name" == *:* ]]; then
  plugin="${name%%:*}"
  skill="${name#*:}"
  installed_json="$HOME/.claude/plugins/installed_plugins.json"
  [ -f "$installed_json" ] || exit 1

  if [ "$plugin_root_only" -eq 1 ]; then
    INSTALLED_JSON="$installed_json" PLUGIN_NAME="$plugin" python3 -c "
import json, os, sys
try:
    with open(os.environ['INSTALLED_JSON']) as f:
        data = json.load(f)
except Exception:
    sys.exit(2)
target = os.environ['PLUGIN_NAME']
roots, listed = [], False
for key, entries in (data.get('plugins') or {}).items():
    if key.split('@', 1)[0] != target:
        continue
    listed = True
    for e in entries or []:
        p = (e or {}).get('installPath') or ''
        if not p or not os.path.isdir(p):
            sys.exit(2)
        r = os.path.realpath(p)
        if r not in roots:
            roots.append(r)
if not listed:
    sys.exit(1)
if not roots:
    sys.exit(2)
print('\n'.join(roots))
"
    exit $?
  fi

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
  [ -d "$install_path" ] || exit 1

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

# Not a locally-installed, file-backed skill (likely a Claude Code
# bundled/built-in skill, or a claude.ai-synced one) — nothing to resolve.
exit 1
