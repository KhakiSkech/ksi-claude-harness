#!/usr/bin/env bash
# SessionStart hook: 진입한 프로젝트에 .ksi/goals.json이 있으면 미완 goal을 1줄로 넛지.
# 있을 때만 발화(opt-in 자동 — 원장 안 쓰는 프로젝트엔 무음). dead-config-guard와 동형.
# 목적: 여러 프로젝트를 오갈 때 '어디까지 했나·뭐가 가짜완료로 재오픈됐나'를 진입 즉시 복원.
# 확장(자가감사: 원장 채택률 저조 — 내구성 갭): .ksi는 없는데 docs/에 감사/백로그류 md가
#   있으면(=추적할 상태가 있는데 원장 미채택) '/goals init 권장' 1줄 넛지를 추가. 이걸로 '전체 분석해줘'를
#   매번 재분석하는 마찰을 원장 채택으로 유도(발화는 여전히 조건부 — 아무 근거 없는 프로젝트엔 무음).
set -uo pipefail

input="$(cat)"
cwd="$(printf '%s' "$input" | python3 -c '
import sys, json
try: print(json.load(sys.stdin).get("cwd","") or "")
except Exception: print("")
' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

# 경로 A: 원장 있음 → 미완 goal 복원 넛지(기존 동작)
if [ -f "$cwd/.ksi/goals.json" ]; then
  brief="$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/ksi-goals.py" --dir "$cwd" status --brief 2>/dev/null)"
  rc=$?
  if [ -z "$brief" ]; then
    # goals.json은 실존하는데(위에서 확인) 출력이 비었다 — 진짜 '완료할 게 없음'(rc=0)과
    # 파싱/읽기 실패(rc!=0, 예외가 stderr로 삼켜짐)를 구분해 후자만 가시화(은폐 방지).
    if [ "$rc" -ne 0 ]; then
      python3 -c '
import json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"⚠ goals 원장 읽기 실패: .ksi/goals.json — /goals로 직접 점검 필요"}}))
' 2>/dev/null
    fi
    exit 0
  fi
  # 프로젝트 두뇌(state.json)도 있으면 현황·freshness 1줄 덧붙임(nextgen 3순위).
  sbrief="$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/ksi-goals.py" --dir "$cwd" state-show --brief 2>/dev/null)"
  full="$brief — /goals로 복원·이어가기"
  [ -n "$sbrief" ] && full="$full · $sbrief"
  WARN="$full" python3 -c '
import os, json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":os.environ["WARN"]}}))
' 2>/dev/null
  exit 0
fi

# 경로 B: 원장 없음 + docs/에 감사·로드맵·백로그류 md 존재 → 원장 채택 넛지(세션당 1회).
# 추적할 상태가 문서로 흩어져 있는데 durable ledger가 없다는 신호 — 무근거 프로젝트엔 발화 안 함.
CWD="$cwd" python3 -c '
import os, glob, json, hashlib, sys
cwd = os.environ.get("CWD","")
if not cwd or not os.path.isdir(os.path.join(cwd, "docs")):
    sys.exit(0)
pats = ["*AUDIT*", "*ROADMAP*", "*BACKLOG*", "*REMAINING*", "*IMPROVEMENT*", "*PLAN*", "*TODO*"]
hits = []
for p in pats:
    hits += glob.glob(os.path.join(cwd, "docs", p + ".md"))
    hits += glob.glob(os.path.join(cwd, "docs", "**", p + ".md"), recursive=True)
hits = sorted(set(hits))
if not hits:
    sys.exit(0)
# 세션당 1회 dedup — 프로젝트 경로 해시로 키(같은 프로젝트 재진입 시 반복 억제).
uid = os.getuid()
key = hashlib.sha1(cwd.encode()).hexdigest()[:8]
sent = f"/tmp/claude-{uid}/goalnudge-{key}"
try:
    os.makedirs(os.path.dirname(sent), exist_ok=True)
    if os.path.exists(sent):
        sys.exit(0)
    open(sent, "w").close()
except Exception:
    pass
n = len(hits)
sample = ", ".join(os.path.basename(h) for h in hits[:3])
msg = (f"이 프로젝트는 docs/에 상태 추적 문서 {n}개({sample}…)가 있는데 durable goal 원장(.ksi/)이 없습니다. "
       "상태를 매번 재분석하는 대신 `/goals init`으로 원장화하면 세션을 넘어 남은 작업·가짜완료가 복원됩니다 "
       "(완료=reviewer 증거 게이트). 감사/로드맵을 읽고 버리지 말고 gate 대상 goal로 durable화 권장.")
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":msg}}, ensure_ascii=False))
' 2>/dev/null
exit 0
