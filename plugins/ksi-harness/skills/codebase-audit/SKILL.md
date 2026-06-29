---
name: codebase-audit
description: 코드베이스/모듈을 여러 에이전트로 병렬 감사·분석하고, 발견을 adversarial하게 검증한 뒤 우선순위 findings로 종합한다. ui-audit의 백엔드·일반 코드 대응물 — "픽셀" 대신 코드·설정·문서를 본다. ultracode의 "workflow 기본"을 매번 0에서 재조립하지 않기 위한 재사용 골격.
when_to_use: substantive한 코드 감사·병렬 분석이 필요할 때 — 여러 모듈/레포 동시 점검, 리팩터/마이그레이션 전 현황 파악, 버그·취약점·일관성·완성도 sweep. 단일 파일 1~2개 조회는 쓰지 말 것(오버킬).
---

# Codebase Audit — 병렬 감사 → adversarial 검증 → 종합

ui-audit이 프론트 "픽셀"에 하는 일을 백엔드/일반 코드에 한다. 핵심 두 원칙:
**적재적소 티어링**(탐색=haiku · 분석/구현=sonnet · verify=opus · 모순 tiebreak/고위험 최종=메인급)과 **adversarial 검증**(값싼 워커는 그럴듯한 거짓을 만든다 — 반드시 반증으로 거른다. 검증 우회 시 가짜 green이 통과한다).

## 0. 스코프 dial (먼저 — ultracode는 비제약이 기본이라 의도적으로 줄인다)
- 작은 substantive: 워커 1개 + 검증 1패스.
- 중간: 모듈 N개 = 워커 N개, adversarial 1패스.
- 큰 감사: fan-out + adversarial(새 finding 마를 때까지, **기본 2패스·천장 4** = maxRounds dial) + 완성도 critic. **확장 옵션:** critic이 미탐색 단위를 반환하면 상한 내에서 다음 라운드 analyze fan-out으로 자동 편입(§5 재투입 루프) — 고정 분해로 안 본 표면이 남을 때.
- 단일 파일·1~2줄 변경엔 이 스킬 금지 — 직접 또는 worker 1개(코드 수정에 scout/Haiku 금지).

## 0.5 재사용 루프 골격 (매번 0에서 재조립 금지 — 의미를 못박는다)
`pipeline(units, analyze, verify)`는 **고정 깊이 단발**(analyze 1패스 + verify 1패스)이다. 완성도가 필요한 큰 감사는 §5의 critic→verify→재투입 루프를 얹어 수렴시킨다.
**루프 의미론(트리거·survivor·정지·degraded·천장)의 SSOT = `~/.claude/workflows/audit-loop.js` 상단 LOOP CONTRACT 주석.** 여기서 재명세하지 않는다(산문↔코드 drift 차단) — 스킬은 dial만 넘긴다: `verifySeverities`(기본 critical/high)·`maxRounds`(기본 2·천장 4)·`analyzeModel`.
**canonical 경로 = audit-loop.js workflow.** `Workflow({scriptPath: '~/.claude/workflows/audit-loop.js', args: {units: [{key, prompt}], context, maxRounds, verifySeverities, analyzeModel}})`로 호출. **§1–6은 그 워크플로가 내부 수행하는 spec이자, 워크플로 없이 인터랙티브로 돌릴 때의 fallback playbook**이다(파일 부재 시 LOOP CONTRACT대로 author).

## 1. 분해
대상을 독립 단위로 나눈다(모듈/레포/레이어/관심사). 각 단위 = 한 워커의 몫.

## 2. 인벤토리 — Haiku tier
`scout`(쓰기 필요 시) 또는 빌트인 **Explore**(read-only, 이미 Haiku)로 각 단위의 파일 인벤토리·grep 인덱싱·진입점을 빠르고 싸게 수집.

## 3. 분석 fan-out — Sonnet tier
단위별 워커가 병렬 분석. **diverse-lens** — 각 렌즈를 한 줄씩(압축해 한 문단에 욱여넣으면 context 압박 시 렌즈가 silent drop된다):
- 정확성/버그 · 보안 · 성능 · 일관성/중복 · 설정-의도 정합 · 문서-코드 drift
- **핵심 여정 실행성** — 시드/픽스처가 파생·종단 상태를 직접 세팅해 실제 flow를 우회하는 '가짜 green' smell(`status=finalized` 주입·점수 직접 적재). 데모는 차 있는데 실사용 동선은 막혀 있나.
- **제품 정체성 SSOT 정합** — README·CLAUDE.md 도메인 불변식/제품명과 모순되는 표면(피벗·리네이밍 후 구 브랜드·렌더러·분류 잔재 누수).
- **어뷰징·무결성 불변식** *(맥락추론 — `model:'opus'` 라우팅)* — 보안(auth/IDOR/injection)과 **분리**: '인증상 허용되나 비즈니스룰상 금지'. **4 어뷰징클래스(역할겸직·경제무결성·게이밍·시간축권한)·음성 케이스(self/cross/replay/state-change-after) = CLAUDE.md 'green≠금지' SSOT 참조.** happy-path가 green이어도 음성 케이스 안 태우면 이 클래스는 영원히 green — 동일 불변식을 타 모듈 레퍼런스와 대조.
- **운영조건/fault-injection** *(맥락추론 — `model:'opus'` 라우팅)* — 정적 코드가 아니라 런타임 실패 모드: 외부의존(거래소·결제·소켓·큐)·상태기계면 타임아웃·부분체결·에러코드·rate-limit·재연결·동시성에서 어떻게 깨지나. **스테이징/testnet이 구조적으로 못 보는 환경분기가 있으면 'done'이 아니라 '실환경 카나리 전 unknown'으로 표기.**
- workflow: `agent(prompt, {model: 'sonnet', schema})`
- 인터랙티브: Task로 `subagent_type: worker` spawn (worker.md가 Sonnet+effort 고정)
- 어려운 추론이 필요한 단위만 `'opus'`로.

## 4. adversarial 검증 — opus tier (생략 금지)
각 critical/high finding(기본 — dial로 medium 이하 확장)을 **다른 에이전트가 반증 시도** — 실제 파일/근거를 다시 열어 거짓양성·과장·지어낸 명령/경로를 거른다. 살아남은 것만 채택. 확실치 않으면 보수적으로 의심. (§0.5 verify 트리거와 동일 기준 — 절마다 다르게 읽히면 안 된다.)
- 검증 tier = **`reviewer`**(Opus xhigh, read-only — Edit/Write 없어 "검증하다 슬쩍 고치기" 구조적 차단). workflow: `agent(\`반증하라: ${finding}\`, {agentType: 'reviewer', schema: VERDICT})` (`{model:'opus'}`도 동작하나 reviewer면 effort·read-only가 frontmatter로 고정). 인터랙티브: Task로 `subagent_type: reviewer` spawn.
- **verify끼리 모순이거나 고위험 변경(마이그레이션·배포·자금 경로)의 최종 판정이면 메인급 tiebreak 1회** — model 미지정 agent()(=메인 inherit)로. 메인급 fan-out은 이 경우뿐.

## 5. 완성도 critic → verify 재투입 (수렴 루프, opus tier)
별도 렌즈로 "빠진 게 뭔가 — 안 본 모듈·미검증 주장·미확인 가정·안 돌린 렌즈"를 재점검. critic·verify 모두 **`reviewer` tier**(§4) — 둘은 같은 opus read-only 검증 에이전트의 두 모드(반증 vs 완성도)일 뿐 별도 에이전트가 아니다.
- **critic 산출물을 그냥 채택하지 않는다** — critic이 낸 새 finding도 §4 adversarial verify를 한 번 더 통과시켜 살아남은 것만 채택(값싼 critic도 그럴듯한 거짓을 낸다 — verify 우회 금지). 1차 findings는 verify로 걸렀는데 critic 추가분만 무검증 통과하는 게 흔한 누락이다.
- critic이 '안 본 단위'를 반환하고 round < maxRounds(기본 2)면 그 단위를 **다음 라운드의 분석 fan-out으로 재투입**. critic 무소득이거나 상한 도달이면 정지(남은 단위는 audit-loop이 units_deferred로 보고). (pipeline은 고정 깊이 단발이므로, 이 재투입이 없으면 critic은 루프가 아니라 terminal one-shot이 된다.)

## 6. 종합 (무손실)
severity로 정렬한 findings + 구체 권고. 반복 결함은 단위별 땜질이 아니라 **구조적 처방**(공유 모듈/규칙/SSOT). **무손실 규칙: critical/high·자금경로·보안 raw finding은 종합 압축이 절대 묻지 못한다** — '대체로 production-grade' 같은 top-line이 그 아래 critical을 가리면 안 된다. 위임자(메인)는 종합 *요약문*이 아니라 **raw 차원별 리스트를 직접 읽고 보고**한다. verify/critic이 rate-limit·세션한도로 부분 실패하면 그 결과를 **DEGRADED(미검증)**로 표기하고 낙관 top-line을 보류한다(잘린 draft를 '완료'로 relay 금지).

## 원칙
- **티어링(3-tier 워커 + 메인급):** 탐색=Explore/scout(`'haiku'`) · 분석·구현=worker(`'sonnet'`) · verify·완성도 critic=**reviewer**(`'opus'`·xhigh·read-only) · 모순 tiebreak/고위험 최종=메인급(미지정 inherit, 의도적으로만) · 판정·종합=메인(Fable이든 Opus든 무관). 모델은 alias로 지정 — 풀 ID 하드코딩 금지.
- **adversarial 필수:** 검증 안 거친 발견은 채택하지 않는다.
- **dial:** exhaustiveness는 "항상 최대"가 아니라 작업 크기에 비례해.
