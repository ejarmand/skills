#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d -t skills-requirements-test-XXXXXX)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/scripts"
cp "$REPO/scripts/check-requirements.sh" "$test_root/scripts/check-requirements.sh"

present_command="skills-requirement-present"
missing_command="skills-requirement-deliberately-missing"
printf '#!/usr/bin/env bash\nexit 0\n' > "$test_root/bin/$present_command"
chmod +x "$test_root/bin/$present_command"
printf '%s\n' \
  '# One executable per line; comments are allowed.' \
  "$present_command # supplied by this test" \
  "$missing_command # intentionally absent" \
  > "$test_root/requirements.txt"

output="$(PATH="$test_root/bin:$PATH" bash "$test_root/scripts/check-requirements.sh")"

printf '%s\n' "$output" | grep -Eq "^${present_command}[[:space:]]+installed[[:space:]]+$test_root/bin/$present_command$"
printf '%s\n' "$output" | grep -Eq "^${missing_command}[[:space:]]+missing[[:space:]]+-$"
printf '%s\n' "$output" | grep -Fqx 'Summary: 1 installed, 1 missing'

echo "reported installed and missing software from the requirements manifest"
