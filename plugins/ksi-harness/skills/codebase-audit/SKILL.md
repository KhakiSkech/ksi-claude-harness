---
name: codebase-audit
description: 코드베이스/모듈을 여러 에이전트로 병렬 감사·분석하고, 발견을 adversarial하게 검증한 뒤 우선순위 findings로 종합한다. ui-audit의 백엔드·일반 코드 대응물 — "픽셀" 대신 코드·설정·문서를 본다. ultracode의 "workflow 기본"을 매번 0에서 재조립하지 않기 위한 재사용 골격.
when_to_use: substantive한 코드 감사·병렬 분석이 필요할 때 — 여러 모듈/레포 동시 점검, 리팩터/마이그레이션 전 현황 파악, 버그·취약점·일관성·완성도 sweep. 단일 파일 1~2개 조회는 쓰지 말 것(오버킬).
---

# Codebase Audit — 병렬 감사 → adversarial 검증 → 종합

ui-audit이 프론트 "픽셀"에 하는 일을 백엔드/일반 코드에 한다. 핵심 두 원칙:
**적재적소 티어링**(탐색=haiku · 분석/구현=sonnet · verify=opus · 모순 tiebreak/고위험 최종=메인급)과 **adversarial 검증**(값싼 워커는 그럴듯한 거짓을 만든다 — 반드시 반증으로 거른다. 값싼 tier가 그럴듯한 거짓을 내는 건 실전에서 반복 적발되는 실패 모드다).

## 0. 스코프 dial (먼저 — ultracode는 비제약이 기본이라 의도적으로 줄인다)
- 작은 substantive: 워커 1개 + 검증 1패스.
- 중간: 모듈 N개 = 워커 N개, adversarial 1패스.
- 큰 감사: fan-out + adversarial(새 finding 마를 때까지, **상한 2패스**) + 완성도 critic. **확장 옵션:** critic이 미탐색 단위를 반환하면 상한 내에서 다음 라운드 analyze fan-out으로 자동 편입(§5 재투입 루프) — 고정 분해로 안 본 표면이 남을 때.
- 단일 파일·1~2줄 변경엔 이 스킬 금지 — 직접 또는 worker 1개(코드 수정에 scout/Haiku 금지).

## 0.5 재사용 루프 골격 (매번 0에서 재조립 금지 — 의미를 못박는다)
`pipeline(units, analyze, verify)`는 **고정 깊이 단발**(analyze 1패스 + verify 1패스)이다. 완성도가 필요한 큰 감사는 §5의 critic→verify→재투입 루프를 얹어 수렴시킨다. 스크립트가 dial만 바꾸도록 **기본값을 박는다**:
- verify 트리거 = critical/high(P1/P2) 기본, dial로 전체 확장 · survivor = `verdict≠'refuted' && corrected≠'none'` · 정지 = critic 무소득 또는 상한 라운드(기본 2, dial로 최대 4).
- 한 줄 의사코드: `round R: pipeline(pending, analyze, verify) → survivors; new = verify(critic(survivors)); new가 있고 R<2면 다음 round의 pending=new, 아니면 정지.`
이 기본값을 스킬이 들고 있으면 트리거·survivor·정지 기준이 스크립트마다 즉흥이던 문제가 봉합되어 **세션 간 재현성·비교가능성**이 생긴다.
**실행형 골격(권장):** repo의 `templates/workflows/audit-loop.js`를 `~/.claude/workflows/`(또는 프로젝트 `.claude/workflows/`)에 복사하면 위 루프가 saved workflow로 등록된다 — `units: [{key, prompt}]`와 dial(context·maxRounds·verifySeverities·analyzeModel·verifyModel)만 args로 넘겨 호출. 없으면 위 의사코드대로 author.

## 1. 분해
대상을 독립 단위로 나눈다(모듈/레포/레이어/관심사). 각 단위 = 한 워커의 몫.

## 2. 인벤토리 — Haiku tier
`scout`(쓰기 필요 시) 또는 빌트인 **Explore**(read-only, 이미 Haiku)로 각 단위의 파일 인벤토리·grep 인덱싱·진입점을 빠르고 싸게 수집.

## 3. 분석 fan-out — Sonnet tier
단위별 워커가 병렬 분석. **diverse-lens**로: 정확성/버그 · 보안 · 성능 · 일관성/중복 · 설정-의도 정합 · 문서-코드 drift · **핵심 여정 실행성**(시드/테스트/픽스처가 파생·종단 상태를 직접 세팅해 실제 flow를 우회하는 '가짜 green' smell — 완료 플래그 직접 세팅, 집계/파생값 직접 적재 등. 데모는 차 있는데 실사용 동선은 막혀 있나) · **제품 정체성 SSOT 정합**(README·CLAUDE.md 도메인 불변식/제품명과 모순되는 표면이 있나 — 리네이밍·피벗 후 구 명칭·구 컴포넌트·구 분류 잔재가 누수돼 신·구가 한 화면에 공존하나) · **어뷰징·무결성 불변식**(보안=auth/IDOR/injection과 **분리** — '인증상 허용되나 비즈니스룰상 금지': 역할 겸직 self-review/self-finalize · 경제 무결성 환불≤수금·멱등 결제·서버권위 가격 · 게이밍 다중계정 혜택리셋·self-count · 시간축 권한 ban/만료 후 보호동작. **happy-path가 green이어도 self/cross/replay/state-change-after 음성 케이스를 안 태우면 이 클래스는 영원히 green** — 동일 불변식을 타 모듈 레퍼런스와 대조한다).
- workflow: `agent(prompt, {model: 'sonnet', schema})`
- 인터랙티브: Task로 `subagent_type: worker` spawn (worker.md가 Sonnet+effort 고정)
- 어려운 추론이 필요한 단위만 `'opus'`로.

## 4. adversarial 검증 — opus tier (생략 금지)
각 critical/high finding(기본 — dial로 medium 이하 확장)을 **다른 에이전트가 반증 시도** — 실제 파일/근거를 다시 열어 거짓양성·과장·지어낸 명령/경로를 거른다. 살아남은 것만 채택. 확실치 않으면 보수적으로 의심. (§0.5 verify 트리거와 동일 기준 — 절마다 다르게 읽히면 안 된다.)
- 검증 tier = **`reviewer`**(Opus xhigh, read-only — Edit/Write 없어 "검증하다 슬쩍 고치기" 구조적 차단). workflow: `agent(\`반증하라: ${finding}\`, {agentType: 'reviewer', schema: VERDICT})` (`{model:'opus'}`도 동작하나 reviewer면 effort·read-only가 frontmatter로 고정). 인터랙티브: Task로 `subagent_type: reviewer` spawn.
- **verify끼리 모순이거나 고위험 변경(마이그레이션·배포·비가역 데이터 경로)의 최종 판정이면 메인급 tiebreak 1회** — model 미지정 agent()(=메인 inherit)로. 메인급 fan-out은 이 경우뿐.
- **1M 컨텍스트는 비용이 아니라 용량 결정**(opus/메인 1M 세션이면 자동 부착, 가격 프리미엄 없음): 단일 finding verify엔 과프로비저닝이나 무해, **cross-finding critic·전모듈 종합**처럼 많은 근거를 동시에 들어야 하는 단계엔 정당.

## 5. 완성도 critic → verify 재투입 (수렴 루프, opus tier)
별도 렌즈로 "빠진 게 뭔가 — 안 본 모듈·미검증 주장·미확인 가정·안 돌린 렌즈"를 재점검. critic·verify 모두 **`reviewer` tier**(§4) — 둘은 같은 opus read-only 검증 에이전트의 두 모드(반증 vs 완성도)일 뿐 별도 에이전트가 아니다.
- **critic 산출물을 그냥 채택하지 않는다** — critic이 낸 새 finding도 §4 adversarial verify를 한 번 더 통과시켜 살아남은 것만 채택(값싼 critic도 그럴듯한 거짓을 낸다 — verify 우회 금지). 1차 findings는 verify로 걸렀는데 critic 추가분만 무검증 통과하는 게 흔한 누락이다.
- critic이 '안 본 단위'를 반환하고 round < 상한(2)이면 그 단위를 **다음 라운드의 분석 fan-out으로 재투입**. critic 무소득이거나 상한 도달이면 정지. (pipeline은 고정 깊이 단발이므로, 이 재투입이 없으면 critic은 루프가 아니라 terminal one-shot이 된다.)

## 6. 종합
severity로 정렬한 findings + 구체 권고. 반복 결함은 단위별 땜질이 아니라 **구조적 처방**(공유 모듈/규칙/SSOT).

## 원칙
- **티어링(3-tier 워커 + 메인급):** 탐색=Explore/scout(`'haiku'`) · 분석·구현=worker(`'sonnet'`) · verify·완성도 critic=**reviewer**(`'opus'`·xhigh·read-only) · 모순 tiebreak/고위험 최종=메인급(미지정 inherit, 의도적으로만) · 판정·종합=메인(Fable이든 Opus든 무관). 모델은 alias로 지정 — 풀 ID 하드코딩 금지.
- **adversarial 필수:** 검증 안 거친 발견은 채택하지 않는다.
- **dial:** exhaustiveness는 "항상 최대"가 아니라 작업 크기에 비례해.
