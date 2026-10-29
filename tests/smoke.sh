#!/usr/bin/env bash
#
# smoke.sh — executable acceptance evidence for browser-check.sh (L-001).
#
# Runs the pinned toolchain against local fixtures and asserts exit codes +
# artifacts. This is the DoD §1.1 "Beleg statt Behauptung" proof.
#
# Usage: tests/smoke.sh        (exit 0 = all checks pass)
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BC="$ROOT/browser-check.sh"
FIX="$HERE/fixtures"
OUT="$HERE/.artifacts"
export CODEFORGE_OUT_DIR="$OUT"
rm -rf "$OUT"; mkdir -p "$OUT"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ # check <desc> <expected-rc> <actual-rc>
  if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else bad "$1 (expected exit $2, got $3)"; fi
}

echo "== 1. chrome smoke =="
"$BC" chrome >"$OUT/chrome-version.log" 2>&1; check "chrome --version" 0 $?
cat "$OUT/chrome-version.log" | sed 's/^/    /'

echo "== 2. axe: known 'list' violation MUST fail =="
"$BC" axe "$FIX/violation.html" >"$OUT/axe-violation.log" 2>&1; rc=$?
check "axe violation -> non-zero" 1 "$rc"
axe_violation_report=$(ls "$OUT"/axe-*violation.html.json 2>/dev/null | head -1)
grep -q '"id": *"list"' "$axe_violation_report" 2>/dev/null \
  && ok "report contains rule 'list'" || bad "report missing rule 'list'"

echo "== 3. axe: clean page MUST pass =="
"$BC" axe "$FIX/clean.html" >"$OUT/axe-clean.log" 2>&1; check "axe clean -> zero" 0 $?

echo "== 4. screenshots @360/768/1024/1440 =="
for w in 360 768 1024 1440; do
  "$BC" screenshot "$FIX/clean.html" "$w" >/dev/null 2>&1; rc=$?
  shot=$(ls "$OUT"/screenshot-*clean.html-${w}.png 2>/dev/null | head -1)
  if [ "$rc" = 0 ] && [ -n "$shot" ] && [ -s "$shot" ]; then ok "screenshot ${w}x900"; else bad "screenshot ${w}x900 (exit $rc)"; fi
done

echo "== 5. lighthouse on local file (file:// shimmed via loopback) =="
"$BC" lighthouse "$FIX/clean.html" >"$OUT/lighthouse.log" 2>&1; check "lighthouse -> zero" 0 $?
lh_report=$(ls "$OUT"/lighthouse-*clean.html.json 2>/dev/null | head -1)
[ -n "$lh_report" ] && [ -s "$lh_report" ] \
  && ok "lighthouse JSON report produced" || bad "lighthouse JSON report missing"

echo "== 6. lighthouse threshold gate MUST fail below min =="
CODEFORGE_LIGHTHOUSE_MIN=0.99 "$BC" lighthouse "$FIX/clean.html" >"$OUT/lighthouse-high.log" 2>&1
check "lighthouse below threshold -> non-zero" 1 $?

echo "== 7. missing Chrome -> clear error, non-zero =="
CODEFORGE_CHROME_BIN=/nonexistent/chrome "$BC" chrome >"$OUT/missing-chrome.log" 2>&1
check "missing chrome -> non-zero" 1 $?
grep -q "not found" "$OUT/missing-chrome.log" && ok "error message names the missing binary" || bad "unclear error message"

echo
echo "----------------------------------------"
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
echo "artifacts: $OUT"
[ "$fail" -eq 0 ]
