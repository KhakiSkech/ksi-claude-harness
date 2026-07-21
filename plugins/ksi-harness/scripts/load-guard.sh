#!/usr/bin/env bash
# load-guard.sh — CPU-heavy 로컬 작업(Playwright/Chromium/dev server) preflight + 캡처 직렬화 락.
# ui-audit §2 캡처 라우팅의 실행물: 경합하는 박스에선 "더 병렬"이 아니라 "밖으로 빼거나(CI/remote) 줄 세우기(락)".
#
# 사용:
#   load-guard.sh [check]            # load1/nproc 비율 판정: GREEN/YELLOW=exit 0, RED=exit 2(로컬 캡처 비권장 → CI/remote/defer)
#   load-guard.sh run -- <cmd...>    # 머신 전역 캡처 락(flock) 아래에서 <cmd> 실행 — 동시 세션의 Chromium 중첩 기동 방지
# 노브(env): KSI_LOAD_YELLOW=1.5  KSI_LOAD_RED=3.0  KSI_LOAD_LOCK_WAIT=1800(초)
# graceful: /proc/loadavg·flock 부재(비-Linux 머신)면 차단하지 않고 통과한다 — 판정 불가 ≠ 차단.

set -u

YELLOW_T="${KSI_LOAD_YELLOW:-1.5}"
RED_T="${KSI_LOAD_RED:-3.0}"
LOCK_WAIT="${KSI_LOAD_LOCK_WAIT:-1800}"
LOCK_FILE="${HOME}/.claude/run/ui-capture.lock"

verdict() {
  if [ ! -r /proc/loadavg ]; then
    echo "LOAD-GUARD GREEN (판정 불가: /proc/loadavg 없음 — 비차단 통과)"
    return 0
  fi
  local load1 cores ratio level
  load1=$(awk '{print $1}' /proc/loadavg)
  cores=$(nproc 2>/dev/null || echo 1)
  ratio=$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%.2f", l/c}')
  level=$(awk -v r="$ratio" -v y="$YELLOW_T" -v rd="$RED_T" 'BEGIN{print (r>=rd)?"RED":(r>=y)?"YELLOW":"GREEN"}')
  echo "LOAD-GUARD ${level} load1=${load1} cores=${cores} ratio=${ratio} (yellow>=${YELLOW_T} red>=${RED_T})"
  case "$level" in
    RED)
      echo "→ CI 캡처 권장. 로컬이 불가피하면 capture.mjs 저강도(자동 감속·self-nice)로 진행하되 지연·부분실패 가능성을 보고 (ui-audit §2)."
      return 2 ;;
    YELLOW)
      echo "→ 경합 주의: 캡처 명령은 'load-guard.sh run -- <cmd>'로 직렬화하고, 멀티프로젝트 동시 감사는 원격 경로 권장."
      return 0 ;;
  esac
  return 0
}

case "${1:-check}" in
  check)
    verdict
    exit $?
    ;;
  run)
    shift
    [ "${1:-}" = "--" ] && shift
    if [ $# -eq 0 ]; then
      echo "usage: load-guard.sh run -- <cmd...>" >&2
      exit 64
    fi
    mkdir -p "$(dirname "$LOCK_FILE")"
    if command -v flock >/dev/null 2>&1; then
      exec flock -w "$LOCK_WAIT" "$LOCK_FILE" "$@"
    fi
    echo "LOAD-GUARD: flock 없음 — 락 없이 실행(비-Linux graceful)" >&2
    exec "$@"
    ;;
  *)
    echo "usage: load-guard.sh [check | run -- <cmd...>]" >&2
    exit 64
    ;;
esac
