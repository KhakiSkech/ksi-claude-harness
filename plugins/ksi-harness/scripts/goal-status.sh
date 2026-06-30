#!/usr/bin/env bash
# SessionStart hook: 진입한 프로젝트에 .ksi/goals.json이 있으면 미완 goal을 1줄로 넛지.
# 있을 때만 발화(opt-in 자동 — 원장 안 쓰는 프로젝트엔 무음). dead-config-guard와 동형.
# 목적: 여러 프로젝트를 오갈 때 '어디까지 했나·뭐가 가짜완료로 재오픈됐나'를 진입 즉시 복원.
set -uo pipefail

input="$(cat)"
cwd="$(printf '%s' "$input" | python3 -c '
import sys, json
try: print(json.load(sys.stdin).get("cwd","") or "")
except Exception: print("")
' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"
[ -f "$cwd/.ksi/goals.json" ] || exit 0

brief="$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/ksi-goals.py" --dir "$cwd" status --brief 2>/dev/null)"
[ -z "$brief" ] && exit 0

WARN="$brief" python3 -c '
import os, json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":os.environ["WARN"]+" — /goals로 복원·이어가기"}}))
' 2>/dev/null
exit 0
