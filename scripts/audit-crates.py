#!/usr/bin/env python3
"""Checks the crates Cargo.lock pins against the advisories OSV holds (RustSec's among them).
Exits 1 for an advisory that isn't listed below with why it doesn't reach RoamRun.
usage: audit-crates.py [Cargo.lock]"""
import json, re, sys, urllib.request

# Looked into, and why each doesn't apply. One that no longer matches is said, to be removed.
KNOWN = {
    # rsa's private-key operations leak timing (no fixed release). idevice brings rsa; its RSA
    # keys are in ca.rs, behind the `pair` feature, which isn't on here: remote pairing takes
    # only a random source and a signing trait from the crate (it signs with Ed25519).
    "RUSTSEC-2023-0071": "rsa: no RSA key is used (idevice's `pair` feature is off)",
}

def ask(url, body=None):
    request = urllib.request.Request(url, data=body and json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request, timeout=60))

lock = open(sys.argv[1] if len(sys.argv) > 1 else "Rust/RoamRunDevice/Cargo.lock").read()
crates = []
for block in lock.split("[[package]]")[1:]:
    field = lambda name: (re.search(rf'^{name} = "([^"]+)"', block, re.M) or [None, None])[1]
    if (field("source") or "").startswith("registry+"):   # ours and the pinned fork aren't on crates.io
        crates.append((field("name"), field("version")))
answer = ask("https://api.osv.dev/v1/querybatch",
             {"queries": [{"package": {"name": n, "ecosystem": "crates.io"}, "version": v} for n, v in crates]})
found = [(n, v, a["id"]) for (n, v), r in zip(crates, answer["results"]) for a in r.get("vulns", [])]
new = [f for f in found if f[2] not in KNOWN]
for name, version, advisory in found:
    summary = ask(f"https://api.osv.dev/v1/vulns/{advisory}").get("summary", "")
    print(f"{'known' if advisory in KNOWN else 'NEW'}: {name} {version}: {advisory} — {summary}")
    if advisory in KNOWN: print(f"       {KNOWN[advisory]}")
for advisory in sorted(set(KNOWN) - {f[2] for f in found}):
    print(f"no longer matches, remove it from KNOWN: {advisory}")
print(f"{len(crates)} crates checked, {len(new)} advisory(ies) not looked into")
sys.exit(1 if new else 0)
