#!/usr/bin/env python3
"""Scan a skill directory and record a verdict in the approval ledger.

Usage:
  approve.py <skill-dir> --verdict APPROVE|CAUTION|REJECT --note "..." [--name NAME] [--skip-scan]
  approve.py --shell <plugin-install-dir> --verdict ... --note "..." [--member-verdict NAME=REJECT]
  approve.py --carry-forward [--apply]   record approvals carried to new plugin versions (carry.py)
  approve.py --prune [--apply]           remove dead plugin-cache APPROVE/CAUTION entries nothing
                                         depends on (never a REJECT or a member REJECT)
  (--carry-forward and --prune are dry runs that change nothing unless --apply is given)

Writes/updates <data-dir>/ledger.json (default ~/.claude/skillspector-gate/ledger.json, or
~/.claude/skillspector/ledger.json for a standalone install; override with $SKILLSPECTOR_GATE_HOME),
keyed by the resolved absolute directory path. A --shell entry covers a plugin's content
outside skills/ and is marked kind "plugin-shell". The PreToolUse gate hook (gate-skill.sh) reads this file and
blocks any skill whose current content hash doesn't match an entry with
verdict APPROVE or CAUTION.
"""
import argparse
import contextlib
import fcntl
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# Same resolution order as gate-skill.sh, home paths only (never this script's own
# install dir): $SKILLSPECTOR_GATE_HOME, else ~/.claude/skillspector-gate if it holds a
# ledger, else the standalone install ~/.claude/skillspector if it holds one, else
# ~/.claude/skillspector-gate.
_GATE_HOME = os.path.expanduser("~/.claude/skillspector-gate")
_STANDALONE = os.path.expanduser("~/.claude/skillspector")
if os.environ.get("SKILLSPECTOR_GATE_HOME"):
    DATA_DIR = os.environ["SKILLSPECTOR_GATE_HOME"]
elif os.path.exists(os.path.join(_GATE_HOME, "ledger.json")):
    DATA_DIR = _GATE_HOME
elif os.path.exists(os.path.join(_STANDALONE, "ledger.json")):
    DATA_DIR = _STANDALONE
else:
    DATA_DIR = _GATE_HOME
LEDGER_PATH = os.path.join(DATA_DIR, "ledger.json")
HASH_SCRIPT = os.path.join(SCRIPT_DIR, "hash-skill.sh")


def find_skillspector():
    found = shutil.which("skillspector")
    if found:
        return found
    fallback = os.path.expanduser("~/.local/bin/skillspector")
    if os.path.exists(fallback):
        return fallback
    print(
        "error: 'skillspector' not found on PATH or at ~/.local/bin/skillspector.\n"
        "Install it: uv tool install git+https://github.com/NVIDIA/skillspector.git",
        file=sys.stderr,
    )
    sys.exit(1)


def load_ledger():
    if os.path.exists(LEDGER_PATH):
        with open(LEDGER_PATH) as f:
            return json.load(f)
    return {}


@contextlib.contextmanager
def ledger_lock():
    """Exclusive lock for a whole read-modify-write of the ledger, so two approve.py runs
    (e.g. a REJECT recorded while --carry-forward is hashing) cannot overwrite each other."""
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(LEDGER_PATH + ".lock", "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def save_ledger(ledger):
    os.makedirs(os.path.dirname(LEDGER_PATH), exist_ok=True)
    tmp = LEDGER_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(ledger, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, LEDGER_PATH)


def hash_dir(path, shell=False):
    cmd = [HASH_SCRIPT, "--shell", path] if shell else [HASH_SCRIPT, path]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return out.stdout.strip()


def _load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(SCRIPT_DIR, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def live_plugin_dirs():
    """(dir, mode, plugin_root) for every installed plugin root (its shell) and every skill
    dir in it. Only installed plugins: carry-forward does not apply to synced ones."""
    index = _load_module("plugin_index", "plugin-index.py")
    out = []
    try:
        roots = index.dedup(index.installed_roots())
    except index.Broken:
        print("error: installed_plugins.json is unreadable or lists a missing install dir; "
              "nothing written", file=sys.stderr)
        sys.exit(2)
    for _, root in roots:
        if not os.path.isdir(root):
            continue
        out.append((root, "shell", root))
        for kind, member in index.members(root):
            if kind != "skill":
                continue
            d = index.find(root, member, "skill")
            if d:
                out.append((d, "skill", root))
    return out


def carry_plan(ledger):
    """[(dir, mode, root, hash, [source keys])] for live dirs with no entry of their own
    whose approval carry.py would carry forward right now."""
    carry = _load_module("carry", "carry.py")
    plan = []
    for d, mode, root in live_plugin_dirs():
        if d in ledger:
            continue
        try:
            h = hash_dir(d, shell=(mode == "shell"))
        except subprocess.CalledProcessError:
            continue
        if not h:
            continue
        result, _ = carry.check(ledger, d, h, mode, "", root)
        if result in ("CARRIED", "MEMBER_REJECTED"):
            plan.append((d, mode, root, h, carry.sources(ledger, d, h, mode == "shell", root)))
    return plan


def do_carry_forward(apply, by):
    carry = _load_module("carry", "carry.py")
    with ledger_lock():
        ledger = load_ledger()
        plan = carry_plan(ledger)
        now = datetime.now(timezone.utc).isoformat()
        for d, mode, root, h, keys in plan:
            verdicts = {k: ledger[k].get("verdict") for k in keys}
            # The most conservative source verdict: CAUTION is a revisit marker, keep it.
            verdict = "CAUTION" if "CAUTION" in verdicts.values() else "APPROVE"
            src = ledger[keys[0]]
            print(f"{'carry' if apply else 'would carry'} {mode:5} {d} ({verdict})")
            for k in keys:
                print(f"      from {k} ({verdicts[k]})")
            entry = {k: v for k, v in src.items() if k != "member_verdicts"}
            entry.update({
                "path": d,
                "hash": h,
                "verdict": verdict,
                "carried_from": keys,
                "carried_verdicts": verdicts,
                "carried_by": by,
                "carried_at": now,
            })
            if mode == "shell":
                mv = carry.carried_member_verdicts(ledger, keys)
                if mv:
                    entry["member_verdicts"] = mv
            ledger[d] = entry
        if apply and plan:
            save_ledger(ledger)
    print(f"{len(plan)} entr{'y' if len(plan) == 1 else 'ies'} {'recorded' if apply else 'to carry (dry run; --apply records them)'}")


def do_prune(apply):
    carry = _load_module("carry", "carry.py")
    with ledger_lock():
        ledger = load_ledger()
        keep_sources = set()
        for _, _, _, _, keys in carry_plan(ledger):
            keep_sources.update(keys)
        # Only plugin-cache entries: a global or project skill on an unmounted volume or in a
        # removed worktree keeps its history.
        dead = [k for k in sorted(ledger) if carry.lineage(k) is not None and not os.path.isdir(k)]
        prune, kept = [], []
        for k in dead:
            e = ledger[k] if isinstance(ledger[k], dict) else {}
            v = e.get("verdict")
            mv = e.get("member_verdicts")
            if v not in ("APPROVE", "CAUTION"):
                kept.append((k, f"verdict {v}: REJECT entries are never pruned"))
            elif not isinstance(mv, (dict, type(None))) or "REJECT" in (mv or {}).values():
                kept.append((k, "holds a member REJECT: never pruned"))
            elif k in keep_sources:
                kept.append((k, "still carries an approval to a live dir; run --carry-forward --apply first"))
            else:
                prune.append(k)
        for k, why in kept:
            print(f"keep  {k} ({why})")
        for k in prune:
            print(f"{'prune' if apply else 'would prune'} {k}")
            if apply:
                del ledger[k]
        if apply and prune:
            save_ledger(ledger)
    print(f"{len(prune)} dead entr{'y' if len(prune) == 1 else 'ies'} {'pruned' if apply else 'to prune (dry run; --apply removes them)'}, {len(kept)} kept")


def run_scan(skillspector_bin, path):
    proc = subprocess.run(
        [skillspector_bin, "scan", path, "--no-llm", "--format", "json"],
        capture_output=True, text=True,
    )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("skill_dir", nargs="?")
    ap.add_argument("--verdict", choices=["APPROVE", "CAUTION", "REJECT"])
    ap.add_argument("--carry-forward", action="store_true",
                    help="Record approvals carried forward to new plugin versions (dry run without --apply).")
    ap.add_argument("--prune", action="store_true",
                    help="Remove dead APPROVE/CAUTION entries that carry nothing (dry run without --apply).")
    ap.add_argument("--apply", action="store_true", help="With --carry-forward or --prune: write the ledger.")
    ap.add_argument("--note", default="")
    ap.add_argument("--name", default=None)
    ap.add_argument("--approved-by", default=os.environ.get("USER", "unknown"))
    ap.add_argument("--skip-scan", action="store_true", help="Don't re-run skillspector, just record verdict/hash")
    ap.add_argument("--risk-score", type=float, default=None)
    ap.add_argument("--risk-severity", default=None)
    ap.add_argument(
        "--shell", action="store_true",
        help="Approve a plugin install dir's shell: everything outside skills/ (agents, commands, "
             "scripts, hooks, mcp.json ...). Implies --skip-scan (skillspector scans skill dirs).",
    )
    ap.add_argument(
        "--member-verdict", action="append", default=[], metavar="NAME=REJECT",
        help="With --shell: block one skill/command/agent of the plugin by name (repeatable).",
    )
    args = ap.parse_args()
    if args.carry_forward or args.prune:
        if args.carry_forward and args.prune:
            ap.error("run --carry-forward and --prune separately (carry forward first)")
        if args.skill_dir or args.verdict or args.shell or args.member_verdict:
            ap.error("--carry-forward / --prune take no skill dir, --verdict, --shell or --member-verdict")
        if args.carry_forward:
            do_carry_forward(args.apply, args.approved_by)
        else:
            do_prune(args.apply)
        return
    if args.apply:
        ap.error("--apply goes with --carry-forward or --prune")
    if not args.skill_dir or not args.verdict:
        ap.error("a skill dir and --verdict are required")
    if args.member_verdict and not args.shell:
        ap.error("--member-verdict needs --shell")
    member_verdicts = {}
    for mv in args.member_verdict:
        member, sep, verdict = mv.partition("=")
        if not sep or not member or verdict != "REJECT":
            ap.error(f"--member-verdict takes NAME=REJECT, got {mv!r}")
        member_verdicts[member] = verdict

    path = os.path.realpath(args.skill_dir)
    if not os.path.isdir(path):
        print(f"error: not a directory: {path}", file=sys.stderr)
        sys.exit(1)

    content_hash = hash_dir(path, shell=args.shell)
    name = args.name or os.path.basename(path)

    entry = {
        "name": name,
        "path": path,
        "hash": content_hash,
        "verdict": args.verdict,
        "note": args.note,
        "approved_by": args.approved_by,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
    }
    if args.shell:
        entry["kind"] = "plugin-shell"
        if member_verdicts:
            entry["member_verdicts"] = member_verdicts
    if args.risk_score is not None:
        entry["skillspector_score"] = args.risk_score
    if args.risk_severity is not None:
        entry["skillspector_severity"] = args.risk_severity

    if not args.skip_scan and not args.shell:
        skillspector_bin = find_skillspector()
        result = run_scan(skillspector_bin, path)
        if result:
            ra = result.get("risk_assessment") or {}
            entry["skillspector_score"] = ra.get("score")
            entry["skillspector_severity"] = ra.get("severity")
            entry["skillspector_recommendation"] = ra.get("recommendation")

    with ledger_lock():
        ledger = load_ledger()
        ledger[path] = entry
        save_ledger(ledger)
    print(f"Recorded {args.verdict} for {name}{' (plugin shell)' if args.shell else ''} ({path})")
    print(f"  hash: {content_hash[:16]}...")
    print(f"  ledger: {LEDGER_PATH}")


if __name__ == "__main__":
    main()
