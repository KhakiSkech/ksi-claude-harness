#!/usr/bin/env bash
# 검증 게이트 훅 4종 + SessionStart 업데이트 알림 훅의 행동 회귀 테스트 — 합성 git repo + 합성 transcript로 발화/침묵을 검사한다.
# 훅 수정 후, 그리고 새 머신(Linux·macOS·Windows git-bash)에서 한 번 돌려 이식성을 확인한다.
# 사용: scripts/test-hooks.sh [hooks-dir]   (기본: <repo>/plugins/ksi-harness/scripts)
# 의존: bash·git·python3 (훅 자체와 동일). ruff는 없으면 해당 케이스 SKIP.
set -u

HOOKS="${1:-$(cd "$(dirname "$0")/.." && pwd)/plugins/ksi-harness/scripts}"
[ -f "$HOOKS/ui-render-check.sh" ] || { echo "hooks-dir 불일치: $HOOKS"; exit 2; }

fail=0
pass() { echo "PASS  $1"; }
failt() { echo "FAIL  $1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
(
  cd "$T" && git init -q . && git config user.email t@t && git config user.name t &&
  echo base > base.txt && git add . && git commit -qm base
) || { echo "테스트 repo 생성 실패"; exit 2; }
mkdir -p "$T/components" "$T/tests"
printf 'export default function D(){return null}\n' > "$T/components/D.tsx"
printf 'def test_x():\n    assert True\n' > "$T/tests/test_x.py"
printf 'def helper():\n    pass\n' > "$T/util.py"

TP="$T/transcript.jsonl"
rec() { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"%s"}}]}}\n' "$1"; }
pay() { printf '{"transcript_path":"%s","cwd":"%s"}' "$TP" "$T"; }

run_hook() { pay | bash "$HOOKS/$1"; }
expect_block() {
  out="$(run_hook "$1")"
  case "$out" in *'"decision"'*'"block"'*) pass "$1 — $2" ;; *) failt "$1 — $2 (출력: ${out:0:60})" ;; esac
}
expect_silent() {
  out="$(run_hook "$1")"
  [ -z "$out" ] && pass "$1 — $2" || failt "$1 — $2 (발화함)"
}

echo "== Stop 훅: 발화 케이스 (미커밋 변경) =="
rec "$T/components/D.tsx" > "$TP";  expect_block  ui-render-check.sh      "미커밋 .tsx → block"
rec "$T/tests/test_x.py" > "$TP";   expect_block  backend-verify-check.sh "미커밋 tests/*.py → block"

echo "== Stop 훅: 침묵 케이스 =="
rec "$T/util.py" > "$TP";           expect_silent backend-verify-check.sh "순수 util.py → silent(경로 필터)"
rec "$T/util.py" > "$TP";           expect_silent ui-render-check.sh      ".py는 프론트 훅 무관 → silent"
( cd "$T" && git add -A && git commit -qm all )
rec "$T/components/D.tsx" > "$TP";  expect_silent ui-render-check.sh      "커밋됨 → silent(git 교차)"
rec "$T/tests/test_x.py" > "$TP";   expect_silent backend-verify-check.sh "커밋됨 → silent(git 교차)"

echo "== Stop 훅: 루프 방지 + graceful =="
for h in ui-render-check.sh backend-verify-check.sh; do
  out="$(printf '{"stop_hook_active":true,"transcript_path":"%s","cwd":"%s"}' "$TP" "$T" | bash "$HOOKS/$h")"
  [ -z "$out" ] && pass "$h — stop_hook_active 통과" || failt "$h — stop_hook_active에서 발화"
  out="$(printf '{}' | bash "$HOOKS/$h")"
  [ -z "$out" ] && pass "$h — 빈 입력 graceful" || failt "$h — 빈 입력에서 발화"
done

echo "== PostToolUse 훅: ruff =="
if command -v ruff >/dev/null 2>&1; then
  printf 'import os\n' > "$T/bad.py"   # F401 unused import
  out="$(printf '{"tool_input":{"file_path":"%s"}}' "$T/bad.py" | bash "$HOOKS/ruff-check.sh")"
  case "$out" in *additionalContext*) pass "ruff-check.sh — 위반 → 피드백 주입" ;; *) failt "ruff-check.sh — 위반인데 침묵" ;; esac
  printf 'x = 1\n' > "$T/good.py"
  out="$(printf '{"tool_input":{"file_path":"%s"}}' "$T/good.py" | bash "$HOOKS/ruff-check.sh")"
  [ -z "$out" ] && pass "ruff-check.sh — 클린 → silent" || failt "ruff-check.sh — 클린인데 발화"
else
  echo "SKIP  ruff 미설치 — ruff 케이스 건너뜀(훅 자체는 graceful skip이 정상 동작)"
fi

echo "== PostToolUse 훅: secret-scan =="
rm -f "${TMPDIR:-/tmp}/claude-secret-scan.last"   # dedup sentinel 초기화(테스트 격리)
# 시크릿 리터럴은 런타임 생성 — 테스트 소스에 비밀 패턴을 박지 않는다.
AWSKEY="AKIA$(tr -dc 'A-Z0-9' </dev/urandom 2>/dev/null | head -c 16)"
ss() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOKS/secret-scan.sh"; }
printf 'KEY = "%s"\n' "$AWSKEY" > "$T/leak.py"
case "$(ss "$T/leak.py")" in *additionalContext*) pass "secret-scan.sh — 하드코딩 키 → 경고" ;; *) failt "secret-scan.sh — 키인데 침묵" ;; esac
printf 'x = 1\n' > "$T/noleak.py"
out="$(ss "$T/noleak.py")"; [ -z "$out" ] && pass "secret-scan.sh — 클린 → silent" || failt "secret-scan.sh — 클린인데 발화"
printf 'AWS_KEY=%s\n' "$AWSKEY" > "$T/.env.example"
out="$(ss "$T/.env.example")"; [ -z "$out" ] && pass "secret-scan.sh — .env.example 제외 → silent" || failt "secret-scan.sh — 예시인데 발화"
mkdir -p "$T/db/migrations"; printf 'DROP TABLE users;\n' > "$T/db/migrations/001.sql"
case "$(ss "$T/db/migrations/001.sql")" in *additionalContext*) pass "secret-scan.sh — 파괴적 DDL → 경고" ;; *) failt "secret-scan.sh — DDL인데 침묵" ;; esac

echo "== SessionStart 훅: update-check =="
UCSENT="${TMPDIR:-/tmp}/claude-ksi-update-check.last"
UCSRC="$T/ucsrc"; mkdir -p "$UCSRC/.claude-plugin"
( cd "$UCSRC" && git init -q . && git config user.email t@t && git config user.name t \
  && echo '{"name":"ksi-harness","version":"0.0.0"}' > .claude-plugin/plugin.json \
  && git add -A && git commit -qm r && git tag v0.0.5 && git tag v0.2.0 ) >/dev/null 2>&1
git clone -q "$UCSRC" "$T/ucroot" >/dev/null 2>&1
ucver() { printf '{"name":"ksi-harness","version":"%s"}\n' "$1" > "$T/ucroot/.claude-plugin/plugin.json"; }
ucrun() { rm -f "$UCSENT"; CLAUDE_PLUGIN_ROOT="$T/ucroot" bash "$HOOKS/update-check.sh" 2>/dev/null; }
if [ -f "$T/ucroot/.claude-plugin/plugin.json" ]; then
  # 주의: json.dumps가 한글을 \uXXXX로 이스케이프하므로 raw 한글이 아니라 ASCII 키(systemMessage)로 매칭한다.
  ucver 0.1.0; case "$(ucrun)" in *systemMessage*) pass "update-check.sh — 뒤처짐 → 알림" ;; *) failt "update-check.sh — 뒤처짐인데 침묵" ;; esac
  ucver 0.2.0; out="$(ucrun)"; [ -z "$out" ] && pass "update-check.sh — 동일 → silent" || failt "update-check.sh — 동일인데 발화"
  ucver "shaXYZ"; out="$(ucrun)"; [ -z "$out" ] && pass "update-check.sh — 비-semver → silent" || failt "update-check.sh — 비-semver인데 발화"
  git -C "$T/ucroot" remote set-url origin /nonexistent.git 2>/dev/null; ucver 0.1.0
  out="$(ucrun)"; [ -z "$out" ] && pass "update-check.sh — 원격 불가 → graceful silent" || failt "update-check.sh — 오프라인인데 발화"
  rm -f "$UCSENT"
else
  echo "SKIP  update-check (git clone 실패 — 환경)"
fi

echo "== PostToolUse 훅: sca-check =="
scaclean() { rm -f "${TMPDIR:-/tmp}"/claude-sca-*.last; }   # 파일별 dedup sentinel 초기화
sca() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOKS/sca-check.sh"; }
scaclean; printf 'x = 1\n' > "$T/notdep.py"
out="$(sca "$T/notdep.py")"; [ -z "$out" ] && pass "sca-check.sh — 비-의존성 파일 → silent" || failt "sca-check.sh — 비-의존성인데 발화"
scaclean; printf 'requests==2.0.0\n' > "$T/requirements.txt"
if command -v pip-audit >/dev/null 2>&1; then
  echo "INFO  pip-audit 설치됨 — requirements 케이스는 취약점 DB 의존이라 발화/침묵 모두 정상(스킵)"
else
  case "$(sca "$T/requirements.txt")" in *additionalContext*) pass "sca-check.sh — pip-audit 미설치 → '미검증' 발화" ;; *) failt "sca-check.sh — 미설치인데 침묵(미검증 미표기)" ;; esac
fi
scaclean

echo "== SessionStart 훅: dead-config-guard =="
dcg() { printf '{"cwd":"%s"}' "$1" | bash "$HOOKS/dead-config-guard.sh"; }
mkdir -p "$T/dcg-clean"
out="$(dcg "$T/dcg-clean")"; [ -z "$out" ] && pass "dead-config-guard.sh — settings 없음 → silent" || failt "dead-config-guard.sh — 설정없는데 발화"
mkdir -p "$T/dcg-bad/.claude"
printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:11434"},"permissions":{"defaultMode":"bypassPermissions"}}' > "$T/dcg-bad/.claude/settings.json"
case "$(dcg "$T/dcg-bad")" in *additionalContext*) pass "dead-config-guard.sh — footgun 설정 → 경고" ;; *) failt "dead-config-guard.sh — footgun인데 침묵" ;; esac
mkdir -p "$T/dcg-ok/.claude"
printf '{"effortLevel":"high"}' > "$T/dcg-ok/.claude/settings.json"
out="$(dcg "$T/dcg-ok")"; [ -z "$out" ] && pass "dead-config-guard.sh — 정상 설정 → silent" || failt "dead-config-guard.sh — 정상인데 발화"

echo "== SessionStart 훅: goal-status (goal-ledger 넛지) =="
PR="$(dirname "$HOOKS")"   # plugin root → CLAUDE_PLUGIN_ROOT (scripts/ksi-goals.py 위치)
gs() { printf '{"cwd":"%s"}' "$1" | CLAUDE_PLUGIN_ROOT="$PR" bash "$HOOKS/goal-status.sh"; }
mkdir -p "$T/gs-none"
out="$(gs "$T/gs-none")"; [ -z "$out" ] && pass "goal-status.sh — .ksi 없음 → silent" || failt "goal-status.sh — 원장없는데 발화"
KG="$HOOKS/ksi-goals.py"
python3 "$KG" --dir "$T/gs-ok" init --project demo >/dev/null 2>&1
python3 "$KG" --dir "$T/gs-ok" register --id G1 --title work >/dev/null 2>&1
python3 "$KG" --dir "$T/gs-ok" start --id G1 >/dev/null 2>&1
case "$(gs "$T/gs-ok")" in *additionalContext*) pass "goal-status.sh — 미완 goal → 넛지" ;; *) failt "goal-status.sh — 미완 goal인데 침묵" ;; esac

echo
[ $fail -eq 0 ] && echo "✅ 전체 통과" || echo "❌ 실패 있음"
exit $fail
