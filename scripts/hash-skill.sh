#!/usr/bin/env bash
# Deterministic content hash of a skill directory: sha256 of every
# tracked file's path+contents, sorted by path, then hashed together.
# Order-independent, catches any add/remove/edit under the directory.
#
# Usage: hash-skill.sh <dir>
set -uo pipefail

dir="${1:?usage: hash-skill.sh <dir>}"
[ -d "$dir" ] || exit 1

find "$dir" -type f ! -name '.DS_Store' -print0 \
  | sort -z \
  | while IFS= read -r -d '' f; do
      rel="${f#"$dir"/}"
      printf '%s\n' "$rel"
      shasum -a 256 "$f" | awk '{print $1}'
    done \
  | shasum -a 256 \
  | awk '{print $1}'
