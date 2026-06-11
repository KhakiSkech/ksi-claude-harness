#!/usr/bin/env bash
# PostToolUse hook: .py 파일을 Edit/Write 하면 ruff check를 돌려 결과를 모델에 피드백한다.
# graceful skip: ruff가 없거나 .py가 아니거나 파일이 없으면 조용히 통과한다.
set -uo pipefail

# 훅이 login shell의 full PATH를 상속 못할 수 있으므로 ruff 설치 경로를 보강
export PATH="$HOME/.local/bin:$PATH"

input="$(cat)"

# 편집된 파일 경로 추출 (tool_input.file_path / path 등 여러 스키마 대응)
file="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get("tool_input", {}) or {}
    print(ti.get("file_path") or ti.get("path") or ti.get("notebook_path") or "")
except Exception:
    print("")
' 2>/dev/null)"

[ -z "$file" ] && exit 0
case "$file" in
  *.py) ;;
  *) exit 0 ;;
esac

command -v ruff >/dev/null 2>&1 || exit 0
[ -f "$file" ] || exit 0

# --no-cache: 훅의 CWD가 쓰기 불가(예: Windows의 Program Files)여도 ruff가
# .ruff_cache 생성 실패로 config/internal 에러를 내지 않게 한다(단일 파일 lint엔 캐시 불필요).
out="$(ruff check --no-cache "$file" 2>&1)"
rc=$?
[ $rc -eq 0 ] && exit 0   # 위반 없음

# ruff 자체 에러(config/internal, rc>=2): lint 위반이 아니라 헛수정은 막되, 침묵하지 않고
# 1줄 통지해 'lint 검증이 무력화됐음'을 가시화한다(설정 깨짐 은폐 방지).
if [ $rc -ge 2 ]; then
  # dedup(2026-06-11): 같은 config/internal 에러를 매 .py 저장마다 반복 주입하지 않는다.
  # 동일 에러가 1시간 내 이미 통지됐으면 침묵; 새 작업세션·다른 에러면 다시 통지(은폐 방지).
  sentinel="${TMPDIR:-/tmp}/claude-ruff-cfgerr.last"
  h="$(printf '%s' "$out" | cksum | tr -d ' ')"
  now="$(date +%s)"
  if [ -f "$sentinel" ]; then
    read -r last_h last_t < "$sentinel" 2>/dev/null || { last_h=''; last_t=0; }
    if [ "$h" = "$last_h" ] && [ $((now - ${last_t:-0})) -lt 3600 ]; then
      exit 0   # 동일 config 에러 최근 통지됨 → 침묵
    fi
  fi
  printf '%s %s\n' "$h" "$now" > "$sentinel" 2>/dev/null || true
  FILE="$file" OUT="$out" python3 -c '
import os, json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "⚠ ruff config/internal error in " + os.environ["FILE"]
            + " — 이 파일의 lint이 미검증 상태입니다. ruff 설정을 확인하세요:\n" + os.environ["OUT"]
    }
}))
' 2>/dev/null
  exit 0
fi

# 위반이 있으면 additionalContext로 모델에 전달 (PostToolUse는 차단 불가, 피드백만)
FILE="$file" OUT="$out" python3 -c '
import os, json
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": "ruff lint issues in " + os.environ["FILE"] + ":\n"
            + os.environ["OUT"] + "\n\n계속하기 전에 이 lint 문제를 고치세요."
    }
}))
'
exit 0
