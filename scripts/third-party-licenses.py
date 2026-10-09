#!/usr/bin/env python3
"""Writes the licenses of the Rust crates one of ours is built from (stdout).
Reads `cargo metadata` on stdin; the crates' sources must be fetched (a build does that).
usage: third-party-licenses.py [what is built from them]   (default: RoamRun's device control)"""
import json, os, sys

m = json.load(sys.stdin)
TOP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")   # paths are said from the repository's top
SUBJECT = sys.argv[1] if len(sys.argv) > 1 else "RoamRun's device control"
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
        bare.append(f'{name} ({p["license"]}, {p["repository"] or "crates.io"})')
    for f in files:
        with open(f, encoding="utf-8", errors="replace") as text:
            body = "\n".join(line.rstrip() for line in text.read().strip().splitlines())
            # The same words laid out differently (indentation, http or https in its links) are one text.
            same = " ".join(body.replace("http://", "https://").split())
            where = f"packaged without a text: see {os.path.relpath(os.path.dirname(kept), TOP)}" if f == kept else os.path.dirname(os.path.relpath(f, folder))
            texts.setdefault(same, [body, []])[1].append(f'{name} ({p["license"]})' + (f", in {where}" if where and f != kept else f", {where}" if where else ""))

# Every crate with its text: one without is put in licenses/ by hand, not passed over.
if bare:
    sys.exit("no license text for: " + "; ".join(bare) + f" — add {os.path.relpath(os.path.dirname(packages[root]['manifest_path']), TOP)}/licenses/<crate name>.txt")

print(f"{SUBJECT} is built from these Rust crates, each under the license it names")
print("(one of them, where it offers a choice). Their texts follow.")
print(f"\n{len(used)} crates. Made by scripts/third-party-licenses.py (make licenses); don't edit.\n")
# Lines no license text has, so where one ends can't be mistaken.
for text, names in sorted(texts.values(), key=lambda t: (t[1][0], t[0])):
    print("\n" + "#" * 80)
    print("\n".join(names))
    print("#" + "-" * 79)
    print(text)
