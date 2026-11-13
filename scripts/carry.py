#!/usr/bin/env python3
"""Ledger lookup for the gate, with approval carry-forward across plugin versions.

The ledger is keyed by a directory's real path. A plugin update installs into a new
versioned cache directory (~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/), so
byte-identical skills and shells used to be re-blocked on every update. carry-forward lets
an approval follow the content into the new directory, under all of these conditions:

  1. There is no ledger entry at the exact path. An exact entry always decides: a stale
     hash, a REJECT or a kind mismatch there denies, as before.
  2. The directory is an installed plugin's member or shell, and the plugin root has the
     cache shape <cache>/<marketplace>/<plugin>/<version> (real paths). Any other
     installPath, claude.ai-synced plugins, global and project skills: no carry-forward.
     A skill whose real path leaves its plugin root: no carry-forward.
  3. A source entry has the same lineage: same marketplace, same plugin directory, same path
     relative to its version root (a shell: the root itself), a different version.
  4. The source has the same kind (skill or plugin-shell), the same content hash, and
     verdict APPROVE or CAUTION.
  5. No entry anywhere in the ledger with the same kind and hash is REJECT.

A carried shell takes the member_verdicts of every matching source (union), so a member
rejected in an earlier version stays rejected.

An entry recorded by approve.py --carry-forward (it has carried_from) keeps rule 5: a later
REJECT of the same kind and hash anywhere denies it.

The gate never writes the ledger. approve.py --carry-forward records carried entries at
their new paths (JP-run); approve.py --prune removes dead plugin-cache entries that nothing
depends on.

Usage:
  carry.py check <ledger> <dir> <hash> <skill|shell> [<member>] [<plugin-root>]
      prints one of OK, CARRIED <source>, MISSING, STALE, REJECTED, MEMBER_REJECTED.
      <plugin-root> (the root plugin-index.py gave) enables carry-forward.
"""
import json
import os
import sys

OK_VERDICTS = ("APPROVE", "CAUTION")


def cache_dir():
    return os.path.realpath(os.path.join(os.path.expanduser("~"), ".claude", "plugins", "cache"))


def _under(path, base):
    return path.startswith(base + os.sep)


def lineage(path):
    """(marketplace, plugin, version, rel) for a real path inside the plugin cache, else None.
    rel is "" for a version root itself."""
    cache = cache_dir()
    if not isinstance(path, str) or not _under(path, cache):
        return None
    parts = path[len(cache) + 1:].split(os.sep)
    if len(parts) < 3 or any(p in ("", ".", "..") for p in parts):
        return None
    return parts[0], parts[1], parts[2], os.sep.join(parts[3:])


def live_lineage(d, root):
    """Lineage of a live dir <d> served from plugin root <root>, or None when carry-forward
    must not apply (root not cache-shaped, <d> outside <root>)."""
    root = os.path.realpath(root)
    d = os.path.realpath(d)
    rl = lineage(root)
    if rl is None or rl[3] != "":
        return None
    if d != root and not _under(d, root):
        return None
    dl = lineage(d)
    if dl is None or dl[:3] != rl[:3]:
        return None
    return dl


def entry_ok_kind(entry, shell):
    return isinstance(entry, dict) and (entry.get("kind") == "plugin-shell") == shell


def rejected_hash(ledger, h, shell):
    return any(
        entry_ok_kind(e, shell) and e.get("hash") == h and e.get("verdict") == "REJECT"
        for e in ledger.values()
    )


def sources(ledger, d, h, shell, root):
    """Ledger keys that can carry an approval to <d> (empty when carry-forward is off)."""
    ll = live_lineage(d, root)
    if ll is None:
        return []
    if bool(ll[3] == "") != shell:  # a shell is the root itself; a skill is below it
        return []
    if rejected_hash(ledger, h, shell):
        return []
    out = []
    for key, e in ledger.items():
        if not entry_ok_kind(e, shell) or e.get("hash") != h or e.get("verdict") not in OK_VERDICTS:
            continue
        if e.get("path", key) != key:
            continue  # an entry must describe its own key
        sl = lineage(key)
        if sl is None or sl[0] != ll[0] or sl[1] != ll[1] or sl[3] != ll[3] or sl[2] == ll[2]:
            continue
        out.append(key)
    return sorted(out)


def carried_member_verdicts(ledger, keys):
    mv = {}
    for k in keys:
        for m, v in ((ledger[k].get("member_verdicts") or {}).items()):
            if v == "REJECT":
                mv[m] = "REJECT"
    return mv


def check(ledger, d, h, mode, member="", root=""):
    shell = mode == "shell"
    entry = ledger.get(d)
    if entry is not None:
        if not entry_ok_kind(entry, shell):
            return "MISSING", None
        if entry.get("hash") != h:
            return "STALE", None
        if entry.get("verdict") == "REJECT":
            return "REJECTED", None
        # An entry recorded by approve.py --carry-forward was written by a tool, not reviewed:
        # it keeps the carry rule that a REJECT of the same bytes anywhere wins.
        if entry.get("carried_from") and rejected_hash(ledger, h, shell):
            return "REJECTED", None
        if shell and (entry.get("member_verdicts") or {}).get(member) == "REJECT":
            return "MEMBER_REJECTED", None
        if entry.get("verdict") in OK_VERDICTS:
            return "OK", None
        return "MISSING", None
    if not root:
        return "MISSING", None
    if rejected_hash(ledger, h, shell):
        return "REJECTED", None
    keys = sources(ledger, d, h, shell, root)
    if not keys:
        return "MISSING", None
    if shell and carried_member_verdicts(ledger, keys).get(member) == "REJECT":
        return "MEMBER_REJECTED", keys[0]
    return "CARRIED", keys[0]


def load(path):
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("ledger is not an object")
    return data


def main(argv):
    if len(argv) >= 6 and argv[1] == "check" and argv[5] in ("skill", "shell"):
        _, _, ledger_path, d, h, mode, *rest = argv
        member = rest[0] if len(rest) > 0 else ""
        root = rest[1] if len(rest) > 1 else ""
        try:
            ledger = load(ledger_path)
        except Exception:
            print("MISSING")
            return 0
        result, src = check(ledger, d, h, mode, member, root)
        print(result if src is None or result != "CARRIED" else f"{result} {src}")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
