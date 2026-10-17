#!/usr/bin/env bash
# Deterministic content hash of a skill directory: sha256 of every
# tracked file's path+contents, sorted by path, then hashed together.
# Order-independent, catches any add/remove/edit under the directory.
#
# --shell hashes a plugin's install directory *outside* its skills/
# subtree: agents/, commands/, scripts/, hooks/, rules/, mcp.json,
# plugin.json, fixtures/ ... — everything a plugin skill or agent can
# reach that no per-skill hash covers. skills/ is left to the per-skill
# entries, and .in_use/ (Claude Code's per-process lock files, rewritten
# every session) is skipped so the hash only moves when content does.
#
# Usage: hash-skill.sh [--shell] <dir>
set -uo pipefail
# Pin collation: `sort` order (and so the hash) otherwise depends on the caller's locale.
export LC_ALL=C

shell=0
if [ "${1:-}" = "--shell" ]; then
  shell=1
  shift
fi

dir="${1:?usage: hash-skill.sh [--shell] <dir>}"
[ -d "$dir" ] || exit 1

list_files() {
  if [ "$shell" -eq 1 ]; then
    find "$dir" \( -path "$dir/skills" -o -path "$dir/.in_use" \) -prune \
      -o -type f ! -name '.DS_Store' -print0
  else
    find "$dir" -type f ! -name '.DS_Store' -print0
  fi
}

list_files \
  | sort -z \
  | while IFS= read -r -d '' f; do
      rel="${f#"$dir"/}"
      printf '%s\n' "$rel"
      shasum -a 256 "$f" | awk '{print $1}'
    done \
  | shasum -a 256 \
  | awk '{print $1}'
