#!/usr/bin/env python3
"""Checks the crates the Cargo.lock files pin against the advisories OSV holds (RustSec's among them).
Exits 1 for an advisory that isn't listed below with why it doesn't reach RoamRun.
usage: audit-crates.py [Cargo.lock …]   (both crates' by default)"""
import json, re, sys, urllib.request

# Looked into, and why each doesn't apply. One that no longer matches is said, to be removed.
KNOWN = {
    # rsa's private-key operations leak timing (no fixed release). idevice brings rsa; its RSA
    # keys are in ca.rs, behind the `pair` feature, which isn't on here: remote pairing takes
    # only a random source and a signing trait from the crate (it signs with Ed25519).
    "RUSTSEC-2023-0071": "rsa: no RSA key is used (idevice's `pair` feature is off)",
    # Unmaintained, not unsound. A proc-macro's helper that age's messages (i18n-embed-fl) bring in:
    # it runs when roamrunctl is built, and nothing of it is in the binary.
    "RUSTSEC-2026-0173": "proc-macro-error2: build-time only (a proc-macro under age), not in the binary",
}

def ask(url, body=None):
    request = urllib.request.Request(url, data=body and json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request, timeout=60))

crates = []
for path in sys.argv[1:] or ["Rust/RoamRunDevice/Cargo.lock", "Rust/roamrunctl/Cargo.lock"]:
    for block in open(path).read().split("[[package]]")[1:]:
        field = lambda name: (re.search(rf'^{name} = "([^"]+)"', block, re.M) or [None, None])[1]
        # Ours aren't on crates.io. The pinned fork is asked about by its crate's name and version:
        # it is that release and a few commits. A crate both pin is asked about once.
        if (field("source") or "").startswith(("registry+", "git+")) and (field("name"), field("version")) not in crates:
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
