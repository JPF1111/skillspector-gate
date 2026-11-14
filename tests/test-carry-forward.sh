#!/usr/bin/env bash
# Regression test: approvals carry forward to a new plugin version when the content is
# byte-identical (carry.py), and nowhere else. Also covers approve.py --carry-forward and
# --prune. Runs against a throwaway HOME; touches nothing real.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="$here/../scripts"

tmp="$(cd "$(mktemp -d)" && pwd -P)"   # macOS: /var -> /private/var
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export SKILLSPECTOR_GATE_HOME="$tmp/data"
mkdir -p "$HOME/.claude/plugins" "$SKILLSPECTOR_GATE_HOME"
HOME="$(cd "$HOME" && pwd -P)"   # macOS: /var -> /private/var
export HOME
LEDGER="$SKILLSPECTOR_GATE_HOME/ledger.json"
cache="$HOME/.claude/plugins/cache"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
check() {  # check <expected allow|deny> <description> <hook-input-json>
  local want="$1" desc="$2" got
  got=$(printf '%s' "$3" | bash "$scripts/gate-skill.sh" | python3 -c "import json,sys; print(json.load(sys.stdin)['hookSpecificOutput']['permissionDecision'])")
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc (want $want, got $got)"; fi
}
skill() { printf '{"tool_name":"Skill","tool_input":{"skill":"%s"},"cwd":"%s"}' "$1" "$tmp"; }
agent() { printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s","prompt":"x"},"cwd":"%s"}' "$1" "$tmp"; }
approve() { python3 "$scripts/approve.py" "$@" --skip-scan --note test >/dev/null; }
installed() {  # installed <name@mkt> <path> [<name@mkt> <path> ...]
  python3 - "$@" > "$HOME/.claude/plugins/installed_plugins.json" <<'PY'
import json, sys
a = sys.argv[1:]
print(json.dumps({"plugins": {a[i]: [{"installPath": a[i + 1]}] for i in range(0, len(a), 2)}}))
PY
}
make_plugin() {  # make_plugin <dir>
  mkdir -p "$1/skills/alpha" "$1/agents" "$1/.claude-plugin"
  printf 'alpha\n'  > "$1/skills/alpha/SKILL.md"
  printf 'writer\n' > "$1/agents/writer.md"
  printf 'reader\n' > "$1/agents/reader.md"
  printf '{"name":"demo"}\n' > "$1/.claude-plugin/plugin.json"
}
entry() { python3 -c "import json,sys; print(json.dumps(json.load(open('$LEDGER')).get(sys.argv[1])))" "$1"; }

# --- v1 approved: skill APPROVE, shell CAUTION with one agent rejected. ---
v1="$cache/mkt/demo/v1"
make_plugin "$v1"
installed demo@mkt "$v1"
approve "$v1/skills/alpha" --verdict APPROVE
approve --shell "$v1" --verdict CAUTION --member-verdict writer=REJECT
check allow "v1 skill allowed" "$(skill demo:alpha)"

# --- update: v2 is byte-identical, v1 removed (the ea10 -> f75f case). ---
v2="$cache/mkt/demo/v2"
make_plugin "$v2"
installed demo@mkt "$v2"
rm -rf "$v1"
check allow "v2 skill carried from identical v1 skill + shell" "$(skill demo:alpha)"
check allow "v2 agent carried (shell carried)"                 "$(agent demo:reader)"
check deny  "v2 member REJECT carried with the shell"           "$(agent demo:writer)"
[ "$(entry "$v2/skills/alpha")" = null ] && ok "gate wrote nothing to the ledger" || bad "gate wrote to the ledger"

# --- a changed byte is not carried. ---
printf 'alpha edited\n' > "$v2/skills/alpha/SKILL.md"
check deny  "changed skill byte not carried" "$(skill demo:alpha)"
printf 'alpha\n' > "$v2/skills/alpha/SKILL.md"
printf 'reader v2\n' > "$v2/agents/reader.md"
check deny  "changed shell byte not carried (skill denied too)" "$(skill demo:alpha)"
check deny  "changed shell byte not carried (agent)"            "$(agent demo:reader)"
printf 'reader\n' > "$v2/agents/reader.md"
check allow "restored v2 carries again" "$(skill demo:alpha)"

# --- an exact entry always decides. ---
cp "$LEDGER" "$tmp/ledger.bak"
python3 - "$LEDGER" "$v2/skills/alpha" <<'PY'
import json, sys
p, d = sys.argv[1:]
l = json.load(open(p)); l[d] = {"path": d, "hash": "0" * 64, "verdict": "APPROVE"}
json.dump(l, open(p, "w"))
PY
check deny  "exact STALE entry beats a matching carry source" "$(skill demo:alpha)"
cp "$tmp/ledger.bak" "$LEDGER"
approve "$v2/skills/alpha" --verdict REJECT
check deny  "exact REJECT entry beats a matching carry source" "$(skill demo:alpha)"
cp "$tmp/ledger.bak" "$LEDGER"
approve "$v2" --verdict APPROVE   # skill-mode entry on the root: kind mismatch at the exact path
check deny  "exact kind-mismatched entry on root blocks shell carry" "$(agent demo:reader)"
cp "$tmp/ledger.bak" "$LEDGER"
check allow "ledger restored, carry works" "$(skill demo:alpha)"

# --- a REJECT of the same hash anywhere blocks the carry. ---
rej="$tmp/elsewhere/alpha"
mkdir -p "$rej" && printf 'alpha\n' > "$rej/SKILL.md"
approve "$rej" --verdict REJECT
check deny  "same-hash REJECT elsewhere blocks skill carry" "$(skill demo:alpha)"
cp "$tmp/ledger.bak" "$LEDGER"
rejshell="$tmp/elsewhere/shellcopy"; mkdir -p "$rejshell" && cp -R "$v2/." "$rejshell/"
approve --shell "$rejshell" --verdict REJECT
check deny  "same-hash shell REJECT elsewhere blocks shell carry" "$(agent demo:reader)"
cp "$tmp/ledger.bak" "$LEDGER"

# --- same bytes, other lineage: nothing carries. ---
o1="$cache/mkt2/demo/v1"; make_plugin "$o1"
installed demo@mkt2 "$o1"
approve --shell "$o1" --verdict APPROVE
check deny  "same plugin name, other marketplace: no carry" "$(skill demo:alpha)"
o2="$cache/mkt/other/v1"; make_plugin "$o2"
printf '{"name":"other"}\n' > "$o2/.claude-plugin/plugin.json"
installed other@mkt "$o2"
approve --shell "$o2" --verdict APPROVE
check deny  "same marketplace, other plugin: no carry" "$(skill other:alpha)"
local_root="$HOME/local-plugins/demo"; make_plugin "$local_root"
installed demo@mkt "$local_root"
approve --shell "$local_root" --verdict APPROVE
check deny  "non-cache installPath: no carry" "$(skill demo:alpha)"
deep="$cache/mkt/demo/v3/nested"; make_plugin "$deep"
installed demo@mkt "$deep"
approve --shell "$deep" --verdict APPROVE
check deny  "root deeper than <mkt>/<plugin>/<version>: no carry" "$(skill demo:alpha)"

# --- a skill dir symlinked out of the plugin root: no carry. ---
v4="$cache/mkt/demo/v4"; make_plugin "$v4"
rm -rf "$v4/skills/alpha"
outside="$tmp/outside/alpha"; mkdir -p "$outside" && printf 'alpha\n' > "$outside/SKILL.md"
ln -s "$outside" "$v4/skills/alpha"
installed demo@mkt "$v4"
check deny  "skill symlinked outside the root: denied" "$(skill demo:alpha)"
# The shell hash already refuses that symlink; check the skill carry on its own too.
hs=$(bash "$scripts/hash-skill.sh" "$outside")
[ "$(python3 "$scripts/carry.py" check "$LEDGER" "$outside" "$hs" skill "" "$v4")" = MISSING ] \
  && ok "carry.py: skill real path outside its root never carries" || bad "carry.py carried a skill outside its root"
rm -rf "$v4"

# --- a renamed skill dir is a different lineage. ---
v5="$cache/mkt/demo/v5"; make_plugin "$v5"
mv "$v5/skills/alpha" "$v5/skills/beta"
installed demo@mkt "$v5"
approve --shell "$v5" --verdict APPROVE
check deny  "same bytes under another skill name: no carry" "$(skill demo:beta)"
# Control: the same exact-shell setup with the skill also approved is allowed, so the
# denies above are the skill carry being refused, not the shell.
approve "$v5/skills/beta" --verdict APPROVE
check allow "control: exact shell + exact skill allowed" "$(skill demo:beta)"
rm -rf "$v5" "$o1" "$o2" "$local_root" "$cache/mkt/demo/v3"
cp "$tmp/ledger.bak" "$LEDGER"

# --- carry.py check, direct. ---
h=$(bash "$scripts/hash-skill.sh" "$v2/skills/alpha")
[ "$(python3 "$scripts/carry.py" check "$LEDGER" "$v2/skills/alpha" "$h" skill)" = MISSING ] \
  && ok "carry.py: no plugin root, no carry" || bad "carry.py carried without a plugin root"
[[ "$(python3 "$scripts/carry.py" check "$LEDGER" "$v2/skills/alpha" "$h" skill "" "$v2")" == "CARRIED $v1/skills/alpha" ]] \
  && ok "carry.py: names its source" || bad "carry.py source"
[ "$(python3 "$scripts/carry.py" check "$LEDGER" "$v2/skills/alpha" "$h" shell "" "$v2")" = MISSING ] \
  && ok "carry.py: skill hash cannot carry a shell" || bad "carry.py kind confusion"
printf 'not json' > "$tmp/broken.json"
[ "$(python3 "$scripts/carry.py" check "$tmp/broken.json" "$v2/skills/alpha" "$h" skill "" "$v2")" = MISSING ] \
  && ok "carry.py: unreadable ledger -> MISSING" || bad "carry.py unreadable ledger"

# --- prune keeps carry sources and REJECTs; carry-forward materializes. ---
installed demo@mkt "$v2"
dead_rej="$tmp/gone/rejected"; mkdir -p "$dead_rej" && printf 'r\n' > "$dead_rej/SKILL.md"
approve "$dead_rej" --verdict REJECT
dead_ok="$cache/mkt/gone/v1/skills/approved"; mkdir -p "$dead_ok" && printf 'a\n' > "$dead_ok/SKILL.md"
approve "$dead_ok" --verdict APPROVE
dead_mv="$cache/mkt/gone/v1"
approve --shell "$dead_mv" --verdict APPROVE --member-verdict writer=REJECT
dead_global="$tmp/gone/global"; mkdir -p "$dead_global" && printf 'g\n' > "$dead_global/SKILL.md"
approve "$dead_global" --verdict APPROVE
rm -rf "$tmp/gone" "$cache/mkt/gone"
before=$(shasum -a 256 < "$LEDGER")
out=$(python3 "$scripts/approve.py" --prune)
[ "$(shasum -a 256 < "$LEDGER")" = "$before" ] && ok "prune dry run writes nothing" || bad "prune dry run wrote"
python3 "$scripts/approve.py" --prune --apply >/dev/null
[ "$(entry "$v1/skills/alpha")" != null ] && [ "$(entry "$v1")" != null ] \
  && ok "prune keeps live carry sources" || bad "prune removed a carry source"
[ "$(entry "$dead_rej")" != null ] && ok "prune keeps dead REJECT" || bad "prune removed a REJECT"
[ "$(entry "$dead_ok")" = null ] && ok "prune removes dead plugin-cache APPROVE that carries nothing" || bad "prune kept an unused dead entry"
[ "$(entry "$dead_mv")" != null ] && ok "prune keeps a dead shell holding a member REJECT" || bad "prune removed a member REJECT"
[ "$(entry "$dead_global")" != null ] && ok "prune leaves dead non-plugin entries alone" || bad "prune removed a non-plugin entry"
check allow "carry still works after prune" "$(skill demo:alpha)"

out=$(python3 "$scripts/approve.py" --carry-forward)
[ "$(entry "$v2/skills/alpha")" = null ] && ok "carry-forward dry run writes nothing" || bad "carry-forward dry run wrote"
python3 "$scripts/approve.py" --carry-forward --apply --approved-by tester >/dev/null
python3 - "$LEDGER" "$v1" "$v2" <<'PY' && ok "carry-forward records entries with provenance and member verdicts" || bad "carry-forward entries"
import json, sys
p, v1, v2 = sys.argv[1:]
l = json.load(open(p))
s, sh = l[v2 + "/skills/alpha"], l[v2]
assert s["verdict"] == "APPROVE" and s["carried_from"] == [v1 + "/skills/alpha"] and s["carried_by"] == "tester"
assert s["path"] == v2 + "/skills/alpha" and s.get("kind") is None
assert sh["kind"] == "plugin-shell" and sh["verdict"] == "CAUTION" and sh["member_verdicts"] == {"writer": "REJECT"}
PY
python3 "$scripts/approve.py" --prune --apply >/dev/null
[ "$(entry "$v1/skills/alpha")" = null ] && ok "prune removes the source once carried" || bad "prune kept a materialized source"
check allow "v2 skill allowed by its own entry" "$(skill demo:alpha)"
check deny  "v2 member REJECT kept in materialized shell" "$(agent demo:writer)"
# A carried entry written by --apply still yields to a later same-hash REJECT (judge M1).
cp "$LEDGER" "$tmp/ledger.mat"
rej2="$tmp/elsewhere2/alpha"; mkdir -p "$rej2" && printf 'alpha\n' > "$rej2/SKILL.md"
approve "$rej2" --verdict REJECT
check deny  "materialized carried entry yields to a later same-hash REJECT" "$(skill demo:alpha)"
cp "$tmp/ledger.mat" "$LEDGER"
check allow "and allows again once that REJECT is gone" "$(skill demo:alpha)"

# Mixed CAUTION/APPROVE sources materialize as CAUTION (judge L2).
v6="$cache/mkt/demo/v6"; make_plugin "$v6"
approve "$v6/skills/alpha" --verdict CAUTION
v7="$cache/mkt/demo/v7"; make_plugin "$v7"
installed demo@mkt "$v7"
python3 "$scripts/approve.py" --carry-forward --apply >/dev/null
python3 - "$LEDGER" "$v7" <<'PY2' && ok "mixed sources materialize as CAUTION" || bad "CAUTION lost on carry-forward"
import json, sys
p, v7 = sys.argv[1:]
e = json.load(open(p))[v7 + "/skills/alpha"]
assert e["verdict"] == "CAUTION" and "CAUTION" in e["carried_verdicts"].values() and len(e["carried_from"]) == 2
PY2
[ -f "$LEDGER.lock" ] && ok "ledger writes take a lock file" || bad "no ledger lock file"
rm -rf "$v6" "$v7"

# Broken installed_plugins.json: carry-forward refuses cleanly, writes nothing.
before=$(shasum -a 256 < "$LEDGER")
printf 'not json' > "$HOME/.claude/plugins/installed_plugins.json"
st=0; python3 "$scripts/approve.py" --carry-forward --apply >/dev/null 2>&1 || st=$?
[ "$st" -eq 2 ] && [ "$(shasum -a 256 < "$LEDGER")" = "$before" ] \
  && ok "broken installed_plugins.json: exit 2, nothing written" || bad "broken installed_plugins.json (exit $st)"
installed demo@mkt "$v2"

python3 "$scripts/approve.py" --carry-forward --prune >/dev/null 2>&1 \
  && bad "--carry-forward with --prune accepted" || ok "--carry-forward with --prune refused"
python3 "$scripts/approve.py" --apply >/dev/null 2>&1 \
  && bad "--apply alone accepted" || ok "--apply alone refused"

# --- The 2026-11-13 incident shape: a skills-only plugin (no agents/, like playground and
# mcp-server-dev) auto-updates while the old version dir stays on disk. Claude Code then
# writes .orphaned_at into the old dir and leaves .in_use/<pid> locks in both. The shell
# approval recorded on the old dir must carry to the new one, and audit.sh must report
# 0 denied. (The 4 denies seen that day came from an audit run on the pre-0.5.0 gate.)
lockfile() {  # lockfile <plugin-dir> <pid>
  mkdir -p "$1/.in_use"
  printf '{"pid":%s,"procStart":"Thu Nov 13 08:50:00 2026"}' "$2" > "$1/.in_use/$2"
}
make_skills_only() {  # make_skills_only <dir>
  mkdir -p "$1/.claude-plugin" "$1/skills/pg"
  printf '{"name":"pg"}\n' > "$1/.claude-plugin/plugin.json"
  printf 'license\n' > "$1/LICENSE"
  printf 'readme\n' > "$1/README.md"
  printf 'pg\n' > "$1/skills/pg/SKILL.md"
}
old="$cache/official/pg/f75f5b25ae94"
make_skills_only "$old"; lockfile "$old" 4242
installed demo@mkt "$v2" pg@official "$old"
approve "$old/skills/pg" --verdict APPROVE
approve --shell "$old" --verdict APPROVE
check allow "incident: old version allowed" "$(skill pg:pg)"
new="$cache/official/pg/2ca121908cc6"
make_skills_only "$new"; lockfile "$new" 4343
printf '1794585051318' > "$old/.orphaned_at"    # the old dir stays, marked orphaned
installed demo@mkt "$v2" pg@official "$new"
[ "$(bash "$scripts/hash-skill.sh" --shell "$new")" = "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]['hash'])" "$LEDGER" "$old")" ] \
  && ok "incident: new shell hash equals the approved old shell's recorded hash" || bad "incident: shell hash differs"
check allow "incident: skill carried with the shell to the new version" "$(skill pg:pg)"
python3 "$scripts/approve.py" --carry-forward | grep -q "would carry shell $new " \
  && ok "incident: --carry-forward plans the shell" || bad "incident: --carry-forward misses the shell"
[ "$(python3 "$scripts/carry.py" check "$LEDGER" "$old" "$(bash "$scripts/hash-skill.sh" --shell "$old")" shell "" "$old")" = STALE ] \
  && ok "incident: the orphaned old dir's own shell entry is STALE (.orphaned_at is hashed; carry uses the recorded hash)" \
  || bad "incident: orphaned old dir's shell entry not STALE (did .orphaned_at hashing change?)"
installed pg@official "$new"   # audit only the incident plugin, independent of the demo state
st=0; aud=$(bash "$scripts/audit.sh" 2>&1) || st=$?
[ "$st" -eq 0 ] && printf '%s\n' "$aud" | grep -q ', 0 denied$' \
  && ok "incident: audit.sh reports 0 denied" || bad "incident: audit.sh (exit $st): $(printf '%s' "$aud" | grep -E 'DENY|^audit:' | tr '\n' ' ')"
printf 'pg changed\n' > "$new/skills/pg/SKILL.md"
check deny  "incident control: a changed skill in the new version is not carried" "$(skill pg:pg)"
printf 'pg\n' > "$new/skills/pg/SKILL.md"
printf 'readme changed\n' > "$new/README.md"
check deny  "incident control: a changed shell file in the new version is not carried" "$(skill pg:pg)"
printf 'readme\n' > "$new/README.md"
installed demo@mkt "$v2"

echo "test-carry-forward: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
