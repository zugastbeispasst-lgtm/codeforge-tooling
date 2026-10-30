#!/usr/bin/env bash
#
# browser-check.sh — pinned, shared browser toolchain for CodeForge coders & QA.
#
# Root cause addressed: L-001 (version drift between coder and QA browser engines).
#
# Rework #1 (t_cd36368c) — fixes from QA-FAIL t_21d64cae:
#   1. (crit)  Chrome TMPDIR decoupled from CODEFORGE_OUT_DIR onto a short, FIXED
#              root (L-008). A long out-dir used to push Chrome's UNIX
#              SingletonSocket past ~108 bytes -> "Socket path too long" (signal 6).
#   2. (major) npx cold install is pre-warmed OUTSIDE the per-check timeout so a
#              first-run download can no longer masquerade as exit 124.
#   3. (minor) axe crash is now distinguishable from a real violation (report
#              presence + parse, not the ambiguous exit 1 alone).
#   4. (minor) file:// URLs are accepted by the lighthouse subcommand.
#   5. (minor) axe-core version pin is explicit and asserted against the report.
#   6. (minor) orphaned Chrome processes are reaped on cleanup.
#
# Usage:
#   browser-check.sh chrome [--version]              Smoke-test the pinned Chrome.
#   browser-check.sh screenshot <path-or-url> <width> Render a screenshot at <width>x900.
#   browser-check.sh axe <path-or-url>              Run axe a11y audit (non-zero on any violation).
#   browser-check.sh lighthouse <path-or-url>       Run Lighthouse (non-zero below score threshold).
#   browser-check.sh --help
#
# <path-or-url> accepts a bare filesystem path, a file:// URL, or an http(s) URL.
# Local files are transparently served over loopback for tools that reject file://.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned defaults (override via env — versions are NOT to be floated casually;
# drift here is exactly what broke QA in L-001).
# ---------------------------------------------------------------------------
DEFAULT_CHROME_BIN="/home/adam/.cache/selenium/chrome/linux64/150.0.7871.24/chrome"
DEFAULT_CHROMEDRIVER_BIN="/home/adam/.cache/selenium/chromedriver/linux64/150.0.7871.46/chromedriver"

# @axe-core/cli CLI pin. NOTE: there is no 4.10.3 CLI release; the 4.10.2 CLI
# bundles axe-core ~4.10.3. Both pins are kept explicit and the *bundled*
# axe-core version is asserted against the produced report (finding 5).
CODEFORGE_AXE_VERSION="${CODEFORGE_AXE_VERSION:-4.10.2}"
CODEFORGE_AXE_CORE_VERSION="${CODEFORGE_AXE_CORE_VERSION:-4.10.3}"
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
# Cold npx install gets its OWN generous budget, kept strictly OUT of
# CODEFORGE_TIMEOUT so a first-run download can't turn a healthy check into 124.
CODEFORGE_INSTALL_TIMEOUT="${CODEFORGE_INSTALL_TIMEOUT:-600}"
# Short, FIXED temp root, independent of CODEFORGE_OUT_DIR. Chrome's
# UNIX-domain SingletonSocket lives at <profile-dir>/SingletonSocket and is
# capped at ~108 bytes, so every temp path must stay short (L-008). Override
# only with another short root; the length is validated at startup.
CODEFORGE_TMP_DIR="${CODEFORGE_TMP_DIR:-/home/adam/.codeforge/tmp}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '[browser-check] %s\n' "$*" >&2; }
die() { printf '[browser-check] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'
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

# Refuse a temp root that would push Chrome's socket path over the ~108-byte
# UNIX-domain limit (L-008). Worst case is <root>/run.XXXXXX/p.XXXXXX/SingletonSocket.
validate_tmp_root() {
  local root="$1" worst len
  worst="${root}/run.XXXXXX/p.XXXXXX/SingletonSocket"
  len="${#worst}"
  if [ "$len" -gt 100 ]; then
    die "CODEFORGE_TMP_DIR='$root' is too long: worst-case Chrome socket path is ${len} bytes (limit ~108). Point CODEFORGE_TMP_DIR at a short fixed root such as /home/adam/.codeforge/tmp."
  fi
}

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

# Pre-install an npx package OUTSIDE the per-check timeout so a cold npm cache
# cannot masquerade as a check failure (rework #1, finding 2). Any argument
# after the package spec is used as a cheap "load the package" probe.
npx_prewarm() {
  local spec="$1"; shift
  local rc=0
  log "pre-warming npx '$spec' (install budget ${CODEFORGE_INSTALL_TIMEOUT}s, separate from check timeout)"
  set +e
  timeout "${CODEFORGE_INSTALL_TIMEOUT}" npx --yes "$spec" "$@" >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    log "npx '$spec' ready"
  else
    log "WARN: npx pre-warm of '$spec' exited $rc; check will still run (may use cache)"
  fi
}

# --- local static-server + run-scoped temp lifecycle ------------------------
SERVER_PID=""
SERVER_URL=""
SERVE_URL=""
RUN_TMP=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
  # Reap orphaned Chrome processes that survived a `timeout` kill of their
  # parent (they keep holding the user-data-dir) — rework #1, finding 6.
  if [ -n "$RUN_TMP" ]; then
    pkill -f "user-data-dir=${RUN_TMP}" 2>/dev/null || true
    if [ -d "$RUN_TMP" ]; then
      rm -rf "$RUN_TMP" 2>/dev/null || true
    fi
    RUN_TMP=""
  fi
}
cleanup_server() { cleanup; }

# Allocate an isolated Chrome user-data-dir under the SHORT run temp dir (never
# the shared/ cramped /tmp tmpfs, never the out-dir). Keep the leaf name tiny so
# the resulting socket path stays well under the ~108-byte limit.
make_profile_dir() {
  mktemp -d "${RUN_TMP}/p.XXXXXX"
}

# Start a loopback static server rooted at $1; block until reachable.
# Sets SERVER_PID in the CURRENT shell and stores the base URL in SERVER_URL.
# NOTE: callers must invoke this directly (never inside "$(...)"), otherwise the
# background server is parented by a subshell whose PID is lost and it leaks.
start_static_server() {
  local dir="$1"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to serve local files for Lighthouse."
  local port
  port="$(find_free_port)"
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir" >/dev/null 2>&1 &
  SERVER_PID=$!
  SERVER_URL="http://127.0.0.1:${port}"
  local i
  for i in $(seq 1 100); do
    if curl -sf -o /dev/null "${SERVER_URL}/"; then
      return 0
    fi
    kill -0 "$SERVER_PID" 2>/dev/null \
      || { SERVER_PID=""; die "local static server failed to start on port $port"; }
    sleep 0.1
  done
  SERVER_PID=""
  die "local static server did not become reachable"
}

# Serve a local file over loopback. Sets the global SERVE_URL (kept in the
# current shell so the server is reaped by the EXIT trap).
serve_local_file() {
  local target="$1" abs dir base enc
  case "$target" in
    file://*) abs="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1]))' "${target#file://}")" ;;
    *)        abs="$target" ;;
  esac
  abs="$(realpath -m -- "$abs")"
  [ -f "$abs" ] || die "local file not found: $abs (from '$target')"
  dir="$(dirname "$abs")"
  base="$(basename "$abs")"
  start_static_server "$dir"
  enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$base")"
  SERVE_URL="${SERVER_URL}/${enc}"
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
  local url out_name chromedriver profile report rc=0 nv=0 prc=0
  url="$(to_url "$target")"
  # axe-cli joins --save against --dir, so pass a basename + explicit out dir.
  out_name="axe-$(slug "$target").json"
  report="${CODEFORGE_OUT_DIR}/${out_name}"
  chromedriver="${CODEFORGE_CHROMEDRIVER:-$DEFAULT_CHROMEDRIVER_BIN}"
  [ -x "$chromedriver" ] || die "chromedriver not found/executable at '$chromedriver'. Set CODEFORGE_CHROMEDRIVER."
  # Isolated profile keeps concurrent/back-to-back runs from clashing on /tmp.
  profile="$(make_profile_dir)"

  # Separate the cold npx install from the check timeout (finding 2).
  npx_prewarm "@axe-core/cli@${CODEFORGE_AXE_VERSION}" --version

  log "axe $url (axe-core/cli@${CODEFORGE_AXE_VERSION}, axe-core@${CODEFORGE_AXE_CORE_VERSION})"
  rm -f "$report" 2>/dev/null || true
  # --exit makes axe exit non-zero when any violation is reported (stricter than
  # serious/critical-only and satisfies the L-001 acceptance bar).
  # Toggle -e off so we can capture the exit code instead of aborting.
  set +e
  timeout "${CODEFORGE_TIMEOUT}" npx --yes "@axe-core/cli@${CODEFORGE_AXE_VERSION}" "$url" \
    --chrome-path "$CHROME_BIN" \
    --chromedriver-path "$chromedriver" \
    --chrome-options="--headless=new,--no-sandbox,--disable-gpu,--user-data-dir=${profile}" \
    --dir "$CODEFORGE_OUT_DIR" \
    --save "$out_name" \
    --exit
  rc=$?
  set -e
  rm -rf "$profile" 2>/dev/null || true

  # Distinguish a real violation from a Chrome/driver crash: axe exits 1 in BOTH
  # cases, but only a genuine run writes a report (finding 3).
  if [ ! -s "$report" ]; then
    log "axe produced no report (exit $rc) — treating as CRASH, not a violation"
    return 2
  fi
  set +e
  nv="$(python3 "$SCRIPT_DIR/lib/axe_summary.py" "$report" "$CODEFORGE_AXE_CORE_VERSION")"
  prc=$?
  set -e
  if [ "$prc" -ne 0 ]; then
    log "axe report at $report is unusable (summary exit $prc) — treating as CRASH"
    return 2
  fi
  log "axe report -> $report (violations=$nv, axe-cli exit $rc)"
  if [ "$nv" -gt 0 ]; then return 1; fi
  return 0
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
      # Lighthouse v13 hard-rejects file:// URLs (bare paths AND file:// URLs),
      # so transparently serve the local file over loopback and audit that.
      serve_local_file "$target"
      url="$SERVE_URL"
      log "serving local file via loopback ($url) — Lighthouse rejects file:// URLs" ;;
  esac

  # Separate the cold npx install from the check timeout (finding 2).
  npx_prewarm "lighthouse@${CODEFORGE_LIGHTHOUSE_VERSION}" --version

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
  # Fixed, short temp root independent of CODEFORGE_OUT_DIR (L-008 / finding 1).
  local tmp_root="$CODEFORGE_TMP_DIR"
  mkdir -p "$tmp_root"
  validate_tmp_root "$tmp_root"
  RUN_TMP="$(mktemp -d "${tmp_root}/run.XXXXXX")"
  # Chrome + npx inherit a short TMPDIR so their UNIX sockets fit.
  export TMPDIR="$RUN_TMP"
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
