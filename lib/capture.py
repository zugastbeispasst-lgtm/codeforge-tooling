#!/usr/bin/env python3
"""
capture.py — dependency-free headless-Chrome screenshot capture via WebDriver.

Used by browser-check.sh as a fallback when Chrome's native
`--headless=new --screenshot=...` CLI path produces no image (observed on hosts
where that path aborts). Drives the SAME pinned chromedriver + Chrome binary via
the W3C WebDriver REST API, so the rendering engine is identical to QA's axe run.

Usage:
  capture.py --chrome BIN --chromedriver BIN --url URL --width W [--height H] --out PATH
"""
import argparse
import base64
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def http(method: str, url: str, payload=None, timeout: int = 90):
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode()
    return json.loads(body) if body else {}


def wait_ready(base: str, timeout: int) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            http("GET", f"{base}/status", timeout=5)
            return
        except (urllib.error.URLError, OSError):
            time.sleep(0.1)
    raise SystemExit("capture.py: chromedriver did not become ready")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--chrome", required=True)
    ap.add_argument("--chromedriver", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, default=900)
    ap.add_argument("--out", required=True)
    ap.add_argument("--timeout", type=int, default=90)
    args = ap.parse_args()

    for label, path in (("chrome", args.chrome), ("chromedriver", args.chromedriver)):
        if not os.access(path, os.X_OK):
            raise SystemExit(f"capture.py: {label} not executable: {path}")

    port = free_port()
    base = f"http://127.0.0.1:{port}"
    driver = subprocess.Popen(
        [args.chromedriver, f"--port={port}", "--log-path=/dev/null"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    session_id = None
    try:
        wait_ready(base, 30)
        caps = {
            "capabilities": {
                "alwaysMatch": {
                    "browserName": "chrome",
                    "goog:chromeOptions": {
                        "binary": args.chrome,
                        "args": [
                            "--headless=new",
                            "--no-sandbox",
                            "--disable-gpu",
                            "--hide-scrollbars",
                            f"--window-size={args.width},{args.height}",
                        ],
                    },
                }
            }
        }
        resp = http("POST", f"{base}/session", caps, timeout=60)
        session_id = resp["value"]["sessionId"]
        # Pin the exact viewport. window/rect sets the *outer* window (viewport
        # ends up ~143px shorter), so prefer the CDP device-metrics override;
        # fall back to window/rect on drivers that don't expose it.
        try:
            http("POST", f"{base}/session/{session_id}/chromium/send_command",
                 {"cmd": "Emulation.setDeviceMetricsOverride",
                  "params": {"width": args.width, "height": args.height,
                             "deviceScaleFactor": 1, "mobile": False}},
                 timeout=30)
        except Exception:
            try:
                http("POST", f"{base}/session/{session_id}/window/rect",
                     {"width": args.width, "height": args.height}, timeout=30)
            except Exception:
                pass
        http("POST", f"{base}/session/{session_id}/url", {"url": args.url}, timeout=60)
        shot = http("GET", f"{base}/session/{session_id}/screenshot", timeout=args.timeout)
        png = base64.b64decode(shot["value"])
        if not png.startswith(b"\x89PNG"):
            raise SystemExit("capture.py: response was not a PNG")
        with open(args.out, "wb") as fh:
            fh.write(png)
        print(f"capture.py: wrote {len(png)} bytes -> {args.out}", file=sys.stderr)
        return 0
    finally:
        if session_id:
            try:
                http("DELETE", f"{base}/session/{session_id}", timeout=10)
            except Exception:
                pass
        driver.terminate()
        try:
            driver.wait(timeout=10)
        except subprocess.TimeoutExpired:
            driver.kill()


if __name__ == "__main__":
    sys.exit(main())
