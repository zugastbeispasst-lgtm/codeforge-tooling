#!/usr/bin/env python3
"""Selbsttest für scripts/codeforge_retro_scan.py (D-022/L-026).

Prüft die Acceptance Criteria gegen eine KOPIE des echten Boards + synthetische
Ereignisse. Berührt weder das Produktions-Board noch das Produktions-State-File.
"""
import importlib.util
import io
import json
import os
import sqlite3
import sys
import tempfile
from contextlib import redirect_stdout

REPO_SCAN = "/home/adam/codeforge/tooling/scripts/codeforge_retro_scan.py"
REAL_DB = "/home/adam/.hermes/kanban/boards/codeforge/kanban.db"

_failures = []


def check(name, cond, extra=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name}" + (f"  {extra}" if extra else ""))
    if not cond:
        _failures.append(name)


def load_scan(db, state, argv):
    os.environ["CODEFORGE_KANBAN_DB"] = db
    os.environ["CODEFORGE_RETRO_STATE"] = state
    spec = importlib.util.spec_from_file_location(f"retro_scan_{id(db)}_{id(state)}", REPO_SCAN)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    sys.argv = ["codeforge_retro_scan.py"] + argv
    return mod


def copy_db(dst):
    src = sqlite3.connect(REAL_DB)
    con = sqlite3.connect(dst)
    with con:
        src.backup(con)
    src.close()
    con.close()


def max_run_id(db):
    con = sqlite3.connect(db)
    v = con.execute("SELECT COALESCE(MAX(id),0) FROM task_runs").fetchone()[0]
    con.close()
    return v


def max_event_id(db):
    con = sqlite3.connect(db)
    v = con.execute("SELECT COALESCE(MAX(id),0) FROM task_events").fetchone()[0]
    con.close()
    return v


def synth_block_event(db, task_id, reason, assignee="coder-a", status="blocked", title="SYNTH"):
    con = sqlite3.connect(db)
    with con:
        con.execute(
            "INSERT INTO tasks (id,title,assignee,status,created_at) VALUES (?,?,?,?,0)",
            (task_id, title, assignee, status),
        )
        cur = con.execute(
            "INSERT INTO task_events (task_id,run_id,kind,payload,created_at) "
            "VALUES (?,?,?,?,0)",
            (task_id, None, "blocked", json.dumps({"reason": reason})),
        )
        eid = cur.lastrowid
    con.close()
    return eid


def synth_child(db, parent_id, child_id, child_status="todo"):
    con = sqlite3.connect(db)
    with con:
        con.execute("INSERT INTO tasks (id,title,assignee,status,created_at) VALUES (?,?,?,?,0)",
                    (child_id, f"CHILD {child_id}", "qa", child_status))
        con.execute("INSERT INTO task_links (parent_id,child_id) VALUES (?,?)", (parent_id, child_id))
    con.close()


def run_capture(mod, argv):
    sys.argv = ["codeforge_retro_scan.py"] + argv
    buf = io.StringIO()
    with redirect_stdout(buf):
        try:
            mod.main()
            err = None
        except SystemExit as e:
            err = e
    return buf.getvalue(), err


def fresh_state(path, db, with_event_cursor=False):
    st = {"last_run_id": max_run_id(db)}
    if with_event_cursor:
        st["last_event_id"] = max_event_id(db)
    with open(path, "w") as f:
        json.dump(st, f)


def main():
    tmp = tempfile.mkdtemp(prefix="retro_scan_test_")

    # AC1 — Baseline: Kopie echten Boards, frischer State (last_run_id=MAX,
    # last_event_id fehlt -> Bootstrap). Kein Signal, t_e1b4c36a feuert nicht nach.
    db = os.path.join(tmp, "ac1.db"); copy_db(db)
    st = os.path.join(tmp, "ac1.state.json"); fresh_state(st, db, with_event_cursor=False)
    out, err = run_capture(load_scan(db, st, ["--dry-run"]), ["--dry-run"])
    check("AC1 Baseline: kein Signal", out.strip() == "" and err is None,
          f"out={out.strip()!r}")

    # AC2 — neuer block-Event (id>Cursor) mit 'awaiting-adam: ...' -> KEIN Signal
    db = os.path.join(tmp, "ac2.db"); copy_db(db)
    st = os.path.join(tmp, "ac2.state.json"); fresh_state(st, db, with_event_cursor=True)
    synth_block_event(db, "t_syn_a", "awaiting-adam: brauche Adam-Entscheid zur Policy")
    out, _ = run_capture(load_scan(db, st, ["--dry-run"]), ["--dry-run"])
    check("AC2 awaiting-adam: kein Block-Signal", "blockierte Tasks" not in out,
          f"out={out.strip()!r}")

    # AC2b — Synonym escalation-required ebenfalls kein Signal
    db = os.path.join(tmp, "ac2b.db"); copy_db(db)
    st = os.path.join(tmp, "ac2b.state.json"); fresh_state(st, db, with_event_cursor=True)
    synth_block_event(db, "t_syn_b", "escalation-required: CEO-Entscheid nötig")
    out, _ = run_capture(load_scan(db, st, ["--dry-run"]), ["--dry-run"])
    check("AC2b escalation-required: kein Block-Signal", "blockierte Tasks" not in out,
          f"out={out.strip()!r}")

    # AC3 — neuer block-Event OHNE Handoff-Präfix -> Signal "1 blockierte Tasks"
    db = os.path.join(tmp, "ac3.db"); copy_db(db)
    st = os.path.join(tmp, "ac3.state.json"); fresh_state(st, db, with_event_cursor=True)
    synth_block_event(db, "t_syn_c", "brauche DB-Creds")
    out, _ = run_capture(load_scan(db, st, ["--dry-run"]), ["--dry-run"])
    check("AC3 echter Blocker: Signal gezaehlt", "1 blockierte Tasks" in out,
          f"out={out.strip()!r}")

    # AC4 — review-required-Block MIT wartendem Kind -> §1.4-Bruch feuert weiter
    db = os.path.join(tmp, "ac4.db"); copy_db(db)
    st = os.path.join(tmp, "ac4.state.json"); fresh_state(st, db, with_event_cursor=True)
    synth_block_event(db, "t_syn_d", "review-required: PR #99 braucht Review")
    synth_child(db, "t_syn_d", "t_syn_d_child", child_status="todo")
    out, _ = run_capture(load_scan(db, st, ["--dry-run"]), ["--dry-run"])
    check("AC4 review-required MIT Kind: §1.4-Bruch-Signal", "§1.4-Bruch" in out,
          f"out={out.strip()!r}")

    # AC4b — review-required-Block OHNE Kind -> kein Signal (normaler Handoff)
    db = os.path.join(tmp, "ac4b.db"); copy_db(db)
    st = os.path.join(tmp, "ac4b.state.json"); fresh_state(st, db, with_event_cursor=True)
    synth_block_event(db, "t_syn_e", "review-required: PR #100 braucht Review")
    out, _ = run_capture(load_scan(db, st, ["--dry-run"]), ["--dry-run"])
    check("AC4b review-required OHNE Kind: kein Signal", out.strip() == "",
          f"out={out.strip()!r}")

    # AC5a — stiller Pfad persistiert last_event_id (Normal-Lauf, kein Signal)
    db = os.path.join(tmp, "ac5.db"); copy_db(db)
    st = os.path.join(tmp, "ac5.state.json"); fresh_state(st, db, with_event_cursor=False)
    synth_block_event(db, "t_syn_f", "awaiting-adam: warte auf Adam")  # kein Signal
    mod = load_scan(db, st, [])
    fake = FakeRun()
    mod.subprocess.run = fake
    run_capture(mod, [])
    saved = json.load(open(st))
    check("AC5a stiller Pfad persistiert last_event_id",
          saved.get("last_event_id", -1) == max_event_id(db),
          f"saved={saved}")

    # AC5b — zwei aufeinanderfolgende Scans ohne neuen Block -> beide still,
    # erster Scan im Signal-Pfad persistiert den Cursor.
    db = os.path.join(tmp, "ac5b.db"); copy_db(db)
    st = os.path.join(tmp, "ac5b.state.json"); fresh_state(st, db, with_event_cursor=True)
    synth_block_event(db, "t_syn_g", "brauche DB-Creds")  # echtes Signal
    mod = load_scan(db, st, [])
    mod.subprocess.run = FakeRun()
    out1, _ = run_capture(mod, [])
    saved1 = json.load(open(st))
    check("AC5b Scan1 Signal-Pfad persistiert Cursor",
          saved1.get("last_event_id", -1) == max_event_id(db),
          f"saved={saved1}")
    # zweiter Scan, nichts Neues -> still
    out2, _ = run_capture(load_scan(db, st, []), ["--dry-run"])
    check("AC5b Scan2 still (kein Wiederhol-Signal)", out2.strip() == "",
          f"out={out2.strip()!r}")

    print()
    if _failures:
        print(f"RESULT: FAIL ({len(_failures)}): {', '.join(_failures)}")
        sys.exit(1)
    print("RESULT: PASS (alle Checks gruen)")


class FakeRun:
    """Stub für subprocess.run: verhindert echte Board-Mutationen in Tests."""
    def __call__(self, *a, **k):
        class R:
            returncode = 0
            stdout = '{"id": "t_fake"}'
            stderr = ""
        return R()


if __name__ == "__main__":
    main()
