#!/usr/bin/env bash
# sourceable 헬퍼(0.8.3): 검증/넛지 훅의 강도 스위치. `. "$(dirname "$0")/ksi-mode.sh"` 로 소싱하면 KSI_MODE가 설정된다.
#   strict(기본) : 종전 동작 — 완료 게이트 block · 넛지 전부 발화.
#   warn         : pre-destructive의 되돌리기-가능(reset --hard/clean -f)을 차단 대신 stderr 경고로.
#                  단, Stop 완료 게이트(ui-render/backend-verify)는 '비차단 리마인더' 채널이 없어 warn=완료 허용(=off와 동일 — 차단만 해제).
#   off          : 검증/넛지 훅 침묵(빠른 PoC·실험 세션용).
# ⚠ 안전벨트는 모드와 무관하게 '항상' 유지된다 — escape는 인체공학 마찰을 줄이는 스위치이지 안전 해제가 아니다:
#   되돌리기 불가/외부영향 하드가드(rm 루트·홈·시스템최상위, git push --force, DROP DATABASE/SCHEMA, git push 시크릿 유출)는
#   warn/off에서도 그대로 차단된다. warn/off가 낮추는 건 '검증 넛지'와 '되돌리기-가능한 로컬 손실 경고'뿐.
# 설정 우선순위: 환경변수 KSI_HOOKS(= strict|warn|off). 미설정·오값이면 strict.
#   예) 세션 임시: `export KSI_HOOKS=off` · 프로젝트: .claude/settings.json 의 env 블록에 "KSI_HOOKS":"warn".
KSI_MODE="${KSI_HOOKS:-strict}"
case "$KSI_MODE" in
  strict|warn|off) ;;
  *) KSI_MODE=strict ;;
esac
export KSI_MODE
