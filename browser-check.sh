#!/usr/bin/env bash
#
# browser-check.sh — pinned, shared browser toolchain for CodeForge coders & QA.
#
# Root cause addressed: L-001 (version drift between coder and QA browser engines).
# This script pins Chrome + axe + Lighthouse so any coder can self-verify
# browser-dependent acceptance criteria (responsive @360/768/1024/1440, a11y, perf)
# with exactly the same engine QA uses.
#
# Usage:
#   browser-check.sh chrome [--version]              Smoke-test the pinned Chrome.
#   browser-check.sh screenshot <path-or-url> <width> Render a screenshot at <width>x900.
#   browser-check.sh axe <path-or-url>              Run axe a11y audit (non-zero on any violation).
#   browser-check.sh lighthouse <path-or-url>       Run Lighthouse (non-zero below score threshold).
#   browser-check.sh --help
#
# Local HTML is supported without a server: bare paths are converted to file:// URLs.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned defaults (override via env — versions are NOT to be floated casually;
# drift here is exactly what broke QA in L-001).
# ---------------------------------------------------------------------------
DEFAULT_CHROME_BIN="/home/adam/.cache/selenium/chrome/linux64/150.0.7871.24/chrome"
DEFAULT_CHROMEDRIVER_BIN="/home/adam/.cache/selenium/chromedriver/linux64/150.0.7871.46/chromedriver"

CODEFORGE_AXE_VERSION="${CODEFORGE_AXE_VERSION:-4.10.2}"
CODEFORGE_LIGHTHOUSE_VERSION="${CODEFORGE_LIGHTHOUSE_VERSION:-13.6.0}"
CODEFORGE_LIGHTHOUSE_MIN="${CODEFORGE_LIGHTHOUSE_MIN:-0.90}"
CODEFORGE_LIGHTHOUSE_CATEGORIES="${CODEFORGE_LIGHTHOUSE_CATEGORIES:-performance,accessibility,best-practices,seo}"
CODEFORGE_OUT_DIR="${CODEFORGE_OUT_DIR:-$PWD}"
# Hard per-tool wall-clock cap so a starving/loaded host yields a deterministic
# failure instead of hanging the coder's shell forever.
CODEFORGE_TIMEOUT="${CODEFORGE_TIMEOUT:-120}"
# Shorter cap for the native --screenshot probe so a broken native path falls
# through to the WebDriver capture quickly instead of eating the full timeout.
CODEFORGE_NATIVE_TIMEOUT="${CODEFORGE_NATIVE_TIMEOUT:-25}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '[browser-check] %s\n' "$*" >&2; }
die() { printf '[browser-check] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# Resolve and validate the Chrome binary; exports CHROME_BIN.
resolve_chrome() {
  CHROME_BIN="${CODEFORGE_CHROME_BIN:-$DEFAULT_CHROME_BIN}"
  [ -e "$CHROME_BIN" ] || die "Chrome binary not found at '$CHROME_BIN'. Set CODEFORGE_CHROME_BIN to a valid Chrome path."
  [ -x "$CHROME_BIN" ] || die "Chrome binary at '$CHROME_BIN' is not executable."
  "$CHROME_BIN" --version >/dev/null 2>&1 \
    || die "Chrome at '$CHROME_BIN' failed to execute '--version' (corrupt or wrong arch?)."
  export CHROME_BIN
  export CHROME_PATH="$CHROME_BIN"   # honour by chrome-launcher (Lighthouse)
}

# Convert a bare filesystem path to an absolute file:// URL; pass URLs through.
to_url() {
  local t="$1"
  case "$t" in
    http://*|https://*|file://*) printf '%s' "$t" ;;
    *) printf 'file://%s' "$(realpath -m -- "$t")" ;;
  esac
}

# Deterministic, filesystem-safe slug derived from the target.
slug() {
  printf '%s' "$1" \
    | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' \
    | sed -e 's#[^A-Za-z0-9._-]#-#g' \
    | cut -c1-80
}

ensure_out_dir() { mkdir -p "$CODEFORGE_OUT_DIR"; }

# Find an ephemeral free TCP port on loopback.
find_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# --- local static-server lifecycle (Lighthouse refuses file:// URLs) --------
SERVER_PID=""
TEMP_ROOT=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  if [ -n "$TEMP_ROOT" ] && [ -d "$TEMP_ROOT" ]; then
    rm -rf "$TEMP_ROOT" 2>/dev/null || true
    TEMP_ROOT=""
  fi
}
cleanup_server() { cleanup; }

# Allocate an isolated Chrome user-data-dir under TEMP_ROOT (on the workspace
# disk, NOT the shared/ cramped /tmp tmpfs — contention there caused
# "failed to write prefs file" and EDQUOT under concurrent coder+QA runs).
make_profile_dir() {
  mktemp -d "${TEMP_ROOT}/chrome-profile.XXXXXX"
}

# Start a loopback static server rooted at $1; block until reachable.
# Sets SERVER_PID; prints the base URL.
start_static_server() {
  local dir="$1"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to serve local files for Lighthouse."
  local port
  port="$(find_free_port)"
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir" >/dev/null 2>&1 &
  SERVER_PID=$!
  local i
  for i in $(seq 1 100); do
    if curl -sf -o /dev/null "http://127.0.0.1:${port}/"; then
      printf '%s' "http://127.0.0.1:${port}"
      return 0
    fi
    kill -0 "$SERVER_PID" 2>/dev/null \
      || { SERVER_PID=""; die "local static server failed to start on port $port"; }
    sleep 0.1
  done
  SERVER_PID=""
  die "local static server did not become reachable"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_chrome() {
  resolve_chrome
  printf 'CHROME_BIN=%s\n' "$CHROME_BIN"
  "$CHROME_BIN" --version
}

cmd_screenshot() {
  [ $# -eq 2 ] || die "usage: browser-check.sh screenshot <path-or-url> <width>"
  local target="$1" width="$2"
  [[ "$width" =~ ^[0-9]+$ ]] || die "width must be an integer (px), got '$width'"
  resolve_chrome
  ensure_out_dir
  local url out profile chromedriver rc=0
  url="$(to_url "$target")"
  out="${CODEFORGE_OUT_DIR}/screenshot-$(slug "$target")-${width}.png"
  profile="$(make_profile_dir)"
  chromedriver="${CODEFORGE_CHROMEDRIVER:-$DEFAULT_CHROMEDRIVER_BIN}"

  # Primary path: Chrome's native headless screenshot CLI (as specified for the
  # responsive ACs). Some hosts have a broken native capture path (it aborts and
  # writes nothing) while the WebDriver path renders fine, so we fall back.
  set +e
  timeout "${CODEFORGE_NATIVE_TIMEOUT}" "$CHROME_BIN" \
    --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
    "--user-data-dir=${profile}" \
    "--screenshot=${out}" \
    "--window-size=${width},900" \
    "$url" >/dev/null 2>&1
  rc=$?
  set -e
  rm -rf "$profile" 2>/dev/null || true

  if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
    log "native --screenshot failed (exit $rc); falling back to WebDriver capture"
    [ -x "$chromedriver" ] || die "screenshot fallback needs chromedriver at '$chromedriver' (set CODEFORGE_CHROMEDRIVER)"
    python3 "$SCRIPT_DIR/lib/capture.py" \
      --chrome "$CHROME_BIN" --chromedriver "$chromedriver" \
      --url "$url" --width "$width" --height 900 \
      --out "$out" --timeout "${CODEFORGE_TIMEOUT}" \
      || die "screenshot capture failed for $url at ${width}x900 (native + WebDriver)"
  fi

  [ -s "$out" ] || die "screenshot not produced at $out (Chrome may have been OOM-killed on a loaded host; retry or raise CODEFORGE_TIMEOUT)"
  log "screenshot ${width}x900 -> $out"
  printf '%s\n' "$out"
}

cmd_axe() {
  [ $# -eq 1 ] || die "usage: browser-check.sh axe <path-or-url>"
  local target="$1"
  resolve_chrome
  ensure_out_dir
  local url out_name chromedriver profile
  url="$(to_url "$target")"
  # axe-cli joins --save against --dir, so pass a basename + explicit out dir.
  out_name="axe-$(slug "$target").json"
  chromedriver="${CODEFORGE_CHROMEDRIVER:-$DEFAULT_CHROMEDRIVER_BIN}"
  [ -x "$chromedriver" ] || die "chromedriver not found/executable at '$chromedriver'. Set CODEFORGE_CHROMEDRIVER."
  # Isolated profile keeps concurrent/back-to-back runs from clashing on /tmp.
  profile="$(make_profile_dir)"

  log "axe $url (axe-core/cli@${CODEFORGE_AXE_VERSION})"
  # --exit makes axe exit non-zero when any violation is reported (stricter than
  # serious/critical-only and satisfies the L-001 acceptance bar).
  # Toggle -e off so we can capture the violation exit code instead of aborting.
  set +e
  timeout "${CODEFORGE_TIMEOUT}" npx --yes "@axe-core/cli@${CODEFORGE_AXE_VERSION}" "$url" \
    --chrome-path "$CHROME_BIN" \
    --chromedriver-path "$chromedriver" \
    --chrome-options="--headless=new,--no-sandbox,--disable-gpu,--user-data-dir=${profile}" \
    --dir "$CODEFORGE_OUT_DIR" \
    --save "$out_name" \
    --exit
  local rc=$?
  set -e
  rm -rf "$profile" 2>/dev/null || true
  log "axe report -> ${CODEFORGE_OUT_DIR}/${out_name} (exit $rc)"
  return $rc
}

cmd_lighthouse() {
  [ $# -eq 1 ] || die "usage: browser-check.sh lighthouse <path-or-url>"
  local target="$1"
  resolve_chrome
  ensure_out_dir
  local url out rc=0

  case "$target" in
    http://*|https://*)
      url="$target" ;;
    *)
      # Lighthouse v13 hard-rejects file:// URLs, so transparently serve the
      # local file over loopback HTTP and audit that instead.
      local abs dir base enc server_base
      abs="$(realpath -m -- "$target")"
      [ -f "$abs" ] || die "lighthouse: local file not found: $abs"
      dir="$(dirname "$abs")"
      base="$(basename "$abs")"
      server_base="$(start_static_server "$dir")"
      enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$base")"
      url="${server_base}/${enc}"
      log "serving $abs via loopback ($url) — Lighthouse rejects file:// URLs" ;;
  esac

  out="${CODEFORGE_OUT_DIR}/lighthouse-$(slug "$target").json"
  log "lighthouse $url (lighthouse@${CODEFORGE_LIGHTHOUSE_VERSION}, min score ${CODEFORGE_LIGHTHOUSE_MIN})"
  set +e
  timeout "${CODEFORGE_TIMEOUT}" npx --yes "lighthouse@${CODEFORGE_LIGHTHOUSE_VERSION}" "$url" \
    --chrome-flags="--headless=new --no-sandbox --disable-gpu" \
    --only-categories="$CODEFORGE_LIGHTHOUSE_CATEGORIES" \
    --output=json \
    --output-path="$out" \
    --quiet
  rc=$?
  set -e
  cleanup_server

  [ -s "$out" ] || die "lighthouse did not produce a report at $out (lighthouse exit $rc)"
  log "lighthouse report -> $out"

  # Threshold gate: compare the minimum category score (0..1) against the threshold.
  node - "$out" "$CODEFORGE_LIGHTHOUSE_MIN" <<'NODE'
const fs = require('fs');
const [reportPath, minStr] = process.argv.slice(2);
const min = parseFloat(minStr);
const rep = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
const cats = rep.categories || {};
let worst = null, worstName = null;
for (const [name, c] of Object.entries(cats)) {
  if (typeof c.score !== 'number') continue;
  if (worst === null || c.score < worst) { worst = c.score; worstName = name; }
}
if (worst === null) { console.error('[browser-check] no category scores found in report'); process.exit(2); }
console.error(`[browser-check] scores: ${Object.entries(cats).map(([n,c])=>`${n}=${c.score===null?'n/a':Math.round(c.score*100)}`).join(' ')}`);
if (min > 0 && worst < min) {
  console.error(`[browser-check] FAIL: lowest category '${worstName}' = ${(worst*100).toFixed(0)} < threshold ${(min*100).toFixed(0)}`);
  process.exit(1);
}
console.error(`[browser-check] OK: lowest category '${worstName}' = ${(worst*100).toFixed(0)} >= threshold ${(min*100).toFixed(0)}`);
NODE
}

# ---------------------------------------------------------------------------
main() {
  # Keep Chrome's profile/temp on the workspace disk, not the shared /tmp tmpfs.
  TEMP_ROOT="${CODEFORGE_TMP_DIR:-$CODEFORGE_OUT_DIR/.chrome-tmp}"
  mkdir -p "$TEMP_ROOT"
  export TMPDIR="$TEMP_ROOT"
  trap cleanup EXIT
  [ $# -ge 1 ] || usage 1
  local sub="$1"; shift
  case "$sub" in
    chrome|--version|-v|-V) cmd_chrome "$@" ;;
    screenshot)              cmd_screenshot "$@" ;;
    axe)                     cmd_axe "$@" ;;
    lighthouse|lh)           cmd_lighthouse "$@" ;;
    -h|--help|help)          usage 0 ;;
    *) die "unknown subcommand '$sub' (expected: chrome | screenshot | axe | lighthouse)" ;;
  esac
}

main "$@"
