#!/bin/bash
# Fails if text contains local machine paths; this repository is public.
#   --staged  check lines added in the staged changes (pre-commit hook)
#   (none)    check every tracked file (before a push)
set -euo pipefail
# Built from pieces so this file does not match itself.
home="/Us""ers/[A-Za-z0-9._-]+/"
temp="/(private/)?var/fol""ders/|/private/t""mp/"
pattern="$home|$temp"
if [ "${1:-}" = "--staged" ]; then
  if git diff --cached -U0 --no-color | grep -E '^\+' | grep -v '^+++' | grep -nE "$pattern"; then
    echo "Staged changes add a local path (above). Use repo-relative paths or ~/." >&2
    exit 1
  fi
else
  if git grep -nE "$pattern"; then
    echo "Tracked files contain a local path (above)." >&2
    exit 1
  fi
fi
