#!/usr/bin/env python3
"""The tests a `swift test` log shows as started and not finished: for a run that hangs, where
the test process's stacks say nothing of tests that are only waiting.

    python3 scripts/unfinished-tests.py test.log
"""
import re, sys

log = open(sys.argv[1], errors="replace").read()
name = r"([A-Za-z0-9_]+\([^)]*\))"
started = re.findall(rf"Test {name} started", log)
ended = set(re.findall(rf"Test {name}(?: with \d+ test cases?)? (?:passed|failed|skipped)", log))
left = [t for t in dict.fromkeys(started) if t not in ended]
print(f"{len(started)} tests started, {len(left)} not finished:")
for t in left:
    print(" ", t)
