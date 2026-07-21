---
name: goals
description: 프로젝트의 장기 목표를 세션 너머로 기억하는 durable goal-ledger. "완료"를 자기신고가 아니라 adversarial 증거 게이트(reviewer 검증)로만 인정하고, 나중에 조기완료로 드러나면 무효화·재오픈한다(green≠작동의 멀티세션화). 이전 프로젝트의 ultragoal 패턴 포팅.
when_to_use: 프로젝트급·멀티세션·substantive 목표를 추적할 때(예를 들어 "이 제품을 파일럿 납품 수준까지"). 여러 프로젝트를 오갈 때 "어디까지 했나·뭐가 가짜로 끝났나"를 복원. **단일 편집·오타·1세션·단순 CRUD엔 쓰지 말 것**(per-task 추적 아님 — 발동은 명시적, trivial은 원장을 안 건드린다).
---

# Goals — durable goal-ledger

프로젝트별 `.ksi/{goals.json(상태), ledger.jsonl(append-only 이벤트)}`. 상태 I/O는 **결정론적 헬퍼**가, 완료 판정은 **adversarial 증거 게이트**가 한다.

## 상태기계
`proposed → in_progress ⇄ blocked → (게이트 pass) completed → (무효화) false_positive_complete → 재오픈` · `proposed/in_progress/blocked → abandoned`(completed·false_positive_complete는 invalidate로만 탈출, abandon 불가)

## 헬퍼 (상태 I/O — 직접 JSON 손편집 금지, 항상 이걸로)
```bash
G="python3 ~/.claude/scripts/ksi-goals.py"   # CWD의 .ksi/ 대상
$G init [--project NAME]                       # .ksi/ 생성(git 커밋 — gitignore 금지)
$G status [--brief]                            # 현황(브리프=넛지 1줄)
$G register --id G001 --title "..." --criteria "기준1; 기준2; 기준3" [--parent ID]
$G start --id G001                             # proposed→in_progress
$G block --id G001 --reason "..."              # 외부 의존 대기
$G attempt --id G001 --evidence "..."          # 완료 '시도' 기록(증거) — 아직 completed 아님
$G gate   --id G001 --verdict pass|refuted|degraded --note "..." [--reviewer NAME --evidence-ref REF]
                                                # ← 게이트 결과만 기록(전이 가드: gate는 in_progress에서만). pass엔 --reviewer(검증 주체)·--evidence-ref(아티팩트/transcript id) 필수(누락 시 에러) — refuted/degraded는 선택
$G invalidate --id G001 --reason "..." --reopen "G002:제목; G003:제목"   # 조기완료 무효화
$G abandon --id G001 --reason "..."            # 되돌리기 명령 없음 — 오상취소면 `register`로 새 id 발급해 이어간다
```

## ★ 증거 게이트 (이 스킬이 존재하는 유일한 이유 — 절대 우회 금지)
목표를 완료하려 할 때:
1. **증거 기록**: `attempt --evidence`에 **구체 산출물**(테스트 명령+출력 · 실제 상태전이 trace · 스크린샷 경로 · file:line). "done"·"passes"는 증거가 아니다.
2. **reviewer로 adversarial 검증**: `attempt` 후 **반드시 reviewer(opus·xhigh·read-only)를 spawn**해, 등록 시 못박은 `completion_criteria` 대비 그 증거가 *실제로* 완료를 증명하는지 반증 시도(인터랙티브: Task `subagent_type: reviewer` / 워크플로: `agent({agentType:'reviewer'})`). 큰 목표는 `/codebase-audit`·`/ui-audit`로 게이트.
3. **판정만 기록**: reviewer가 확인하면 `gate --verdict pass --reviewer <검증주체> --evidence-ref <아티팩트경로/transcript id>`(→completed — 이 두 인자는 스크립트가 필수로 강제, 누락 시 에러 exit), 픽스처 우회·self-report·green인데 안 작동이면 `gate --verdict refuted --note "..."`(→in_progress 유지, attempt++, reviewer/evidence-ref는 선택). **메인이 직접 pass를 찍지 않는다 — reviewer가 깨려다 못 깨야 pass.**
4. **DEGRADED**: 게이트 verify가 rate-limit으로 죽으면 pass 금지 — `gate --verdict degraded`(completed 불가·증거 클리어·재검증 강제, audit-loop LOOP CONTRACT와 동일 원칙).

→ **스크립트가 코드로 강제하는 것**: 증거 없는(공백 포함) pass 불가 · pass엔 `--reviewer`/`--evidence-ref` 필수(자기선언 pass 차단 — 검증 주체·아티팩트 식별자를 코드가 요구) · 전이 가드(gate는 in_progress에서만, **completed는 invalidate로만 빠져나감** — 가짜완료 감사추적 우회 차단) · refuted/degraded는 증거를 비워 새 attempt 강제 · gate 없이 attempt가 3회 초과 반복되면 `ungated_attempts` 카운터가 경고를 출력(게이트를 안 부르고 attempt만 반복하는 패턴 신호 — 차단은 아니고 넛지). **스크립트가 강제 못 하는 것**: reviewer를 실제로 spawn했는지, `--reviewer`에 진짜 검증 주체를 적었는지(헬퍼는 I/O만 — reviewer 호출과 그 진위는 이 스킬 준수에 달렸다). 즉 in-session 완전 예방이 아니라 **증거·전이 강제 + durable 기록 + 멀티세션 invalidate**로 봉인한다 — 자기선언 pass를 *물리적으로* 막진 못해도(증거·reviewer 문자열은 지어낼 수 있음), 그 증거가 reviewer 반증을 못 견디면 다음 세션이 `invalidate`로 잡는다.

## deep-interview와의 연결 (completion_criteria의 출처)
`completion_criteria` = **deep-interview의 합의 spec 수용기준**. 체인: deep-interview(spec·수용기준) → `register --criteria`(그 기준) → 작업 → 게이트가 그 기준 대비 검증. 그동안 휘발하던 spec 산출물이 durable해진다.

## 흐름 (전형)
세션 시작 시 `status`로 복원 → 다음 actionable 목표 `start` → 작업 → 증거 모아 `attempt` → reviewer 게이트 → `gate pass`(또는 refuted면 계속) → 다음 목표. 후속 세션이 조기완료를 발견하면 `invalidate --reopen`.

## 범위 (lean — ceremony 방지)
- **프로젝트급 durable 목표에만.** 단일 편집·1세션 작업은 원장 미사용(과한 추적도 비용).
- 새 에이전트 0(reviewer 재사용)·MCP 0·DB 0(JSONL+markdown, grep·diff 가능).
- 장기 자율 실행은 아래 **`/goals run`**(자율 실행) — 종료를 원장 상태(게이트통과)에 묶어 '모델 self-cancel로 종료'류 autopilot 패턴의 fail-open을 구조적으로 회피.

## `/goals run` — 자율 실행 (ultracode-native, evidence-gated)
ultracode의 자율·장기·workflow를 goal-ledger 위에 얹어, **종료를 모델 자기선언이 아니라 원장 상태에 묶는다.**

**실물화: `~/.claude/workflows/goals-run.js`(native는 saved workflow로 자동등록 · 플러그인 머신은 `sync-machine.sh --plugin`이 `~/.claude/workflows/`에 배치 — 플러그인 번들은 workflows/를 안 나른다).** 산문 루프가 아니라 실행형 — `args: {dir(프로젝트 경로 필수), maxGoals(세션 예산, 기본 6·천장 20), context}`. **동작 계약(종료 조건·red-lane·evidence-gate·세션-경계 stitching)은 `~/.claude/workflows/goals-run.js` 상단 RUN CONTRACT 주석이 SSOT** — 여기서 재명세 안 함.

**안전성 근거(:35 규율 전제 — reviewer를 실제로 spawn하는지는 스크립트가 강제 못 하고 이 스킬 준수에 달렸다):** 종료가 reviewer-검증된 게이트통과라는 원장 사실이라 'todo 0 + self-cancel'류 가짜완료 출구가 없다(완전봉쇄는 아니고, 우회하면 `ungated_attempts` 경고·다음 세션 `invalidate`가 잡는다). 자율성은 최대로, 검증은 강제로.
