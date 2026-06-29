#!/usr/bin/env bash
# 하네스 telemetry — transcript에서 프로젝트별 model/agent-tier 분포를 집계해 티어링 oversubscription을 적발.
# 이번 메타감사가 수동 grep으로 한 일을 영구 스크립트화('측정불가' 메타갭 해소).
# 사용: harness-cost-report.sh [경로필터]   (기본=전체 프로젝트; 인자로 경로 일부 지정 가능)
# 의존성 없음(native OTEL과 별개의 사후 분석). 실시간/USD 단위가 필요하면 아래 native opt-in 참고.
set -uo pipefail
PROJ_DIR="$HOME/.claude/projects"
filter="${1:-}"
cd "$PROJ_DIR" 2>/dev/null || { echo "no projects dir: $PROJ_DIR"; exit 1; }

printf "%-40s %8s %8s %8s %6s %5s %10s\n" "PROJECT" "opus" "sonnet" "haiku" "fable" "WF" "rev/wrk"
printf -- "%.0s-" {1..92}; echo
for d in *"$filter"*/; do
  [ -d "$d" ] || continue
  name="${d%/}"; short="${name##*Desktop-}"; short="${short:0:40}"
  o=$(grep -rhoE '"model":"claude-opus[^"]*"' "./$d" 2>/dev/null | wc -l)
  s=$(grep -rhoE '"model":"claude-sonnet[^"]*"' "./$d" 2>/dev/null | wc -l)
  h=$(grep -rhoE '"model":"claude-haiku[^"]*"' "./$d" 2>/dev/null | wc -l)
  f=$(grep -rhoE '"model":"claude-fable[^"]*"' "./$d" 2>/dev/null | wc -l)
  wf=$(grep -rho '"name":"Workflow"' "./$d" 2>/dev/null | wc -l)
  rev=$(grep -rho '"agentType":"reviewer"' "./$d" 2>/dev/null | wc -l)
  wrk=$(grep -rho '"agentType":"worker"' "./$d" 2>/dev/null | wc -l)
  [ $((o+s+h+f)) -eq 0 ] && continue
  flag=""
  [ "$s" -gt 0 ] && [ $((o / (s+1))) -ge 4 ] && flag="${flag} ⚠opus과편중"
  [ "$wf" -gt 0 ] && [ "$rev" -eq 0 ] && flag="${flag} ⚠verify우회(reviewer=0)"
  printf "%-40s %8s %8s %8s %6s %5s %10s%s\n" "$short" "$o" "$s" "$h" "$f" "$wf" "$rev/$wrk" "$flag"
done
echo
echo "해석:"
echo "  · opus:sonnet ≥ 4:1  → 탐색·구현이 opus tier로 oversubscription(적재적소 위반 의심 — sonnet/haiku로 내릴 여지)."
echo "  · WF>0 인데 reviewer=0 → adversarial verify 우회 의심(green≠작동 리스크)."
echo "  · fable 0 + opus 다수 → 메인이 사실상 Opus(main-agnostic상 OK, 비용은 인지)."
echo
echo "실시간/USD 단위가 필요하면 native OTEL opt-in: settings.json env에"
echo '  "CLAUDE_CODE_ENABLE_TELEMETRY": "1"  → model·agent.name·skill.name·effort별 token/cost.usage(USD) export.'
echo "  (console exporter는 세션을 시끄럽게 하므로, 쓸 거면 OTLP collector나 파일 exporter 권장.)"
