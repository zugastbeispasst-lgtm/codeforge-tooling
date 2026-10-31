#!/usr/bin/env python3
"""CodeForge improvement-loop watchdog.

Scans the `codeforge` kanban board for quality signals since the last run
(failed runs, blocked tasks, rework cycles, QA-FAIL verdicts). If there is
something to learn, it creates ONE `hr` retro task and prints a notice.
If there is nothing, it prints nothing -> the cron stays silent.

Designed to run as a no_agent cron job (empty stdout == no message).

Datenquellen (v2, D-022/L-026):
- Lauf-Signale (fehlgeschlagene Läufe, Rework, QA-FAIL) werden weiterhin per
  State-Cursor `last_run_id` über `task_runs` abgegrenzt.
- Block-Signale werden NICHT mehr zustandsbasiert über `tasks.status='blocked'`
  gezählt, sondern ereignisbasiert über block-ÜBERGÄNGE in `task_events`
  (`kind='blocked' AND id > last_event_id`). Ein dauerhaft offenes Ticket kann so
  keinen wiederkehrenden Retro-Trigger mehr erzeugen (Familie D-018/D-019/D-022).
- Intendierte Human-Handoffs (Block-Reason mit Präfix `review-required`,
  `awaiting-adam` oder `escalation-required`) sind KEIN Block-Signal.
"""
import json
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone

BOARD = "codeforge"
# A3 (D-022/L-026): DB-/State-Pfad per Env überschreibbar (Testbarkeit); Defaults
# bleiben unverändert -> Produktion unberührt.
DEFAULT_DB = "/home/adam/.hermes/kanban/boards/codeforge/kanban.db"
DEFAULT_STATE = "/home/adam/.codeforge/retro_state.json"
DB = os.environ.get("CODEFORGE_KANBAN_DB", DEFAULT_DB)
STATE = os.environ.get("CODEFORGE_RETRO_STATE", DEFAULT_STATE)
HERMES_BIN = "/home/adam/.hermes/hermes-agent/venv/bin/hermes"
HERMES_CWD = "/home/adam/.hermes/hermes-agent"

# Operating Manual §1.4/§2.6: ein Block, dessen reason mit einem dieser Präfixe
# beginnt, ist ein NORMALER Handoff an einen Menschen (Review bzw. Eskalation an
# Adam/CEO) — KEIN echter Blocker, also weder "blockierte Tasks"-Signal noch
# Retro-Trigger.
#   - review-required      : PR/Artefakt fertig, braucht nur noch eine Review-Abnahme
#                            (nur zulässig ohne QA-Kindkarte, §1.4).
#   - awaiting-adam        : intendierte Eskalation, die auf einen Adam/CEO-Entscheid
#                            wartet (kanonische Konvention, CEO-Entscheid 2026-10-31).
#   - escalation-required  : Synonym zu awaiting-adam.
HUMAN_HANDOFF_PREFIXES = ("review-required", "awaiting-adam", "escalation-required")

# §1.4-Bruch-Prüfung bleibt AUSSCHLIESSLICH auf `review-required` beschränkt:
# ein `awaiting-adam`-Block MIT wartenden Kindern ist erlaubt/intendiert.
REVIEW_REQUIRED_PREFIX = "review-required"


def is_review_required(reason):
    """§1.4: normaler Review-Handoff (nur ohne QA-Kindkarte)."""
    return (reason or "").strip().lower().startswith(REVIEW_REQUIRED_PREFIX)


def is_human_handoff_ok(reason):
    """True, wenn der Block-Reason ein intendierter Human-Handoff ist.

    Verallgemeinert is_review_required() um die Eskalations-Präfixe
    `awaiting-adam` / `escalation-required` (A1, D-022/L-026). Solche Blocks
    zählen NICHT als Block-Signal. Die §1.4-Bruch-Prüfung verwendet weiterhin
    ausschließlich is_review_required().
    """
    r = (reason or "").strip().lower()
    return any(r.startswith(p) for p in HUMAN_HANDOFF_PREFIXES)


def is_qa_fail(summary, metadata):
    """EXACT QA-FAIL detection (D-018 / L-022).

    SQLite's LIKE is case-insensitive for ASCII, so a pattern like
    '%verdict%FAIL%' also matches a *PASS* row that merely contains the
    substring "fail" anywhere after "verdict" (e.g. `"tests_failed": 0`).
    That produced phantom "QA-FAILs" from PASS verdicts (runs 50 + 64).
    Parse the structured verdict instead, and only fall back to a
    case-SENSITIVE summary match.
    """
    try:
        verdict = (json.loads(metadata or "{}") or {}).get("verdict")
        if isinstance(verdict, str) and verdict.strip().upper() == "FAIL":
            return True
    except Exception:
        pass
    # case-sensitive: 'verdict: FAIL' (not 'verdict: PASS ... tests_failed')
    return bool(re.search(r"verdict:\s*FAIL\b", summary or ""))


def block_reason(cur, task_id):
    """Latest block reason for a task, from the event log (agent-readable)."""
    row = cur.execute(
        "SELECT payload FROM task_events WHERE task_id=? AND kind='blocked' "
        "ORDER BY id DESC LIMIT 1",
        (task_id,),
    ).fetchone()
    if row and row["payload"]:
        try:
            return json.loads(row["payload"]).get("reason") or ""
        except Exception:
            return ""
    return ""


def event_reason(payload):
    """Reason aus einem task_events-Payload (JSON) ziehen, defensiv."""
    try:
        return (json.loads(payload or "{}") or {}).get("reason") or ""
    except Exception:
        return ""


def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except Exception:
        return {"last_run_id": 0}


def save_state(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "w") as f:
        json.dump(state, f)


def main():
    if not os.path.exists(DB):
        return  # board not present -> nothing to do, stay silent
    state = load_state()
    last = int(state.get("last_run_id", 0))

    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    cur = con.cursor()

    # A2: Block-Signale sind Ereignisse, kein Dauerzustand. Fehlt der Cursor
    # `last_event_id` (Bootstrap, Bestands-State), initialisieren wir ihn auf
    # MAX(task_events.id): so feuern historische Blocks (z. B. die
    # Adam-Eskalation t_e1b4c36a, event id=562) NICHT rückwirkend nach.
    if "last_event_id" not in state:
        last_event_id = cur.execute(
            "SELECT COALESCE(MAX(id),0) FROM task_events"
        ).fetchone()[0]
    else:
        last_event_id = int(state.get("last_event_id", 0))

    # D-019 / L-022: `reclaimed` = the run was reclaimed via a lock
    # reclaim (infra/operator action, e.g. manual_reclaim) and re-spawned — it is
    # NOT an agent failure. Only genuine non-completed outcomes count as "failed".
    fails = cur.execute(
        "SELECT id, task_id, profile, outcome, summary, error FROM task_runs "
        "WHERE id > ? AND outcome IS NOT NULL AND outcome != 'completed' "
        "AND outcome != 'reclaimed'",
        (last,),
    ).fetchall()
    reclaimed = cur.execute(
        "SELECT id, task_id, profile, error FROM task_runs "
        "WHERE id > ? AND outcome = 'reclaimed'",
        (last,),
    ).fetchall()

    # A2: block-ÜBERGÄNGE seit dem Cursor (ereignisbasiert). Verknüpft mit
    # `tasks` (titel/assignee) und reason aus dem Event-Payload. Intendierte
    # Human-Handoffs (is_human_handoff_ok) werden ausgeschlossen.
    blocked_events = cur.execute(
        "SELECT e.id AS event_id, e.task_id, e.payload, t.title, t.assignee "
        "FROM task_events e LEFT JOIN tasks t ON t.id = e.task_id "
        "WHERE e.kind='blocked' AND e.id > ? ORDER BY e.id",
        (last_event_id,),
    ).fetchall()
    blocked = []
    for e in blocked_events:
        reason = event_reason(e["payload"])
        if is_human_handoff_ok(reason):
            continue  # §1.4/§2.6: intendierter Handoff, KEIN Block-Signal
        blocked.append({"id": e["task_id"], "assignee": e["assignee"], "reason": reason})

    # D-022/L-026: `blocked_raw` dient NUR NOCH der §1.4-Bruch-Prüfung
    # (unverändertes Verhalten) — nicht mehr dem "blockierte Tasks"-Signal.
    blocked_raw = cur.execute(
        "SELECT id, title, assignee, last_failure_error FROM tasks WHERE status='blocked'"
    ).fetchall()
    # a run that ended in outcome='blocked' because of a human handoff is
    # likewise not a failure signal
    fails = [
        f for f in fails
        if not (f["outcome"] == "blocked" and is_human_handoff_ok(block_reason(cur, f["task_id"])))
    ]
    # D-020 / L-006 (recurrence): a coding card blocked `review-required` while a
    # QA child card is still waiting = §1.4 breach — the child can never promote
    # from a blocked parent, so the pipeline stalls. That is NOT a "normal
    # handoff": it IS a signal (and an escalation trigger for the retro).
    # WICHTIG: bleibt ausschließlich auf `review-required` beschränkt.
    blocked_with_child = []
    for b in blocked_raw:
        reason = block_reason(cur, b["id"]) or (b["last_failure_error"] or "")
        if not is_review_required(reason):
            continue
        kids = cur.execute(
            "SELECT c.id, c.status FROM task_links l JOIN tasks c ON c.id = l.child_id "
            "WHERE l.parent_id = ? AND c.status NOT IN ('done', 'archived')",
            (b["id"],),
        ).fetchall()
        if kids:
            blocked_with_child.append(
                {"id": b["id"], "assignee": b["assignee"], "reason": reason,
                 "children": [f"{k['id']}({k['status']})" for k in kids]}
            )
    # D-019 / L-022: a "rework cycle" is a dedicated REWORK card (house
    # convention: title starts with "REWORK"), NOT merely a task that happened to
    # run more than once. Re-runs after a reclaim or a review-required->resume
    # cycle were being mis-counted as rework.
    rework = cur.execute(
        "SELECT id, title FROM tasks WHERE UPPER(title) LIKE 'REWORK%' "
        "AND id IN (SELECT DISTINCT task_id FROM task_runs WHERE id > ?)",
        (last,),
    ).fetchall()
    # D-018 / L-022: exact QA-FAIL detection (see is_qa_fail) — SQLite LIKE is
    # case-insensitive and matched PASS rows containing "fail" (e.g. tests_failed).
    cand = cur.execute(
        "SELECT id, task_id, summary, metadata FROM task_runs WHERE id > ?",
        (last,),
    ).fetchall()
    qa_fail = [c for c in cand if is_qa_fail(c["summary"], c["metadata"])]
    new_max = cur.execute("SELECT COALESCE(MAX(id),0) FROM task_runs").fetchone()[0]
    # A2: Cursor für Block-Ereignisse am Laufende -> wird in JEDEM Pfad persistiert.
    new_max_events = cur.execute(
        "SELECT COALESCE(MAX(id),0) FROM task_events"
    ).fetchone()[0]
    con.close()

    signals = []
    if fails:
        signals.append(f"{len(fails)} fehlgeschlagene Läufe")
    if blocked:
        signals.append(f"{len(blocked)} blockierte Tasks")
    if blocked_with_child:
        signals.append(
            f"{len(blocked_with_child)} review-required-Blocks MIT wartendem Kind (§1.4-Bruch)"
        )
    if rework:
        signals.append(f"{len(rework)} Rework-Zyklen")
    if qa_fail:
        signals.append(f"{len(qa_fail)} QA-FAILs")

    if os.environ.get("RETRO_FORCE_SIGNAL") and not signals:
        signals = ["(forced test signal)"]

    if not signals:
        save_state({"last_run_id": new_max, "last_event_id": new_max_events})
        return  # SILENT — nothing to report

    detail = []
    for f in fails[:10]:
        detail.append(
            f"- Lauf {f['id']} ({f['profile']}) outcome={f['outcome']}: "
            f"{(f['error'] or f['summary'] or '')[:160]}"
        )
    for b in blocked[:10]:
        detail.append(f"- BLOCKED {b['id']} ({b['assignee']}): {(b['reason'] or '')[:160]}")
    for b in blocked_with_child[:10]:
        detail.append(
            f"- §1.4-BRUCH {b['id']} ({b['assignee']}): review-required-Block, aber "
            f"wartendes Kind {', '.join(b['children'])} -> Pipeline stallt. "
            f"Reason: {(b['reason'] or '')[:120]}"
        )
    for r in rework[:10]:
        detail.append(f"- REWORK {r['id']}: {(r['title'] or '')[:140]}")
    for q in qa_fail[:10]:
        detail.append(f"- QA-FAIL {q['task_id']}: {(q['summary'] or '')[:160]}")
    for c in reclaimed[:10]:
        detail.append(
            f"- RECLAIM (infra, kein Fehlschlag) Lauf {c['id']} ({c['profile']}): "
            f"{(c['error'] or '')[:120]}"
        )

    body = (
        "Automatischer Retro-Trigger (Watchdog).\n\n"
        f"Signale: {', '.join(signals)}\n\nDetails:\n" + "\n".join(detail) + "\n\n"
        "Hinweis (§1.4/§2.6): Blöcke, deren reason mit `review-required`, "
        "`awaiting-adam` oder `escalation-required` beginnt, gelten als normaler "
        "Human-Handoff und werden vom Watchdog NICHT als Signal gezählt. "
        "`awaiting-adam`/`escalation-required` kennzeichnen intendierte Adam/CEO-"
        "Eskalationen; `review-required` nur ohne QA-Kindkarte (§1.4). AUSSNAHME: "
        "wartet trotzdem bereits eine QA-Kindkarte auf den `review-required`-Block "
        "(§1.4-Bruch), feuert das Signal weiterhin — das Kind kann sonst nie promoten.\n\n"
        "Block-Signale sind ereignisbasiert (block-Übergänge seit dem letzten Lauf), "
        "damit ein dauerhaft offenes Ticket keinen wiederkehrenden Trigger erzeugt.\n\n"
        "Führe den Improvement-Loop aus (skill: codeforge-improvement-loop): "
        "Signale klassifizieren, LESSONS.md + DEFECTS.md aktualisieren, konkrete "
        "Patches/Proposals erzeugen (oder explizit 'no action')."
    )

    key = "codeforge-retro-" + datetime.now(timezone.utc).strftime("%Y%m%d")

    if "--dry-run" in sys.argv:
        print(f"🔁 [dry-run] Improvement-Loop würde auslösen: {', '.join(signals)} (kein Task angelegt)")
        return

    # ensure the right board is active, then create the retro task
    subprocess.run([HERMES_BIN, "kanban", "boards", "switch", BOARD],
                   cwd=HERMES_CWD, capture_output=True, text=True)
    r = subprocess.run(
        [HERMES_BIN, "kanban", "create",
         f"Retro: Improvement-Loop ({', '.join(signals)})",
         "--assignee", "hr", "--body", body,
         "--created-by", "retro-watchdog", "--idempotency-key", key, "--json"],
        cwd=HERMES_CWD, capture_output=True, text=True,
    )
    save_state({"last_run_id": new_max, "last_event_id": new_max_events})

    if r.returncode != 0:
        # surface the failure so the watchdog can't fail silently
        print(f"⚠️ CodeForge Improvement-Loop: Retro-Task konnte nicht angelegt werden.\n{r.stderr[:400]}")
        sys.exit(1)

    tid = ""
    try:
        tid = json.loads(r.stdout).get("id", "")
    except Exception:
        pass
    print(f"🔁 CodeForge Improvement-Loop ausgelöst: {', '.join(signals)}. Retro-Task: {tid or '(siehe Board)'}")


if __name__ == "__main__":
    main()
