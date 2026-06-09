#!/usr/bin/env bash
#
# Stage all changes, commit with the standard Co-Authored-By trailer (no GPG
# prompt), AND push. One approvable command — do NOT chain `&& git push` onto it
# (that's a separate command and would re-prompt every time; the push lives here).
#
#   tools/commit.sh "<commit message>"
#
# The message may be multi-line (quote it). Review this script once, then approve
# `tools/commit.sh` and future commit+push won't re-prompt.
set -euo pipefail

MSG="${1:?usage: tools/commit.sh \"message\"}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

git -C "$ROOT" add -A
git -C "$ROOT" -c commit.gpgsign=false commit \
  -m "$MSG" \
  -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git -C "$ROOT" push
