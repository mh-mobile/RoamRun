#!/bin/sh
# textlint over the Japanese documents (.textlintrc.json): the shape of sentences, and marks of
# machine-written text. It can't tell a translated sentence from a written one: that takes a reader.
# Needs Node 20 or later; the versions are pinned here, and nothing is installed into the repository.
cd "$(dirname "$0")/.." || exit 1
[ $# -gt 0 ] || set -- README.ja.md Rust/roamrunctl/README.ja.md docs/*.ja.md
exec npx --yes -p textlint@15.8.0 \
    -p @textlint-ja/textlint-rule-preset-ai-writing@1.7.0 \
    -p textlint-rule-preset-ja-technical-writing@12.0.2 \
    textlint "$@"
