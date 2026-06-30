---
name: goals
description: 프로젝트의 장기 목표를 세션 너머로 기억하는 durable goal-ledger. "완료"를 자기신고가 아니라 adversarial 증거 게이트(reviewer 검증)로만 인정하고, 나중에 조기완료로 드러나면 무효화·재오픈한다(green≠작동의 멀티세션화). append-only 원장 + 증거 게이트 패턴.
when_to_use: 프로젝트급·멀티세션·substantive 목표를 추적할 때(예: "이 제품을 파일럿 납품 수준까지"). 여러 프로젝트를 오갈 때 "어디까지 했나·뭐가 가짜로 끝났나"를 복원. **단일 편집·오타·1세션·단순 CRUD엔 쓰지 말 것**(per-task 추적 아님 — 발동은 명시적, trivial은 원장을 안 건드린다).
---

# Goals — durable goal-ledger

프로젝트별 `.ksi/{goals.json(상태), ledger.jsonl(append-only 이벤트)}`. 상태 I/O는 **결정론적 헬퍼**가, 완료 판정은 **adversarial 증거 게이트**가 한다.

## 상태기계
`proposed → in_progress ⇄ blocked → (게이트 pass) completed → (무효화) false_positive_complete → 재오픈` · `any → abandoned`

## 헬퍼 (상태 I/O — 직접 JSON 손편집 금지, 항상 이걸로)
```bash
G="python3 ~/.claude/scripts/ksi-goals.py"   # CWD의 .ksi/ 대상
# (플러그인 머신: plugins/ksi-harness/scripts/ksi-goals.py를 ~/.claude/scripts/로 1회 복사 — audit-loop.js와 동일 패턴)
$G init [--project NAME]                       # .ksi/ 생성(git 커밋 — gitignore 금지)
$G status [--brief]                            # 현황(브리프=넛지 1줄)
$G register --id G001 --title "..." --criteria "기준1; 기준2; 기준3" [--parent ID]
$G start --id G001                             # proposed→in_progress
$G block --id G001 --reason "..."              # 외부 의존 대기
$G attempt --id G001 --evidence "..."          # 완료 '시도' 기록(증거) — 아직 completed 아님
$G gate   --id G001 --verdict pass|refuted|degraded --note "..."   # ← 게이트 결과만 기록(전이 가드 강제: gate는 in_progress에서만)
$G invalidate --id G001 --reason "..." --reopen "G002:제목; G003:제목"   # 조기완료 무효화
$G abandon --id G001 --reason "..."
```

## ★ 증거 게이트 (이 스킬이 존재하는 유일한 이유 — 절대 우회 금지)
목표를 완료하려 할 때:
1. **증거 기록**: `attempt --evidence`에 **구체 산출물**(테스트 명령+출력 · 실제 상태전이 trace · 스크린샷 경로 · file:line). "done"·"passes"는 증거가 아니다.
2. **reviewer로 adversarial 검증**: `attempt` 후 **반드시 reviewer(opus·xhigh·read-only)를 spawn**해, 등록 시 못박은 `completion_criteria` 대비 그 증거가 *실제로* 완료를 증명하는지 반증 시도(인터랙티브: Task `subagent_type: reviewer` / 워크플로: `agent({agentType:'reviewer'})`). 큰 목표는 `/codebase-audit`·`/ui-audit`로 게이트.
3. **판정만 기록**: reviewer가 확인하면 `gate --verdict pass`(→completed), 픽스처 우회·self-report·green인데 안 작동이면 `gate --verdict refuted --note "..."`(→in_progress 유지, attempt++). **메인이 직접 pass를 찍지 않는다 — reviewer가 깨려다 못 깨야 pass.**
4. **DEGRADED**: 게이트 verify가 rate-limit으로 죽으면 pass 금지 — `gate --verdict degraded`(completed 불가·증거 클리어·재검증 강제, audit-loop LOOP CONTRACT와 동일 원칙).

→ **스크립트가 코드로 강제하는 것**: 증거 없는(공백 포함) pass 불가 · 전이 가드(gate는 in_progress에서만, **completed는 invalidate로만 빠져나감** — 가짜완료 감사추적 우회 차단) · refuted/degraded는 증거를 비워 새 attempt 강제. **스크립트가 강제 못 하는 것**: reviewer를 실제로 spawn했는지(헬퍼는 I/O만 — reviewer 호출은 이 스킬이 책임진다). 즉 in-session 완전 예방이 아니라 **증거·전이 강제 + durable 기록 + 멀티세션 invalidate**로 봉인한다 — 자기선언 pass를 *물리적으로* 막진 못해도(증거 한 줄은 적을 수 있음), 그 증거가 reviewer 반증을 못 견디면 다음 세션이 `invalidate`로 잡는다.

## deep-interview와의 연결 (completion_criteria의 출처)
`completion_criteria` = **deep-interview의 합의 spec 수용기준**. 체인: deep-interview(spec·수용기준) → `register --criteria`(그 기준) → 작업 → 게이트가 그 기준 대비 검증. 그동안 휘발하던 spec 산출물이 durable해진다.

## 흐름 (전형)
세션 시작 시 `status`로 복원 → 다음 actionable 목표 `start` → 작업 → 증거 모아 `attempt` → reviewer 게이트 → `gate pass`(또는 refuted면 계속) → 다음 목표. 후속 세션이 조기완료를 발견하면 `invalidate --reopen`.

## 범위 (lean — ceremony 방지)
- **프로젝트급 durable 목표에만.** 단일 편집·1세션 작업은 원장 미사용(과한 추적도 비용).
- 새 에이전트 0(reviewer 재사용)·MCP 0·DB 0(JSONL+markdown, grep·diff 가능).
- 장기 자율 실행은 아래 **`/goals run`**(자율 실행) — 종료를 원장 상태(게이트통과)에 묶어 OMC autopilot의 fail-open을 구조적으로 회피.

## `/goals run` — 자율 실행 (ultracode-native, evidence-gated)
ultracode의 정수(자율·장기·workflow)를 goal-ledger 위에 얹는다. **종료를 모델 자기선언이 아니라 *원장 상태*에 묶는 것**이 핵심 — 안전레일은 ultracode 억압이 아니라 ultracode 자기 원칙(adversarial verify + 균형형 자율성)을 자율실행에 적용해 **가짜green 없이 굴러가게** 하는 바퀴다.

루프(원장의 actionable 목표를 다 소진할 때까지):
1. `ksi-goals.py status` → 다음 actionable(in_progress 우선, 없으면 proposed) 선택. **actionable이 0이면 종료** — 모든 목표가 completed(게이트통과)/blocked/abandoned라는 *객관 원장 상태*일 때만. 모델이 "끝났다"고 선언해서가 아니다.
2. proposed면 `start`. 목표를 ultracode로 작업(규모 크면 codebase-audit/build·worker fan-out — 평소대로 dial).
3. 증거 모아 `attempt --evidence` → **reviewer 게이트 필수** → `gate pass|refuted|degraded`. (게이트 우회 시 그 목표는 영원히 actionable로 남아 루프가 안 끝난다 — 우회 자체가 무의미.)
4. refuted면 같은 목표 재시도(상한 기본 3회 — 초과면 `block`으로 사람에게 상신). degraded(verify 실패)면 재검증, 반복되면 block.
5. **되돌리기 어려운 작업(배포·push·DB마이그·비밀·외부전송) 만나면 멈춰 1줄 확인** — 전역 자율성 게이트(이건 ultracode 억압이 아니라 doctrine 자체). 그 외는 멈추지 않는다.
6. budget/턴 한계면 `ScheduleWakeup`(또는 `/loop`)으로 다음 턴·세션에 이어감 — 장기 실행. 재진입 시 `status`로 상태 복원(원장이 SSOT).

**왜 안전한가 vs autopilot류:** 흔한 autopilot은 'todo 카운터 0 + 모델 self-cancel'로 종료 → 가짜완료 후 멈춤(검증 우회). 우리는 종료가 **reviewer-검증된 게이트통과**라는 원장 사실이라, 자율루프가 가짜완료로 빠져나갈 출구가 없다. 자율성은 최대로, 검증은 강제로.
