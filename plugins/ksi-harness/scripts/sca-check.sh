#!/usr/bin/env bash
# PostToolUse hook: 의존성 매니페스트/lockfile을 Edit/Write 하면 SCA(pip-audit / npm audit)를 돌려
# high+ 취약점을 모델에 피드백한다(PostToolUse는 차단 불가 — 넛지만, 배포 블로커 판단은 모델/사용자).
# graceful: 도구 미설치·해당 파일 아님·파일 없음이면 통과하되, '보안 게이트 미검증'은 1줄로 가시화(은폐 금지).
# dedup: 같은 파일+내용을 1시간 내 재검사하지 않는다(SCA는 느림 — 매 저장마다 PyPI 조회 방지).
# 3-게이트 doctrine: ruff/pytest가 못 잡는 차원(코드 변경 없이도 overnight CVE) — 전역 CLAUDE.md SCA 게이트의 기계화.
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"

input="$(cat)"
file="$(printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); ti = d.get("tool_input", {}) or {}
    print(ti.get("file_path") or ti.get("path") or "")
except Exception:
    print("")
' 2>/dev/null)"
[ -z "$file" ] && exit 0

base="$(basename "$file")"
eco=""
case "$base" in
  requirements*.txt|pyproject.toml|poetry.lock|Pipfile.lock) eco=py ;;
  package.json|package-lock.json|yarn.lock|pnpm-lock.yaml) eco=node ;;
  *) exit 0 ;;
esac
[ -f "$file" ] || exit 0
dir="$(dirname "$file")"

# dedup (파일별 sentinel + 내용 해시 + 1시간 윈도우)
key="$(printf '%s' "$file" | cksum | tr -d ' ' | cut -d' ' -f1)"
sentinel="${TMPDIR:-/tmp}/claude-sca-${key}.last"
h="$(cksum < "$file" 2>/dev/null | tr -d ' ')"
now="$(date +%s 2>/dev/null)"; : "${now:=0}"
if [ -f "$sentinel" ]; then
  read -r last_h last_t < "$sentinel" 2>/dev/null || { last_h=''; last_t=0; }
  if [ "$h" = "$last_h" ] && [ $((now - ${last_t:-0})) -lt 3600 ]; then exit 0; fi
fi
printf '%s %s\n' "$h" "$now" > "$sentinel" 2>/dev/null || true

emit() { MSG="$1" python3 -c '
import os, json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":os.environ["MSG"]}}))
' 2>/dev/null; }

if [ "$eco" = py ]; then
  if ! command -v pip-audit >/dev/null 2>&1; then
    emit "⚠ SCA 미검증: ${base} 변경됨인데 pip-audit 미설치 — \`pip install pip-audit\` 후 점검 필요(의존성 취약점 게이트는 ruff/pytest가 못 잡는 차원)."
    exit 0
  fi
  case "$base" in
    requirements*.txt) out="$(cd "$dir" && pip-audit -r "$base" 2>&1 | tail -n 40)"; rc=${PIPESTATUS[0]:-$?} ;;
    *)                 out="$(cd "$dir" && pip-audit 2>&1 | tail -n 40)"; rc=${PIPESTATUS[0]:-$?} ;;
  esac
elif [ "$eco" = node ]; then
  if ! command -v npm >/dev/null 2>&1; then
    emit "⚠ SCA 미검증: ${base} 변경됨인데 npm 미설치 — \`npm audit --audit-level=high\` 점검 필요."
    exit 0
  fi
  out="$(cd "$dir" && npm audit --audit-level=high 2>&1 | tail -n 40)"; rc=${PIPESTATUS[0]:-$?}
fi

[ "${rc:-0}" -eq 0 ] && exit 0   # 취약점 없음(또는 high 미만)
emit "⚠ SCA(의존성 취약점) — ${file}:
${out}

high+ 미해결은 배포 블로커로 취급하세요(전역 doctrine). 해결 불가면 사유와 잔여 리스크를 명시."
exit 0
