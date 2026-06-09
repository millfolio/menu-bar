#!/usr/bin/env bash
#
# Stage all changes and commit with the standard Co-Authored-By trailer, without
# a GPG-signing prompt. One approvable command instead of an ad-hoc `git add` +
# `git -c commit.gpgsign=false commit -m …` each time.
#
#   tools/commit.sh "<commit message>"
#
# The message may be multi-line (quote it). Review this script once, then approve
# `tools/commit.sh` and future commits won't re-prompt.
set -euo pipefail

MSG="${1:?usage: tools/commit.sh \"message\"}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

git -C "$ROOT" add -A
git -C "$ROOT" -c commit.gpgsign=false commit \
  -m "$MSG" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
