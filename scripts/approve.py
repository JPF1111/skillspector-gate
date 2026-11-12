#!/usr/bin/env python3
"""Scan a skill directory and record a verdict in the approval ledger.

Usage:
  approve.py <skill-dir> --verdict APPROVE|CAUTION|REJECT --note "..." [--name NAME] [--skip-scan]
  approve.py --shell <plugin-install-dir> --verdict ... --note "..." [--member-verdict NAME=REJECT]

Writes/updates <data-dir>/ledger.json (default ~/.claude/skillspector-gate/ledger.json, or
~/.claude/skillspector/ledger.json for a standalone install; override with $SKILLSPECTOR_GATE_HOME),
keyed by the resolved absolute directory path. A --shell entry covers a plugin's content
outside skills/ and is marked kind "plugin-shell". The PreToolUse gate hook (gate-skill.sh) reads this file and
blocks any skill whose current content hash doesn't match an entry with
verdict APPROVE or CAUTION.
"""
import argparse
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
    ap.add_argument("skill_dir")
    ap.add_argument("--verdict", required=True, choices=["APPROVE", "CAUTION", "REJECT"])
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

    ledger = load_ledger()
    ledger[path] = entry
    save_ledger(ledger)
    print(f"Recorded {args.verdict} for {name}{' (plugin shell)' if args.shell else ''} ({path})")
    print(f"  hash: {content_hash[:16]}...")
    print(f"  ledger: {LEDGER_PATH}")


if __name__ == "__main__":
    main()
