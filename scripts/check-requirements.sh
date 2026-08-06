#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [requirements-file]" >&2
  exit 2
fi

requirements_file="${1:-"$REPO/requirements.txt"}"
if [ ! -f "$requirements_file" ]; then
  echo "error: requirements file not found: $requirements_file" >&2
  exit 1
fi

installed=0
missing=0
total=0

printf '%-40s %-10s %s\n' "SOFTWARE" "STATUS" "LOCATION"
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line="${raw_line%%#*}"
  read -r requirement extra <<< "$line"
  [ -n "${requirement:-}" ] || continue
  if [ -n "${extra:-}" ]; then
    echo "error: each requirement must be one executable name: $raw_line" >&2
    exit 2
  fi

  total=$((total + 1))
  if location="$(command -v "$requirement" 2>/dev/null)"; then
    installed=$((installed + 1))
    printf '%-40s %-10s %s\n' "$requirement" "installed" "$location"
  else
    missing=$((missing + 1))
    printf '%-40s %-10s %s\n' "$requirement" "missing" "-"
  fi
done < "$requirements_file"

if [ "$total" -eq 0 ]; then
  echo "error: requirements file contains no software entries: $requirements_file" >&2
  exit 2
fi

printf 'Summary: %s installed, %s missing\n' "$installed" "$missing"
