#!/usr/bin/env bash
# Every scenario ID in Specs/ must have a TanStack test and a Kouch test, and vice versa.
set -euo pipefail
cd "$(dirname "$0")/.."

ids() { grep -rhoE '\[[a-z]+-[0-9]{3}\]' "$@" | sort -u; }

spec=$(ids Specs)
ts=$(ids Conformance/tanstack/tests)
swift=$(ids Tests/KouchTests)

status=0
report() {
  local missing
  missing=$(comm -23 <(echo "$1") <(echo "$2"))
  if [[ -n "$missing" ]]; then
    echo "Missing in $3:"; echo "$missing" | sed 's/^/  /'
    status=1
  fi
}
report "$spec" "$ts" "Conformance/tanstack"
report "$spec" "$swift" "Tests/KouchTests"
report "$ts" "$spec" "Specs (TS test without spec)"
report "$swift" "$spec" "Specs (Swift test without spec)"

[[ $status -eq 0 ]] && echo "Parity OK: $(echo "$spec" | wc -l | tr -d ' ') scenarios in Specs, TanStack and Kouch."
exit $status
