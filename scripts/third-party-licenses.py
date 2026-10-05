#!/usr/bin/env python3
"""Writes the licenses of the Rust crates device control is built from (stdout).
Reads `cargo metadata` on stdin; the crates' sources must be fetched (a build does that)."""
import json, os, sys

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
texts, bare = {}, []
for p in sorted((packages[i] for i in used), key=lambda p: (p["name"], p["version"])):
    name = f'{p["name"]} {p["version"]}'
    folder = os.path.dirname(p["manifest_path"])
    # Below its top too: a crate can carry others' code, with their license beside it.
    files = sorted(os.path.join(at, f) for at, _, found in os.walk(folder) for f in found if f.upper().startswith(NAMES))
    # A crate packaged without its license: the text from its repository, kept in licenses/.
    kept = os.path.join(os.path.dirname(packages[root]["manifest_path"]), "licenses", p["name"] + ".txt")
    if not files and os.path.isfile(kept):
        files = [kept]
    if not files:
        bare.append(f'{name} — {p["license"]} — {", ".join(p["authors"]) or "its authors"} — {p["repository"] or "crates.io"}')
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as text:
            body = "\n".join(line.rstrip() for line in text.read().strip().splitlines())
            # The same words laid out differently (indentation, http or https in its links) are one text.
            same = " ".join(body.replace("http://", "https://").split())
            inside = os.path.dirname(os.path.relpath(f, folder)) if f != kept else ""
            texts.setdefault(same, [body, []])[1].append(f'{name} ({p["license"]})' + (f", in {inside}" if inside else ""))

print("RoamRun's device control is built from these Rust crates, each under the license it names")
print("(one of them, where it offers a choice). Their texts follow.")
print(f"\n{len(used)} crates. Made by scripts/third-party-licenses.py (make licenses); don't edit.\n")
if bare:
    print("Published without a license text, in the crate or its repository; under the license named:\n")
    print("\n".join(f"  {b}" for b in bare))
# Lines no license text has, so where one ends can't be mistaken.
for text, names in sorted(texts.values(), key=lambda t: (t[1][0], t[0])):
    print("\n" + "#" * 80)
    print("\n".join(names))
    print("#" + "-" * 79)
    print(text)
