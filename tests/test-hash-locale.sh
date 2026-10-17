#!/usr/bin/env bash
# Regression test: hash-skill.sh must give the same hash whatever the caller's
# locale. Claude Code hooks run with no LANG (C collation); approvals are often
# run from a UTF-8 shell, so a locale-dependent sort order blocks approved skills.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
hash="$here/../scripts/hash-skill.sh"

# Pick a UTF-8 locale the host actually has (macOS: en_US.UTF-8, Linux: en_US.utf8).
utf8=""
avail="$(locale -a 2>/dev/null || true)"
for l in en_US.UTF-8 en_US.utf8 C.UTF-8 C.utf8; do
  if printf '%s\n' "$avail" | grep -qx "$l"; then utf8="$l"; break; fi
done
[ -n "$utf8" ] || { echo "FAIL: no UTF-8 locale available to test against" >&2; exit 1; }

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/references"
printf 'skill\n' > "$fixture/SKILL.md"
printf 'ref\n'   > "$fixture/references/x.md"

# Vacuity guard: the chosen locale must really order these files differently
# from C, otherwise the comparison below proves nothing.
c_first="$(cd "$fixture" && find . -type f -print0 | LC_ALL=C sort -z | tr '\0' '\n' | head -1)"
u_first="$(cd "$fixture" && find . -type f -print0 | LC_ALL="$utf8" sort -z | tr '\0' '\n' | head -1)"
if [ "$c_first" = "$u_first" ]; then
  echo "FAIL: locale $utf8 collates like C on this host; test would be vacuous" >&2
  exit 1
fi

h_c="$(LC_ALL=C bash "$hash" "$fixture")"
h_u="$(LC_ALL="$utf8" bash "$hash" "$fixture")"
h_hook="$(env -u LANG -u LC_ALL -u LC_COLLATE bash "$hash" "$fixture")"

# Bytewise (C) order: SKILL.md before references/x.md.
expected="$(printf 'SKILL.md\n%s\nreferences/x.md\n%s\n' \
  "$(printf 'skill\n' | shasum -a 256 | awk '{print $1}')" \
  "$(printf 'ref\n' | shasum -a 256 | awk '{print $1}')" \
  | shasum -a 256 | awk '{print $1}')"

fail=0
for pair in "C:$h_c" "$utf8:$h_u" "no-LANG:$h_hook"; do
  name="${pair%%:*}"; val="${pair#*:}"
  if [ "$val" = "$expected" ]; then echo "ok   $name $val"
  else echo "FAIL $name $val (expected $expected)" >&2; fail=1; fi
done
exit "$fail"
