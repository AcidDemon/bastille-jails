#!/usr/local/bin/python3.12
# Claude Code builds git@github.com: from a "github" marketplace source, and the jail has no ssh key.
import json
import os

HOME = os.path.expanduser("~")
FILES = [
    f"{HOME}/.claude/settings.json",
    f"{HOME}/.claude/plugins/known_marketplaces.json",
]


def to_https(src):
    if src.get("source") != "github":
        return False
    repo = src.get("repo", "")
    if not repo or repo.startswith("anthropics/"):
        return False
    src.pop("repo")
    src["source"] = "git"
    src["url"] = f"https://github.com/{repo}.git"
    return True


total = 0
for path in FILES:
    if not os.path.exists(path):
        print(f"skip {path}")
        continue

    with open(path) as fh:
        data = json.load(fh)

    entries = data.get("extraKnownMarketplaces", data)
    hits = 0
    for name, entry in entries.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("source"), dict):
            continue
        if to_https(entry["source"]):
            hits += 1
            print(f"  {name} -> {entry['source']['url']}")

    if hits:
        with open(path, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
    print(f"{path}: {hits} rewritten")
    total += hits

print(f"{total} total")
