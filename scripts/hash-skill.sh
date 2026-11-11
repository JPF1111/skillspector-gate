#!/usr/bin/env bash
# Deterministic content hash of a skill directory: sha256 of every
# file's path+contents, sorted by path, then hashed together.
# Order-independent, catches any add/remove/edit under the directory.
#
# Symlinks are hashed by their link text. A symlink whose target resolves
# outside the directory makes the hash fail (exit 3, nothing on stdout),
# so the gate denies: content the hash cannot see must not pass as
# approved. (`find -type f` alone skipped symlinks entirely.)
#
# --shell hashes a plugin's install directory *outside* its skill
# directories: agents/, commands/, scripts/, hooks/, rules/, mcp.json,
# plugin.json, fixtures/, and any loose file under skills/ that is not
# inside a directory holding a SKILL.md. Skill directories are left to
# the per-skill entries. Claude Code's per-process lock files are skipped
# only when they are exactly that: .in_use/<pid>, a regular, non-executable
# file under 200 bytes holding one line {"pid":<pid>,"procStart":"<date>"}
# whose pid matches its name. Anything else under .in_use/ is hashed, and a
# symlink into .in_use/ fails the hash (it could point at skipped content).
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
root_real=$(cd "$dir" && pwd -P) || exit 1

# Is <f> (relative name <rel>) one of Claude Code's .in_use/<pid> lock files?
is_lock_file() {
  local f="$1" rel="$2" pid size
  [[ "$rel" =~ ^\.in_use/([0-9]{1,10})$ ]] || return 1
  pid="${BASH_REMATCH[1]}"
  [ -f "$f" ] && [ ! -L "$f" ] && [ ! -x "$f" ] || return 1
  size=$(wc -c < "$f" | tr -d ' ')
  [ "$size" -lt 200 ] || return 1
  [ "$(wc -l < "$f" | tr -d ' ')" -le 1 ] || return 1
  grep -Eqx "\{\"pid\":$pid,\"procStart\":\"[A-Za-z0-9 :]{1,40}\"\}" "$f"
}

# In shell mode: is <rel> inside a skill directory under skills/?
in_skill_dir() {
  local rel="$1" p="skills" rest comp
  case "$rel" in skills/*) ;; *) return 1 ;; esac
  rest="${rel#skills/}"
  while [[ "$rest" == */* ]]; do
    comp="${rest%%/*}"
    rest="${rest#*/}"
    p="$p/$comp"
    [ -f "$dir/$p/SKILL.md" ] && return 0
  done
  return 1
}

stream=$(mktemp) || exit 1
trap 'rm -f "$stream"' EXIT

while IFS= read -r -d '' f; do
  rel="${f#"$dir"/}"
  if [ "$shell" -eq 1 ]; then
    in_skill_dir "$rel" && continue
    is_lock_file "$f" "$rel" && continue
  fi
  if [ -L "$f" ]; then
    target_real=$(readlink -f "$f" 2>/dev/null) || target_real=""
    case "$target_real" in
      "$root_real"/.in_use|"$root_real"/.in_use/*)
        echo "hash-skill.sh: symlink $rel points into .in_use/ — refusing to hash" >&2; exit 3 ;;
      "$root_real"|"$root_real"/*) ;;
      *) echo "hash-skill.sh: symlink $rel points outside $dir — refusing to hash" >&2; exit 3 ;;
    esac
    printf '%s\nsymlink:%s\n' "$rel" "$(readlink "$f")" >> "$stream"
  else
    printf '%s\n%s\n' "$rel" "$(shasum -a 256 "$f" | awk '{print $1}')" >> "$stream"
  fi
done < <(find "$dir" \( -type f -o -type l \) ! -name '.DS_Store' -print0 | sort -z)

shasum -a 256 < "$stream" | awk '{print $1}'
