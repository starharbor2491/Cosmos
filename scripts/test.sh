#!/bin/zsh
# Runs `swift test`, retrying when the Command Line Tools toolchain flakes with
# "plugin for module 'TestingMacros' not found" (a swift-build bug seen with CLT-only installs; a plain rerun,
# or `rm -rf .build`, clears it). Usage: scripts/test.sh [swift test args...]
cd "${0:A:h}/.." || exit 1
for attempt in 1 2 3 4; do
  out=$(swift test "$@" 2>&1); rc=$?
  if print -r -- "$out" | grep -q "plugin for module 'TestingMacros' not found"; then
    echo "[test.sh] TestingMacros plugin flake (attempt $attempt), retrying..." >&2
    [[ $attempt == 3 ]] && rm -rf .build
    continue
  fi
  print -r -- "$out" | grep -v "ld: warning"
  exit $rc
done
echo "[test.sh] gave up after repeated TestingMacros plugin failures" >&2
exit 1
