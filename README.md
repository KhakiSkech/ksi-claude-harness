# ksi-claude-harness

ultracode-first **멀티에이전트 워크플로 하네스**를 팀에 배포하기 위한 Claude Code 플러그인 + 마켓플레이스 + doctrine 템플릿.

원본은 1인 개발자의 개인 `~/.claude` 하네스이며, 이 repo는 **재사용 가능한 깨끗한 골격만** 추출한 것이다(개인 메모리·비밀·세션은 제외됨).

---

## 무엇이 들어있나

| 구성요소 | 위치 | 설명 |
|---|---|---|
| **플러그인 `ksi-harness`** | `plugins/ksi-harness/` | 아래 4종을 번들 |
| · 스킬 6 | `skills/` | `deep-interview`(의도 확정 — UI면 UX 축·멀티액터면 **어뷰징 축** 포함) · `brainstorm`(발산→수렴) · `codebase-audit`(백엔드 병렬 감사 + 수렴 루프 + **어뷰징·무결성**(self-dealing·경제무결성·게이밍·시간축권한)·**운영조건/fault-injection**(런타임 실패모드·환경분기 미관측) 렌즈 + 무손실 종합) · `ui-audit`(프론트 **시각 + UX 플로우** 감사: 흐름 단계수·에러복구·용어 SSOT·마이크로카피) · `release-risk`(배포·마이그·롤백·blast-radius 리스크 점검 — 자율성 게이트 운영화) · `goals`(**durable goal-ledger** — 완료를 reviewer 증거 게이트로만 인정·조기완료 무효화/재오픈·`/goals run` evidence-gated 자율실행; 프로젝트별 `.ksi/ledger.jsonl` append-only. 헬퍼 `scripts/ksi-goals.py`) |
| · tier 워커 3 | `agents/` | `scout`(Haiku 잡일 — 비코드 write) · `worker`(Sonnet high 구현) · `reviewer`(Opus xhigh, **read-only 검증** — adversarial 반증·완성도 critic) — 페르소나 아닌 **모델 tier 레버**(메인급은 움직이는 천장이라 에이전트 없음) |
| · 검증 게이트 훅 6 | `scripts/` + `hooks/hooks.json` | `ruff-check.sh`(.py 저장 시 lint, advisory) · `secret-scan.sh`(저장 시 **민감 쓰기 경고**, PostToolUse: 하드코딩 시크릿·파괴적 migration DDL·settings.json drift — 경고-only, 오탐방지·1h dedup) · `sca-check.sh`(의존성 매니페스트/lock 변경 시 **pip-audit/npm audit**, high+ 취약점 경고, PostToolUse; 도구 미설치는 '미검증'으로 표기) · `ui-render-check.sh`(화면 미커밋 편집 시 시각+동선 검증 넛지, Stop) · `backend-verify-check.sh`(백엔드 상태전이/테스트 미커밋 편집 시 'green≠작동' 넛지: 픽스처 우회·캐시 가짜green·DB dialect, Stop) · `dead-config-guard.sh`(프로젝트 settings가 Claude를 로컬/외부 엔드포인트로 강제하거나 권한확인 우회 시 경고, SessionStart) · `goal-status.sh`(프로젝트에 `.ksi/goals.json` 있으면 미완 goal 1줄 넛지, SessionStart) |
| **doctrine 템플릿** | `templates/CLAUDE.md.example` · `templates/domain-invariants.example.md` | 언어·ultracode·모델 티어링·자율성·검증 게이트 doctrine (전역 CLAUDE.md 배포 불가 → 직접 복사) + `## 도메인 불변식` SSOT 스캐폴딩(4 어뷰징클래스 + 아키타입별 채움 예시 — codebase-audit 어뷰징 렌즈의 조준점) |
| **설정 예시** | `templates/*.json` | 팀 자동활성화 · 권장 사용자 설정 |
| **telemetry** | `scripts/harness-cost-report.sh` | transcript에서 프로젝트별 model/tier 분포·oversubscription(opus 과편중·reviewer 우회) 집계 — 의존성 없음(native OTEL opt-in 안내 포함) |

> **핵심 철학:** 모델 티어링(haiku/sonnet/opus/메인, **main-agnostic**) + adversarial 검증 + 검증 게이트(green≠작동, 프론트=시각+동선·백엔드=픽스처/dialect) + **design-side UX spec→검증 루프**(검증기는 측정할 목표가 없으면 '안 깨졌나'만 잰다 → 착수 전 페르소나·동선·상태·마이크로카피·접근성 예산을 먼저)가 스킬·에이전트·훅에 **baked-in**. 도메인 페르소나 에이전트는 두지 않는다(전문성은 프롬프트/맥락에).

---

## 설치 (팀)

### 0. 의존성 점검 (먼저)
```
bash scripts/doctor.sh
```
필수(git·python3·claude)와 권장(ruff·Playwright — **없으면 해당 기능이 조용히 빠짐**)을 점검하고 OS별 설치 힌트를 출력한다. 자동 설치는 의도적으로 안 함(패키지 매니저·sudo가 머신마다 달라서 — 힌트만).

### 1. 플러그인 — 둘 중 하나

**(a) 프로젝트 단위 자동활성화 (팀 공유, 권장)** — 프로젝트의 `.claude/settings.json`에 `templates/project-settings.example.json` 내용을 병합하고 git 체크인(repo 좌표는 `KhakiSkech/ksi-claude-harness`로 설정돼 있음). 팀원이 프로젝트를 신뢰(trust)하면 자동 등록·활성화된다. private repo라 팀원은 GitHub 접근 권한(collaborator)이 필요하다.

**(b) 개인 설치**
```
/plugin marketplace add KhakiSkech/ksi-claude-harness
/plugin install ksi-harness@ksi-tools
```
(로컬 테스트는 `/plugin marketplace add ./ksi-claude-harness`)

> ⚠️ **이중 활성화 주의 (원작자/기존 사용자):** `~/.claude/{skills,agents,hooks}`에 이 골격의 **로컬 사본**을 이미 둔 머신에서는 플러그인을 설치하지 말 것(또는 설치 전에 로컬 사본과 `settings.json`의 해당 훅 블록을 제거). 둘 다 두면 스킬이 bare+네임스페이스(`/ui-audit` + `/ksi-harness:ui-audit`)로 중복되고 **같은 Stop 훅이 매번 2회 발화**한다. 로컬 사본이 없는 일반 팀원은 해당 없음.

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
위는 bash(Linux) 기준. **zsh(macOS)·PowerShell(Windows)은 넣을 파일·문법이 다르다** → 아래 [OS별 차이](#os별-차이-linux--macos--windows) 표 참조.
→ **적용 전 [`docs/SAFETY.md`](docs/SAFETY.md)를 반드시 읽는다.** dangerous mode는 권한 프롬프트를 끄므로 trade-off가 있다.

---

## 요구사항 (스킬·훅이 100% 동작하려면)
한 번에 점검: `bash scripts/doctor.sh` (필수/권장/프로젝트별 구분 + OS별 설치 힌트).
- **ruff 훅:** `ruff`가 PATH에(보통 `~/.local/bin/ruff`). 없으면 **조용히 skip**된다 — .py 저장 시 lint 피드백이 한 번도 안 보이면 ruff 설치/PATH부터 확인.
- **ui-audit / ui-render 훅:** Node + Playwright(브라우저 설치), 그리고 앱을 띄울 수 있는 환경. auth-gated 앱은 시각감사에 세션/시드가 필요.
- **워크플로 스킬(codebase-audit·ui-audit):** ultracode 세션(또는 Workflow 도구 사용 권한)에서 fan-out이 의미 있다.

## OS별 차이 (Linux / macOS / Windows)
하네스는 OS 불문 **`~/.claude` 전역**에 설치되고, 훅·테스트는 전부 **bash + python3 + git**에 의존하므로 세 OS에서 **같은 경로로 동작**한다(Windows는 Claude Code가 훅을 git-bash로 실행 — 실증됨, NTFS 케이스폴드까지 `normcase`로 처리). 그래서 설치 절차는 하나면 충분하고, 실제로 갈리는 건 **딱 2지점**뿐이다:

| | Linux | macOS | Windows |
|---|---|---|---|
| **사전 요구** | 보통 다 있음 (git·python3) | python3 설치 확인 (`python3 --version`) | **[Git for Windows](https://git-scm.com/download/win)**(=git-bash) + python3. 훅·`test-hooks.sh`는 git-bash에서 돈다 |
| **alias 넣을 곳** (§4, 어차피 수동) | `~/.bashrc` | `~/.zshrc` (macOS 기본 셸 = zsh) | PowerShell `$PROFILE` — **Warp 등 셸 가드보다 위에** 두고 `claude-plain` 탈출구를 함께 정의 |
| **ruff 경로** | `~/.local/bin/ruff` (PATH 보강됨) | 동일 | `pipx`/`pip --user` 설치 경로가 PATH에 있어야 — 없으면 ruff 훅 조용히 skip |

> Windows alias 예(PowerShell `$PROFILE`): `function claude { claude.exe --dangerously-skip-permissions --settings '{"ultracode":true}' @args }` · `function claude-plain { claude.exe @args }`. **이 함수도 개인이 직접** 넣는다(하네스가 자동 추가 못 함). dangerous mode는 [`docs/SAFETY.md`](docs/SAFETY.md) 먼저.

즉 **별도 3종 설치 문서는 불필요** — 위 표의 2지점(사전 요구 + alias 위치)만 OS에 맞게 읽으면 어느 머신에서도 안 헤맨다. (향후 `install.sh`를 만들면 `uname`으로 감지해 이 안내문만 분기 출력하면 된다.)

## 스킬 네임스페이스
플러그인 설치 시 스킬은 `/ksi-harness:codebase-audit` 처럼 네임스페이스가 붙는다. 스킬 본문의 상호참조는 bare 이름(`codebase-audit`)을 쓰므로, 플러그인 이름을 바꾸면 README/템플릿의 참조도 함께 바꾼다(모델은 대개 의도로 해석하지만 명시가 안전).

## 업데이트 / 버전
- 활발한 개발: `plugin.json`/`marketplace.json`의 `version`을 생략하면 git commit SHA가 버전이 된다.
- 안정 배포: semantic versioning(`0.1.0` → bump). 마켓플레이스 `source`에 `ref`(tag/branch)로 stable/latest 채널 분리 가능.
- **업데이트 알림 (SessionStart 훅, 0.2.0+):** `update-check.sh`가 세션 시작 시 원격 최신 릴리스 태그(`vX.Y.Z`)와 설치 버전을 비교해, 뒤처졌으면 *"업데이트 가능"* 한 줄을 알린다 — **알림-only(코드 자동변경 없음)**, 하루 1회·`git ls-remote` 4s timeout·오프라인이면 graceful silent. 적용은 사용자가 `/plugin marketplace update` → `/plugin update ksi-harness`로 직접 한다. **그래서 릴리스 때 반드시 태그를 푼다:** `git tag vX.Y.Z && git push origin vX.Y.Z`(태그가 없으면 알림이 비교할 기준이 없다). dangerous mode 하네스에서 원격 코드를 검토 없이 자동 pull·실행하는 건 공급망 위험이라 **의도적으로 자동적용을 하지 않는다**.

## 멀티머신 동기화 (한 줄)
다른 머신에서 새 버전이 push되면, repo clone에서 한 줄로 받는다 — repo 최신화 + 플러그인 갱신 + 훅 회귀까지:
```
bash scripts/sync-machine.sh        # 모드 자동 감지 (Windows는 git-bash에서)
```
- **플러그인 머신**(예: Windows): `marketplace update` + `plugin update`(적용은 Claude Code 재시작 후) + dist 훅 회귀 — 이 머신 bash/python3 이식성까지 한 번에 검증.
- **native 머신**(`~/.claude` 직접 운용): pull로 들어온 plugin/template 변경의 **패리티 확인 목록**을 출력하고(자동 복사는 안 함 — 로컬 스킬은 도메인 예시 유지가 정상), **로컬 `~/.claude/hooks`를 실측**으로 회귀.
- 강제 지정: `--plugin` / `--native`.

## 훅 행동 회귀 테스트
훅을 수정했거나 새 머신(Windows git-bash 포함)에 깔았으면 한 번 돌린다 — 합성 repo+transcript로 **전 훅(검증 게이트 6 + goal-ledger 넛지)의 발화/침묵 케이스**를 검사(ruff·pip-audit 미설치 머신은 해당 케이스 SKIP):
```
scripts/test-hooks.sh          # ✅ 전체 통과 가 나와야 함
```

## 재사용 감사 루프 (audit-loop workflow)
`templates/workflows/audit-loop.js` = codebase-audit·ui-audit의 fan-out→adversarial verify→critic(검증 후 재투입) 루프를 코드로 박은 골격. `~/.claude/workflows/`(개인) 또는 프로젝트 `.claude/workflows/`에 복사하면, 매 감사마다 pipeline을 재작성하지 않고 `units`(키+프롬프트)와 dial만 넘겨 호출한다. 자세한 args는 파일 상단 주석.

## tier 검증 골격 (paired-run workflow)
`templates/workflows/paired-run.js` = 새 모델 출시 때 "tier X가 렌즈 Z에서 tier Y를 대체할 수 있나"를 싸게 답하는 골격. 같은 unit을 challenger(기본 sonnet)·reference(기본 opus)로 **동일 프롬프트** 분석 → reviewer가 reference-only finding을 코드로 재검증(환각 제외)해 진짜 recall gap만 집계하고 verdict(material_gap/minor_gap/challenger_sufficient)를 반환한다. audit-loop(버그 *발견*)과 shape가 다른 *tier 라우팅 검증* 도구. `units`+`context`(렌즈 spec·통제 핵심)+`lens`+dial(challengerModel·referenceModel)만 넘긴다. 자세한 args는 파일 상단 CONTRACT 주석.

## 배포 전 검증 (repo **루트의 부모** 디렉토리에서 실행)
```
claude plugin validate ./ksi-claude-harness/plugins/ksi-harness   # 플러그인 매니페스트
claude plugin validate ./ksi-claude-harness                       # 마켓플레이스 root
/plugin marketplace add ./ksi-claude-harness                      # 로컬 설치 테스트
```
(repo 루트 안에서라면 `claude plugin validate .` 이 마켓플레이스, `claude plugin validate ./plugins/ksi-harness` 가 플러그인.)

## 안 들어있는 것 (의도적 — 프라이버시)
개인 메모리(프로필·진행 프로젝트·이메일·플랜·머신정보), MCP auth 캐시, credentials, 세션 기록은 **전부 제외**. 이 repo는 골격만이다.
