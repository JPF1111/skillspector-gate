#!/usr/bin/env python3
"""Scan a skill directory and record a verdict in the approval ledger.

Usage:
  approve.py <skill-dir> --verdict APPROVE|CAUTION|REJECT --note "..." [--name NAME] [--skip-scan]

Writes/updates <data-dir>/ledger.json (default ~/.claude/skillspector-gate/ledger.json,
override with $SKILLSPECTOR_GATE_HOME), keyed by the skill's resolved absolute
directory path. The PreToolUse gate hook (gate-skill.sh) reads this file and
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
DATA_DIR = os.environ.get("SKILLSPECTOR_GATE_HOME", os.path.expanduser("~/.claude/skillspector-gate"))
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


def hash_dir(path):
    out = subprocess.run([HASH_SCRIPT, path], capture_output=True, text=True, check=True)
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
    args = ap.parse_args()

    path = os.path.realpath(args.skill_dir)
    if not os.path.isdir(path):
        print(f"error: not a directory: {path}", file=sys.stderr)
        sys.exit(1)

    content_hash = hash_dir(path)
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

    if not args.skip_scan:
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
    print(f"Recorded {args.verdict} for {name} ({path})")
    print(f"  hash: {content_hash[:16]}...")
    print(f"  ledger: {LEDGER_PATH}")


if __name__ == "__main__":
    main()
