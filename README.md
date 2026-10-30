# codeforge-tooling

Shared, **pinned** browser toolchain for CodeForge coders & QA.

## Why

Root cause **L-001**: coder and QA ran different/unpinned browser engines, so a
coder could not reproduce QA's results. `browser-check.sh` pins Chrome + axe +
Lighthouse so every coder can self-verify browser-dependent acceptance criteria
(responsive `@360/768/1024/1440`, axe a11y, Lighthouse) against **exactly** the
engine QA uses.

## Requirements

- The pinned Chrome for Testing binary (default path below)
- Matching `chromedriver` (only needed for axe + the screenshot fallback)
- `node`/`npx` (axe, Lighthouse), `python3` + `curl` (Lighthouse local-file shim,
  screenshot fallback)

## Usage

```bash
export CODEFORGE_OUT_DIR=.artifacts      # where reports/screenshots land (default: $PWD)

./browser-check.sh chrome                            # smoke test -> prints pinned version
./browser-check.sh screenshot page.html 360          # -> screenshot-page.html-360.png (360x900)
./browser-check.sh axe page.html                     # non-zero if any a11y violation
./browser-check.sh lighthouse page.html              # non-zero if a category score < threshold
```

Local files are supported without a server (bare paths **and** `file://` URLs;
for Lighthouse the file is transparently served over loopback because Lighthouse
rejects `file://` URLs).

Cold `npx` installs (first run on a host) are pre-warmed **outside** the
per-check timeout, so a first-time download can never be mistaken for a check
failure.

## Pinned versions / paths (override via env)

| Variable | Default | Notes |
|---|---|---|
| `CODEFORGE_CHROME_BIN` | `/home/adam/.cache/selenium/chrome/linux64/150.0.7871.24/chrome` | `--version` is validated; missing → clear error, non-zero exit |
| `CODEFORGE_CHROMEDRIVER` | `/home/adam/.cache/selenium/chromedriver/linux64/150.0.7871.46/chromedriver` | axe + screenshot fallback |
| `CODEFORGE_AXE_VERSION` | `4.10.2` | pin of the `@axe-core/cli` **CLI** (`npx @axe-core/cli@…`); no `4.10.3` CLI exists |
| `CODEFORGE_AXE_CORE_VERSION` | `4.10.3` | expected **bundled** `axe-core` engine version, asserted against the report (mismatch → exit 3) |
| `CODEFORGE_LIGHTHOUSE_VERSION` | `13.6.0` | `npx lighthouse@…` |
| `CODEFORGE_LIGHTHOUSE_MIN` | `0.90` | fails if the *lowest* category score is below this (set `0` to disable) |
| `CODEFORGE_LIGHTHOUSE_CATEGORIES` | `performance,accessibility,best-practices,seo` | |
| `CODEFORGE_OUT_DIR` | `$PWD` | report/screenshot output dir |
| `CODEFORGE_TIMEOUT` | `120` | per-tool wall-clock cap (seconds) |
| `CODEFORGE_NATIVE_TIMEOUT` | `25` | cap for the native `--screenshot` probe before fallback |
| `CODEFORGE_INSTALL_TIMEOUT` | `600` | budget for the one-off `npx` pre-warm download (kept out of `CODEFORGE_TIMEOUT`) |
| `CODEFORGE_TMP_DIR` | `/home/adam/.codeforge/tmp` | **short, fixed** Chrome temp root, independent of `CODEFORGE_OUT_DIR`; rejected at startup if a worst-case socket path would exceed ~108 bytes (L-008) |

## Exit codes

| Subcommand | 0 | non-zero |
|---|---|---|
| `chrome` | Chrome runs | Chrome missing/broken |
| `screenshot` | PNG written at `<width>x900` | capture failed |
| `axe` | no violations | `1` = ≥1 violation; `2` = crash (no/unreadable report) |
| `lighthouse` | all categories ≥ threshold | below threshold / no report |

## Tests

```bash
./tests/smoke.sh     # 13 assertions incl. a deliberate 'list' a11y violation
```

`tests/fixtures/violation.html` contains a known axe `list` violation
(`<a>` as a direct child of `<ul>`) and **must** make `axe` exit non-zero.

`CODEFORGE_OUT_DIR` is honoured if pre-set, so the same suite can be run against
a deliberately long out-dir (the L-008 regression case):

```bash
CODEFORGE_OUT_DIR=/home/adam/<very/long/path> ./tests/smoke.sh   # still 13/13
```

## Implementation notes

- **Short, fixed temp root (L-008).** Chrome's UNIX-domain `SingletonSocket`
  lives at `<profile-dir>/SingletonSocket` and is capped at ~108 bytes. The temp
  root is therefore a short, FIXED path (`CODEFORGE_TMP_DIR`), fully decoupled
  from `CODEFORGE_OUT_DIR`; a run-scoped subdir is created per invocation and its
  worst-case socket length is validated before Chrome starts. This is why a long
  out-dir can no longer trigger `FATAL: Socket path too long`.
- **Isolated Chrome profile.** Each invocation uses a fresh `--user-data-dir`
  under the run temp dir and `TMPDIR` is pointed there too, so concurrent
  coder/QA runs don't collide or exhaust the shared `/tmp`.
- **Process hygiene.** Every Chrome launched with our profile dir is reaped on
  exit, and the loopback static server is started in the *current* shell (never
  in a command substitution) so it is always killed by the `EXIT` trap — a leaked
  one-per-run server used to accumulate and starve the host of memory.
- **Screenshot fallback.** The native `--headless=new --screenshot` path is the
  primary route; where that path is broken on a host (aborts / hangs and writes
  nothing) `lib/capture.py` captures via the **same pinned chromedriver +
  Chrome** using the W3C WebDriver API and an exact `Emulation.
  setDeviceMetricsOverride` viewport.
