# ksi-claude-harness

ultracode-first **멀티에이전트 워크플로 하네스**를 팀에 배포하기 위한 Claude Code 플러그인 + 마켓플레이스 + doctrine 템플릿.

원본은 1인 개발자의 개인 `~/.claude` 하네스이며, 이 repo는 **재사용 가능한 깨끗한 골격만** 추출한 것이다(개인 메모리·비밀·세션은 제외됨).

---

## 무엇이 들어있나

| 구성요소 | 위치 | 설명 |
|---|---|---|
| **플러그인 `ksi-harness`** | `plugins/ksi-harness/` | 아래 4종을 번들 |
| · 스킬 4 | `skills/` | `deep-interview`(의도 확정 — UI면 UX 축 포함) · `brainstorm`(발산→수렴) · `codebase-audit`(백엔드 병렬 감사 + 수렴 루프) · `ui-audit`(프론트 **시각 + UX 플로우** 감사: 흐름 단계수·에러복구·용어 SSOT·마이크로카피) |
| · tier 워커 2 | `agents/` | `scout`(Haiku 경량 잡일) · `worker`(Sonnet high 구현) — 페르소나 아닌 **모델 tier 레버** |
| · 검증 게이트 훅 3 | `scripts/` + `hooks/hooks.json` | `ruff-check.sh`(.py 저장 시 lint, advisory) · `ui-render-check.sh`(화면 미커밋 편집 시 시각+동선 검증 넛지, Stop) · `backend-verify-check.sh`(백엔드 상태전이/테스트 미커밋 편집 시 'green≠작동' 넛지: 픽스처 우회·캐시 가짜green·DB dialect, Stop) |
| **doctrine 템플릿** | `templates/CLAUDE.md.example` | 언어·ultracode·모델 티어링·자율성·검증 게이트 doctrine (플러그인으로는 전역 CLAUDE.md 배포 불가 → 직접 복사) |
| **설정 예시** | `templates/*.json` | 팀 자동활성화 · 권장 사용자 설정 |

> **핵심 철학:** 모델 티어링(haiku/sonnet/opus/메인, **main-agnostic**) + adversarial 검증 + 검증 게이트(green≠작동, 프론트=시각+동선·백엔드=픽스처/dialect) + **design-side UX spec→검증 루프**(검증기는 측정할 목표가 없으면 '안 깨졌나'만 잰다 → 착수 전 페르소나·동선·상태·마이크로카피·접근성 예산을 먼저)가 스킬·에이전트·훅에 **baked-in**. 도메인 페르소나 에이전트는 두지 않는다(전문성은 프롬프트/맥락에).

---

## 설치 (팀)

### 1. 플러그인 — 둘 중 하나

**(a) 프로젝트 단위 자동활성화 (팀 공유, 권장)** — 프로젝트의 `.claude/settings.json`에 `templates/project-settings.example.json` 내용을 병합하고 git 체크인. `YOUR-ORG/ksi-claude-harness`를 실제 repo로 바꾼다. 팀원이 프로젝트를 신뢰(trust)하면 자동 등록·활성화된다.

**(b) 개인 설치**
```
/plugin marketplace add YOUR-ORG/ksi-claude-harness
/plugin install ksi-harness@ksi-tools
```
(로컬 테스트는 `/plugin marketplace add ./ksi-claude-harness`)

### 2. doctrine 템플릿 복사
플러그인은 전역 지침을 심을 수 없다. `templates/CLAUDE.md.example`를 `~/.claude/CLAUDE.md`(개인 전역) 또는 프로젝트 `CLAUDE.md`에 복사하고, **스택 섹션을 팀에 맞게 조정**한다.

### 3. 권장 사용자 설정
`templates/user-settings.example.json`에서 필요한 키를 `~/.claude/settings.json`에 병합(`_comment` 키는 제거). `effortLevel: high`는 비-ultracode fallback 기준값. **`model` 키는 일부러 없음 = main-agnostic**(세션에서 `/model`로 Fable/Opus 선택).

### 4. (파워유저) ultracode + dangerous alias — **선택, 안전 문서 먼저 읽기**
원작자는 새 세션마다 ultracode + dangerous mode를 켜는 alias를 쓴다. 이건 **개인이 직접** `~/.bashrc`에 넣어야 한다(하네스/플러그인이 자동 추가 못 함):
```bash
alias claude='claude --dangerously-skip-permissions --settings '\''{"ultracode":true}'\'''
# 평범 실행은 \claude
```
→ **적용 전 [`docs/SAFETY.md`](docs/SAFETY.md)를 반드시 읽는다.** dangerous mode는 권한 프롬프트를 끄므로 trade-off가 있다.

---

## 요구사항 (스킬·훅이 100% 동작하려면)
- **ruff 훅:** `ruff`가 PATH에(보통 `~/.local/bin/ruff`). 없으면 graceful skip.
- **ui-audit / ui-render 훅:** Node + Playwright(브라우저 설치), 그리고 앱을 띄울 수 있는 환경. auth-gated 앱은 시각감사에 세션/시드가 필요.
- **워크플로 스킬(codebase-audit·ui-audit):** ultracode 세션(또는 Workflow 도구 사용 권한)에서 fan-out이 의미 있다.

## 스킬 네임스페이스
플러그인 설치 시 스킬은 `/ksi-harness:codebase-audit` 처럼 네임스페이스가 붙는다. 스킬 본문의 상호참조는 bare 이름(`codebase-audit`)을 쓰므로, 플러그인 이름을 바꾸면 README/템플릿의 참조도 함께 바꾼다(모델은 대개 의도로 해석하지만 명시가 안전).

## 업데이트 / 버전
- 활발한 개발: `plugin.json`/`marketplace.json`의 `version`을 생략하면 git commit SHA가 버전이 된다.
- 안정 배포: semantic versioning(`0.1.0` → bump). 마켓플레이스 `source`에 `ref`(tag/branch)로 stable/latest 채널 분리 가능.

## 배포 전 검증
```
claude plugin validate ./plugins/ksi-harness     # 플러그인 매니페스트
claude plugin validate ./ksi-claude-harness      # 마켓플레이스 root
/plugin marketplace add ./ksi-claude-harness      # 로컬 설치 테스트
```

## 안 들어있는 것 (의도적 — 프라이버시)
개인 메모리(프로필·진행 프로젝트·이메일·플랜·머신정보), MCP auth 캐시, credentials, 세션 기록은 **전부 제외**. 이 repo는 골격만이다.
