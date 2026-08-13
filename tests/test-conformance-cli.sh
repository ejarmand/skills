#!/usr/bin/env bash
# Cheap interface checks for the live conformance harness. The provider probes
# themselves consume authenticated sessions and remain manual.
set -u -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
HARNESS="$REPO/tests/conformance-profiles.sh"

out="$("$HARNESS" opencode 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || { echo "error: missing-argument exit was $rc, want 2" >&2; exit 1; }
case "$out" in
  *'<claude|codex|cursor|opencode|all|'*) ;;
  *) echo "error: conformance usage does not advertise opencode" >&2; exit 1 ;;
esac

bash -n "$HARNESS" || exit 1
echo "conformance CLI advertises opencode and parses cleanly"
