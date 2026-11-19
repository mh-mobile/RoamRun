#!/bin/sh
# view's page (Rust/roamrunctl/src/view.html) in a headless Chromium, its WebSocket, VideoDecoder and clock made up:
# what it sends and shows for what the server sends (scripts/page-check.cjs). No server, no device.
# Needs Node 20 or later. Playwright's version is pinned here; it goes to a folder of its own (PAGE_CHECK_DIR),
# its browser to Playwright's usual place, nothing into the repository. PAGE_CHECK_DEPS=1 also installs the
# browser's system libraries (Linux, as CI runs it).
cd "$(dirname "$0")/.." || exit 1
dir=${PAGE_CHECK_DIR:-${TMPDIR:-/tmp}/roamrun-page-check}
mkdir -p "$dir" || exit 1
npm install --silent --no-audit --no-fund --prefix "$dir" playwright@1.64.1 || exit 1
"$dir/node_modules/.bin/playwright" install ${PAGE_CHECK_DEPS:+--with-deps} chromium || exit 1
NODE_PATH="$dir/node_modules" exec node scripts/page-check.cjs "$@"
