#!/usr/bin/env python3
"""ksi-goals — durable goal-ledger 상태 헬퍼 (green≠작동의 멀티세션화).

durable goal-ledger 패턴: 프로젝트별 .ksi/{goals.json(상태), ledger.jsonl(append-only 이벤트)}.
완료는 자기신고가 아니라 evidence gate(reviewer 검증) 통과로만 인정 — gate refuted면 in_progress 유지.
완료가 나중에 조기였다고 드러나면 invalidate → false_positive_complete + 재오픈.

상태기계: proposed → in_progress ⇄ blocked → (gate pass) completed → (invalidate) false_positive_complete → 재오픈
          any → abandoned

이 스크립트는 '상태 I/O'만 결정론적으로 한다. evidence gate의 *판정*(reviewer adversarial 검증)은
/goals 스킬이 오케스트레이션하고, 그 결과만 `gate` 명령으로 기록한다(헬퍼는 reviewer를 부르지 않음).
코드 강제: 증거 없는 pass 불가 · 전이 가드(ALLOWED — completed는 invalidate로만) · refuted/degraded는 증거 클리어.
가정: 단일 writer(같은 .ksi를 동시 변경하는 두 프로세스는 미가정 — atomic write로 corruption은 없으나 lost-update 가능).

사용: ksi-goals.py <command> [opts]   (CWD의 .ksi/ 대상, --dir로 변경)
"""
import argparse
import datetime
import json
import os
import sys

STATES = ("proposed", "in_progress", "blocked", "completed", "false_positive_complete", "abandoned")
MARK = {"completed": "✓", "false_positive_complete": "✗재오픈", "abandoned": "—",
        "blocked": "⏸", "in_progress": "▶", "proposed": "·"}
# 허용 전이(현재상태 → 명령). 이 외엔 거부 — completed는 invalidate로만 빠져나간다(가짜완료 감사추적 우회 차단).
ALLOWED = {
    "start": ("proposed", "blocked"),
    "block": ("in_progress",),
    "attempt": ("in_progress",),
    "gate": ("in_progress",),
    "invalidate": ("completed",),
    "abandon": ("proposed", "in_progress", "blocked"),
}


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def paths(d):
    k = os.path.join(d, ".ksi")
    return k, os.path.join(k, "goals.json"), os.path.join(k, "ledger.jsonl")


def load(gp):
    if not os.path.exists(gp):
        sys.exit("'.ksi/goals.json' 없음 — 먼저 `ksi-goals.py init`")
    with open(gp, encoding="utf-8") as f:
        return json.load(f)


def save(gp, data):
    data["updated_at"] = now()
    tmp = gp + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, gp)


def log(lp, event, goal=None, **kw):
    rec = {"ts": now(), "event": event}
    if goal:
        rec["goal"] = goal
    rec.update(kw)
    with open(lp, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def find(data, gid):
    for g in data["goals"]:
        if g["id"] == gid:
            return g
    sys.exit(f"goal '{gid}' 없음")


def new_goal(gid, title, criteria=None, parent=None):
    return {
        "id": gid, "title": title, "completion_criteria": criteria or [],
        "status": "proposed", "attempt": 1, "evidence": None, "verdict": None,
        "invalidation_reason": None, "parent": parent, "blocked_by": None,
        "created_at": now(), "updated_at": now(),
    }


def build_parser():
    p = argparse.ArgumentParser(prog="ksi-goals")
    p.add_argument("--dir", default=".")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init").add_argument("--project", default=os.path.basename(os.path.abspath(".")))

    st = sub.add_parser("status")
    st.add_argument("--brief", action="store_true")

    rg = sub.add_parser("register")
    rg.add_argument("--id", required=True)
    rg.add_argument("--title", required=True)
    rg.add_argument("--criteria", default="", help="완료기준 ; 로 구분")
    rg.add_argument("--parent", default=None)

    sub.add_parser("start").add_argument("--id", required=True)

    bl = sub.add_parser("block")
    bl.add_argument("--id", required=True)
    bl.add_argument("--reason", required=True)

    at = sub.add_parser("attempt")
    at.add_argument("--id", required=True)
    at.add_argument("--evidence", required=True)

    ga = sub.add_parser("gate")
    ga.add_argument("--id", required=True)
    ga.add_argument("--verdict", required=True, choices=("pass", "refuted", "degraded"))
    ga.add_argument("--note", default="")

    iv = sub.add_parser("invalidate")
    iv.add_argument("--id", required=True)
    iv.add_argument("--reason", required=True)
    iv.add_argument("--reopen", default="", help="새 goal들 id:title;id:title")

    ab = sub.add_parser("abandon")
    ab.add_argument("--id", required=True)
    ab.add_argument("--reason", required=True)
    return p


def cmd_status(data, brief):
    cnt = {s: 0 for s in STATES}
    for x in data["goals"]:
        cnt[x["status"]] = cnt.get(x["status"], 0) + 1
    actionable = [x for x in data["goals"] if x["status"] in ("proposed", "in_progress")]
    nxt = f"{actionable[0]['id']} {actionable[0]['title']}" if actionable else "(없음)"
    if brief:
        parts = []
        if cnt["in_progress"]:
            parts.append(f"진행중 {cnt['in_progress']}")
        if cnt["proposed"]:
            parts.append(f"대기 {cnt['proposed']}")
        if cnt["blocked"]:
            parts.append(f"blocked {cnt['blocked']}")
        if cnt["false_positive_complete"]:
            parts.append(f"⚠가짜완료재오픈 {cnt['false_positive_complete']}")
        if parts:
            print(f"{data['project']} goal: " + " · ".join(parts) + f" — 다음: {nxt} (/goals)")
        return
    print(f"# {data['project']} — goal-ledger")
    for x in data["goals"]:
        print(f"  {MARK.get(x['status'], '?')} [{x['id']}] {x['title']}  ({x['status']}, attempt {x['attempt']})")
        if x.get("invalidation_reason"):
            print(f"       ↳ 무효화: {x['invalidation_reason']}")
    print("\n  요약: " + " · ".join(f"{s}={cnt[s]}" for s in STATES if cnt[s]))
    print(f"  다음 actionable: {nxt}")


def main():
    args = build_parser().parse_args()
    kdir, gp, lp = paths(args.dir)

    if args.cmd == "init":
        if os.path.exists(gp):
            print(f"이미 존재: {gp}")
            return
        os.makedirs(kdir, exist_ok=True)
        save(gp, {"version": 1, "project": args.project, "updated_at": now(), "goals": []})
        open(lp, "a").close()
        log(lp, "init", project=args.project)
        print(f"✓ 초기화: {kdir}  (.gitignore에 넣지 말 것 — 목표 이력은 repo와 함께 커밋)")
        return

    data = load(gp)

    if args.cmd == "status":
        cmd_status(data, args.brief)
        return

    if args.cmd == "register":
        if any(x["id"] == args.id for x in data["goals"]):
            sys.exit(f"goal '{args.id}' 이미 존재")
        if args.parent and not any(x["id"] == args.parent for x in data["goals"]):
            print(f"⚠ parent '{args.parent}' 미존재 — 참조만 기록(트리 검증 없음)")
        crit = [c.strip() for c in args.criteria.split(";") if c.strip()]
        data["goals"].append(new_goal(args.id, args.title, crit, args.parent))
        save(gp, data)
        log(lp, "registered", args.id, status="proposed", parent=args.parent)
        print(f"✓ 등록: {args.id}  (완료기준 {len(crit)}개 — gate가 이 기준 대비 검증)")
        return

    x = find(data, args.id)
    allowed = ALLOWED.get(args.cmd)
    if allowed and x["status"] not in allowed:
        extra = " (완료 목표는 invalidate로만 재오픈)" if x["status"] == "completed" else ""
        sys.exit(f"{args.id}: '{args.cmd}'은 상태 '{x['status']}'에서 불가 — 허용: {', '.join(allowed)}{extra}")

    if args.cmd == "start":
        x["status"] = "in_progress"
        x["updated_at"] = now()
        save(gp, data)
        log(lp, "started", args.id)
        print(f"▶ {args.id} in_progress")
    elif args.cmd == "block":
        x["status"] = "blocked"
        x["blocked_by"] = args.reason
        x["updated_at"] = now()
        save(gp, data)
        log(lp, "blocked", args.id, reason=args.reason)
        print(f"⏸ {args.id} blocked")
    elif args.cmd == "attempt":
        ev = (args.evidence or "").strip()
        if not ev:
            sys.exit(f"{args.id}: 빈 evidence 불가 — 구체 산출물(테스트 출력·상태전이 trace·file:line)을 적어라")
        x["evidence"] = ev
        x["updated_at"] = now()
        save(gp, data)
        log(lp, "completion_attempt", args.id, evidence=ev)
        print(f"📋 {args.id} 완료 시도 기록 — 이제 evidence gate(reviewer 검증) 필요. 통과 시 `gate --verdict pass`")
    elif args.cmd == "gate":
        if args.verdict == "pass" and not (x.get("evidence") or "").strip():
            sys.exit(f"{args.id}: 증거 없이 pass 불가 — 먼저 `attempt --evidence` 후 reviewer 검증(증거 게이트 우회 금지)")
        x["verdict"] = {"verdict": args.verdict, "note": args.note, "at": now()}
        if args.verdict == "pass":
            x["status"] = "completed"
            msg = f"✓ {args.id} completed (evidence gate 통과)"
        elif args.verdict == "degraded":
            x["evidence"] = None  # 미검증 — 새 attempt 강제
            msg = f"⚠ {args.id} DEGRADED — verify 미완(rate-limit 등). completed 금지, in_progress 유지·재검증 필요"
        else:  # refuted
            x["status"] = "in_progress"
            x["attempt"] += 1
            x["evidence"] = None  # 기각된 증거는 재사용 불가 — 다음 pass가 새 attempt를 강제
            msg = f"✗ {args.id} gate refuted — in_progress 유지(attempt {x['attempt']}). 새 증거로 재검증: {args.note}"
        x["updated_at"] = now()
        save(gp, data)
        log(lp, "gate_verdict", args.id, verdict=args.verdict, note=args.note)
        print(msg)
    elif args.cmd == "invalidate":
        if x["status"] != "completed":
            sys.exit(f"{args.id}는 completed가 아니라 invalidate 불가(현재 {x['status']})")
        x["status"] = "false_positive_complete"
        x["invalidation_reason"] = args.reason
        x["updated_at"] = now()
        reopened = []
        skipped = []
        for part in (q for q in args.reopen.split(";") if q.strip()):
            nid, _, ntitle = part.partition(":")
            nid, ntitle = nid.strip(), ntitle.strip()
            if nid and not any(y["id"] == nid for y in data["goals"]):
                data["goals"].append(new_goal(nid, ntitle or nid, parent=args.id))
                reopened.append(nid)
            elif nid:
                skipped.append(nid)
        save(gp, data)
        log(lp, "false_positive_complete", args.id, reason=args.reason, reopened_as=reopened)
        out = f"✗재오픈 {args.id} → false_positive_complete. 재오픈: {reopened or '(없음)'}"
        if skipped:
            out += f"  ⚠ 이미 존재해 스킵: {skipped}"
        print(out)
    elif args.cmd == "abandon":
        x["status"] = "abandoned"
        x["invalidation_reason"] = args.reason
        x["updated_at"] = now()
        save(gp, data)
        log(lp, "abandoned", args.id, reason=args.reason)
        print(f"— {args.id} abandoned")


if __name__ == "__main__":
    main()
