#!/usr/bin/env python3
"""Writes the licenses of the Rust crates device control is built from (stdout).
Reads `cargo metadata` on stdin; the crates' sources must be fetched (a build does that)."""
import collections, json, os, sys

m = json.load(sys.stdin)
packages = {p["id"]: p for p in m["packages"]}
nodes = {n["id"]: n for n in m["resolve"]["nodes"]}
root = m["resolve"]["root"]
# What a build uses, its build scripts and macros included; not what only tests need.
used, queue = set(), [root]
while queue:
    i = queue.pop()
    if i in used:
        continue
    used.add(i)
    queue += [d["pkg"] for d in nodes[i]["deps"] if any(k["kind"] in (None, "build") for k in d["dep_kinds"])]
used.discard(root)

NAMES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "UNLICENSE")
texts, bare = collections.defaultdict(list), []
for p in sorted((packages[i] for i in used), key=lambda p: (p["name"], p["version"])):
    name = f'{p["name"]} {p["version"]}'
    folder = os.path.dirname(p["manifest_path"])
    files = sorted(f for f in os.listdir(folder) if f.upper().startswith(NAMES) and os.path.isfile(os.path.join(folder, f)))
    if not files:
        bare.append(f'{name} — {p["license"]} — {p["repository"] or "crates.io"}')
    for f in files:
        with open(os.path.join(folder, f), encoding="utf-8", errors="replace") as text:
            texts["\n".join(line.rstrip() for line in text.read().strip().splitlines())].append(f'{name} ({p["license"]})')

print("RoamRun's device control is built from these Rust crates, each under the license it names")
print("(one of them, where it offers a choice). Their texts follow.")
print(f"\n{len(used)} crates. Made by scripts/third-party-licenses.py (make licenses); don't edit.\n")
if bare:
    print("Without a license file in the crate; under the license named:\n")
    print("\n".join(f"  {b}" for b in bare))
for text, names in sorted(texts.items(), key=lambda t: (t[1][0], t[0])):
    print("\n" + "=" * 80)
    print("\n".join(names))
    print("-" * 80)
    print(text)
