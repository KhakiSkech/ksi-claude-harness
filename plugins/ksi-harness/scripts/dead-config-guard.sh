#!/usr/bin/env bash
# SessionStart hook: 진입한 프로젝트의 .claude/settings.json이 'active footgun'을 강제하는지 1줄 경고.
# 점검: Claude를 비-Anthropic/로컬 엔드포인트로 강제하는 ANTHROPIC_BASE_URL, 강제 bypassPermissions,
# 로컬/비-Claude 모델 매핑 잔존. 경고만(자동수정 없음 — update-check 훅과 동형 SessionStart 이벤트).
# 동기: 프로젝트별 settings가 세션을 조용히 깨거나(죽은 엔드포인트) 권한확인을 우회시키는 사고를 진입 시점에 가시화.
set -uo pipefail

input="$(cat)"
cwd="$(printf '%s' "$input" | python3 -c '
import sys, json
try: print(json.load(sys.stdin).get("cwd","") or "")
except Exception: print("")
' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"
cfg="$cwd/.claude/settings.json"
[ -f "$cfg" ] || exit 0

warn="$(CFG="$cfg" python3 -c '
import os, json
try:
    d = json.load(open(os.environ["CFG"]))
except Exception:
    raise SystemExit  # 파싱 불가면 침묵(다른 도구 소관)
issues = []
env = d.get("env") or {}
base = str(env.get("ANTHROPIC_BASE_URL", "") or "")
low = base.lower()
if base and ("11434" in base or "ollama" in low or "localhost" in low or "127.0.0.1" in base):
    issues.append("ANTHROPIC_BASE_URL=%s → Claude 호출을 로컬/외부 엔드포인트로 강제(엔드포인트가 죽었거나 의도치 않으면 세션이 조용히 깨짐)" % base)
perms = d.get("permissions") or {}
if perms.get("defaultMode") == "bypassPermissions":
    issues.append("permissions.defaultMode=bypassPermissions 강제(프로젝트 진입만으로 권한확인 우회)")
models = []
for v in (env.get("ANTHROPIC_MODEL", ""), env.get("ANTHROPIC_SMALL_FAST_MODEL", ""), d.get("model", "")):
    s = str(v or "").lower()
    if s and any(t in s for t in ("ollama", "qwen", "nemotron", "llama", "gemma", "mistral", "/local")):
        models.append(str(v))
if models:
    issues.append("비-Claude/로컬 모델 매핑 잔존: %s" % ", ".join(models))
if issues:
    print("⚠ 설정 경고 — 이 프로젝트 `.claude/settings.json`:\n- " + "\n- ".join(issues)
          + "\n(이 설정은 세션을 깨거나 권한확인을 우회시킬 수 있음 — 의도된 것인지 확인하세요.)")
' 2>/dev/null)"

[ -z "$warn" ] && exit 0
WARN="$warn" python3 -c '
import os, json
print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":os.environ["WARN"]}}))
' 2>/dev/null
exit 0
