#!/usr/bin/env python3
"""Map Claude Code plugin names to the on-disk directories the gate controls.

Two sources, both read fresh on every call:
  installed  ~/.claude/plugins/installed_plugins.json  (every entry's installPath, all
             marketplaces and scopes: the Skill/Agent name carries no marketplace)
  synced     ~/.claude/plugins/synced/<account>/manifest.json  (claude.ai-synced plugins)

A synced plugin's live directory is <account>/<manifest name>, or <manifest name>~g<N>
when the manifest gives it generation N > 1. Older generations left on disk are not
loaded by Claude Code and are not returned. A synced plugin's name is the "name" in its
.claude-plugin/plugin.json (falling back to the manifest name).

A name can have more than one root (several install dirs, installed and also synced,
synced under two accounts). Every root is returned, installed first; the gate requires
each of them to be approved, so an ambiguous name can only be stricter, never looser.

Usage:
  plugin-index.py roots <plugin>     every root, one per line. Exit codes:
                                       0  found; every listed root is present
                                       1  not an installed or synced plugin
                                       2  installed_plugins.json is unreadable, or the name
                                          is listed there with a missing install dir
                                          (the gate denies: fail closed)
  plugin-index.py find <root> <member> <skill|command|agent>
                                     the member's real skill dir or .md file; exit 1 if none
  plugin-index.py list               "<plugin>\\t<root>" for every root of every plugin
  plugin-index.py members <root>     "<skill|command|agent>\\t<member>" for every member
"""
import json
import os
import re
import sys

HOME = os.path.expanduser("~")
INSTALLED = os.path.join(HOME, ".claude", "plugins", "installed_plugins.json")
SYNCED = os.path.join(HOME, ".claude", "plugins", "synced")

DEFAULT_DIRS = {"skill": "skills", "command": "commands", "agent": "agents"}


class Broken(Exception):
    """installed_plugins.json unreadable, or a listed install dir missing."""


def real(p):
    return os.path.realpath(p)


def plugin_json(root):
    p = os.path.join(root, ".claude-plugin", "plugin.json")
    try:
        with open(p) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def installed_roots(only=None):
    """(name, root) for installed plugins. Raises Broken as resolve-skill.sh 0.3.0 did."""
    if not os.path.isfile(INSTALLED):
        return []
    try:
        with open(INSTALLED) as f:
            data = json.load(f)
        plugins = data.get("plugins") or {}
        if not isinstance(plugins, dict):
            raise ValueError
    except Exception:
        raise Broken
    out = []
    for key, entries in plugins.items():
        name = key.split("@", 1)[0]
        if only is not None and name != only:
            continue
        listed_ok = False
        for e in entries or []:
            p = (e or {}).get("installPath") or ""
            if not p or not os.path.isdir(p):
                if only is not None:
                    raise Broken
                continue
            out.append((name, real(p)))
            listed_ok = True
        if only is not None and not listed_ok:
            raise Broken
    return out


def synced_roots():
    out = []
    try:
        accounts = sorted(os.listdir(SYNCED))
    except OSError:
        return out
    for acct in accounts:
        account = os.path.join(SYNCED, acct)
        try:
            with open(os.path.join(account, "manifest.json")) as f:
                plugins = json.load(f).get("plugins") or []
        except Exception:
            continue
        for p in plugins if isinstance(plugins, list) else []:
            if not isinstance(p, dict):
                continue
            mname = p.get("name") or ""
            if not isinstance(mname, str) or not mname or "/" in mname or mname in (".", ".."):
                continue
            try:
                gen = int(p.get("generation") or 1)
            except (TypeError, ValueError):
                continue
            d = os.path.join(account, mname + (f"~g{gen}" if gen > 1 else ""))
            if not os.path.isdir(d):
                continue
            name = plugin_json(d).get("name") or mname
            out.append((name, real(d)))
    return out


def dedup(rows):
    seen, out = set(), []
    for r in rows:
        if r not in seen:
            seen.add(r)
            out.append(r)
    return out


def member_dirs(root, kind):
    """Directories (or single .md files) holding members of this kind: plugin.json's
    "skills"/"commands"/"agents" paths (inside the plugin only), then the default dir."""
    out = []
    val = plugin_json(root).get(DEFAULT_DIRS[kind])
    vals = [val] if isinstance(val, str) else (val if isinstance(val, list) else [])
    for v in vals:
        if isinstance(v, str):
            p = os.path.normpath(os.path.join(root, v))
            if p == root or p.startswith(root + os.sep):
                out.append(p)
    default = os.path.join(root, DEFAULT_DIRS[kind])
    if default not in out:
        out.append(default)
    return out


def walk(root, maxdepth, prune_skills):
    """Like `find <root> -maxdepth <maxdepth> [-path <root>/skills -prune]`: yields
    (dirpath, dirnames, filenames) with entries at depth <= maxdepth."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        depth = 0 if dirpath == root else dirpath[len(root):].count(os.sep)
        if prune_skills and dirpath == root and "skills" in dirnames:
            dirnames.remove("skills")
        yield dirpath, list(dirnames), sorted(filenames)
        if depth + 1 >= maxdepth:  # children's contents would be deeper than maxdepth
            dirnames[:] = []


NAME_RE = re.compile(r"^name:[ \t]*(.*?)[ \t]*$")


def frontmatter_name(path):
    """First `name:` line, quotes stripped (same as the 0.3.0 gate's awk)."""
    try:
        with open(path, errors="replace") as f:
            for line in f:
                m = NAME_RE.match(line.rstrip("\n"))
                if m:
                    return m.group(1).replace('"', "").replace("'", "").rstrip(" \t")
    except OSError:
        pass
    return None


def find(root, member, kind):
    rel = member.replace(":", "/")
    base = member.rsplit(":", 1)[-1]
    for d in member_dirs(root, kind):
        if kind == "skill":
            cand = os.path.join(d, rel)
            if os.path.isfile(os.path.join(cand, "SKILL.md")):
                return real(cand)
        else:
            if os.path.isfile(d) and d.endswith(".md") and os.path.basename(d)[:-3] == rel:
                return real(d)
            cand = os.path.join(d, rel + ".md")
            if os.path.isfile(cand):
                return real(cand)
    # 0.3.0 fallbacks: a skill dir named <base> holding a SKILL.md up to 4 levels deep;
    # a */commands/<member>.md or */agents/<member>.md up to 3 levels deep outside skills/.
    if kind == "skill":
        for dirpath, dirnames, _ in walk(root, 4, False):
            for dn in dirnames:
                cand = os.path.join(dirpath, dn)
                if dn == base and os.path.isfile(os.path.join(cand, "SKILL.md")):
                    return real(cand)
        return None
    suffix = os.sep + DEFAULT_DIRS[kind] + os.sep + rel + ".md"
    md_files = []
    for dirpath, _, filenames in walk(root, 3, True):
        for fn in filenames:
            cand = os.path.join(dirpath, fn)
            if cand.endswith(suffix) and os.path.isfile(cand):
                return real(cand)
            if fn.endswith(".md") and os.path.basename(dirpath) == DEFAULT_DIRS[kind]:
                md_files.append(cand)
    if kind == "agent":
        # Claude Code may name an agent by its frontmatter name: rather than its file.
        candidates = []
        for d in member_dirs(root, "agent"):
            if os.path.isfile(d) and d.endswith(".md"):
                candidates.append(d)
            elif os.path.isdir(d):
                candidates += [os.path.join(d, n) for n in sorted(os.listdir(d)) if n.endswith(".md")]
        for f in candidates + md_files:
            if os.path.isfile(f) and frontmatter_name(f) == base:
                return real(f)
    return None


def members(root):
    out = []
    for kind in ("skill", "command", "agent"):
        names = set()
        for d in member_dirs(root, kind):
            if kind == "skill":
                if os.path.isdir(d):
                    names.update(n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n, "SKILL.md")))
            elif os.path.isfile(d) and d.endswith(".md"):
                names.add(os.path.basename(d)[:-3])
            elif os.path.isdir(d):
                names.update(n[:-3] for n in os.listdir(d) if n.endswith(".md") and os.path.isfile(os.path.join(d, n)))
        out += [(kind, n) for n in sorted(names)]
    return out


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "roots" and len(argv) == 3:
        try:
            rows = installed_roots(argv[2])
        except Broken:
            return 2
        rows += [r for r in synced_roots() if r[0] == argv[2]]
        roots = dedup(r for _, r in rows)
        for r in roots:
            print(r)
        return 0 if roots else 1
    if cmd == "find" and len(argv) == 5 and argv[4] in DEFAULT_DIRS:
        hit = find(real(argv[2]), argv[3], argv[4])
        if hit:
            print(hit)
            return 0
        return 1
    if cmd == "list" and len(argv) == 2:
        try:
            rows = installed_roots()
        except Broken:
            rows = []
        for n, r in dedup(rows + synced_roots()):
            print(f"{n}\t{r}")
        return 0
    if cmd == "members" and len(argv) == 3:
        for k, n in members(real(argv[2])):
            print(f"{k}\t{n}")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
