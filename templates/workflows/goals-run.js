export const meta = {
  name: 'goals-run',
  description: '자율 척추 — .ksi 원장의 actionable 목표를 evidence-gate로만 소진하는 실행형 루프. "모두 진행" 수동 반복을 구조적으로 없앤다. 종료는 모델 자기선언이 아니라 원장 상태(actionable==0). goals SKILL.md `/goals run`의 실물화(nextgen 1순위).',
  whenToUse: '프로젝트에 .ksi 원장이 있고 여러 목표를 자율로 완결하고 싶을 때. args: {dir(프로젝트 경로 필수), maxGoals(세션당 상한, 기본 6 — 마라톤 방지 세션-경계 stitching), context(공통 맥락)}. red-lane(push·배포·마이그·자금경로·비밀)은 자동 실행 안 하고 멈춰 사람에게 넘긴다.',
  phases: [
    { title: 'Run', detail: 'status→start→작업→attempt→reviewer gate 루프(원장 소진까지·세션예산까지)' },
  ],
}

// ==== RUN CONTRACT (SSOT — goals SKILL.md 산문은 여기를 참조) ====
//  종료 = 원장의 actionable==0(게이트통과/blocked/abandoned) OR 세션예산(maxGoals) 도달. 모델 자기선언 종료 금지.
//  세션-경계 stitching = 마라톤 금지. maxGoals 도달하면 원장에 상태 flush돼 있으므로 깨끗이 suspend,
//    다음 세션이 goal-status.sh brief로 복원해 이어감(원장이 SSOT). 단일 장기루프로 compaction 쌓지 않는다.
//  red-lane 하드스톱 = 목표가 push/deploy/migration/자금경로/secret/외부전송이면 자동 실행 안 함 —
//    needsHuman으로 격리하고 스킵(bypassPermissions 상시 + 되돌리기 게이트[자율성 ①]. worktree primitive는
//    미검증이라 의존하지 않는다 — red는 격리가 아니라 '사람에게 넘김'으로 처리).
//  evidence-gate = reviewer가 criteria 대비 증거를 adversarial 검증. refuted면 gate 안 통과 → 그 목표는
//    actionable로 남지만, 같은 목표 attempt N회 실패면 무한루프 방지로 skip(needsHuman).
//  self-report 불신 = worker "완료" 선언이 아니라 reviewer 게이트통과만 completed. ksi-goals가 코드로 강제.
// ====

let A = args || {}
if (typeof A === 'string') {
  try { A = JSON.parse(A) } catch (e) { return { error: 'args가 문자열인데 JSON 파싱 실패 — {dir, maxGoals?, context?} 객체 필요' } }
}
const DIR = A.dir
if (!DIR) return { error: 'args.dir(프로젝트 경로) 필수 — .ksi 원장이 있는 프로젝트 루트' }
const CTX = A.context || ''
const maxGoals = Math.max(1, Math.min(20, A.maxGoals || 6)) // 세션 예산(마라톤 방지). 천장 20.
const maxAttemptsPerGoal = 2 // 같은 목표 반복 실패 시 skip(무한루프 방지)
const G = `python3 ~/.claude/scripts/ksi-goals.py --dir ${JSON.stringify(DIR)}`

// red-lane 어휘 — 되돌리기 어렵거나 외부영향. 목표 title/criteria에 걸리면 자동 실행 금지.
const RED = /push|deploy|배포|출시|release|migrat|마이그|백필|backfill|rollback|롤백|payment|결제|과금|billing|refund|환불|payout|정산|withdraw|출금|mainnet|메인넷|실거래|live[\s_-]?trad|secret|비밀|\.env|credential|rotate|외부\s?전송|prod(uction)?\b/i

const STATUS_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['done', 'actionable', 'counts'],
  properties: {
    done: { type: 'boolean' },
    counts: { type: 'object', additionalProperties: true },
    actionable: {
      type: 'array', items: {
        type: 'object', additionalProperties: false, required: ['id', 'title', 'status'],
        properties: { id: { type: 'string' }, title: { type: 'string' }, status: { type: 'string' }, attempt: { type: 'integer' }, criteria: { type: 'array', items: { type: 'string' } }, evidence: { type: ['string', 'null'] } },
      },
    },
  },
}

const WORK_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['goal_id', 'did', 'evidence_ref', 'self_status'],
  properties: {
    goal_id: { type: 'string' },
    did: { type: 'string', description: '실제 수행한 변경 요약' },
    evidence_ref: { type: 'string', description: 'file:line·테스트결과 등 검증 대상 근거(추측 금지)' },
    self_status: { enum: ['attempted', 'blocked', 'needs_human'], description: 'attempted=증거 붙여 게이트로 · blocked=의존성 대기 · needs_human=되돌리기 어려움/판단 필요' },
    block_reason: { type: 'string' },
  },
}

const GATE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['verdict', 'reason'],
  properties: {
    verdict: { enum: ['pass', 'refuted', 'degraded'], description: 'pass=criteria 충족 실증 · refuted=미충족/환각 · degraded=검증 불완전(rate-limit 등)' },
    reason: { type: 'string', description: '실제 근거 파일을 다시 열어 확인한 결과' },
  },
}

phase('Run')
log(`goals-run: ${DIR} — 세션 예산 ${maxGoals} 목표. 종료=원장 actionable 0 또는 예산 도달(마라톤 방지).`)

// 원장 상태를 기계판독으로 읽는 헬퍼(scout tier — 단순 CLI 실행+파싱).
const readStatus = () =>
  agent(`${DIR}의 goals 원장 상태를 읽어라. 정확히 이 명령을 Bash로 실행하고 그 JSON을 그대로 반환:\n\`${G} status --json\`\n출력 JSON을 스키마대로 반환하라(가공·추측 금지 — CLI 출력 그대로).`,
    { label: 'status', phase: 'Run', model: 'haiku', schema: STATUS_SCHEMA })

const done = []
const skipped = []       // red-lane·반복실패·blocked
const attemptsById = {}
let processed = 0

while (processed < maxGoals) {
  const st = await readStatus()
  if (!st || st.done || !(st.actionable || []).length) {
    log(`원장 actionable 0 — 완료(원장 상태 기준, 모델 선언 아님).`)
    break
  }
  // 아직 skip 안 한 것 중 다음
  const next = st.actionable.find((g) => !skipped.some((s) => s.id === g.id))
  if (!next) { log('남은 actionable이 전부 skip 대상(red-lane/반복실패) — 사람 처리 필요, 종료.'); break }

  // red-lane 하드스톱 — 자동 실행 금지.
  const redHit = RED.test(next.title) || (next.criteria || []).some((c) => RED.test(c))
  if (redHit) {
    skipped.push({ id: next.id, title: next.title, why: 'red-lane(되돌리기 어려움/외부영향) — 자동 실행 안 함, 사람 확인 필요' })
    log(`⛔ red-lane 스킵: [${next.id}] ${next.title} — 사람에게 넘김(push/배포/마이그/자금/비밀류).`)
    continue
  }

  attemptsById[next.id] = (attemptsById[next.id] || 0) + 1
  if (attemptsById[next.id] > maxAttemptsPerGoal) {
    skipped.push({ id: next.id, title: next.title, why: `${maxAttemptsPerGoal}회 시도 후 게이트 미통과 — 무한루프 방지 skip, 사람 처리` })
    log(`↷ 반복실패 스킵: [${next.id}] ${next.title}`)
    continue
  }

  processed++
  log(`▶ [${next.id}] ${next.title} (attempt ${attemptsById[next.id]}/${maxAttemptsPerGoal})`)

  // 작업 — worker tier(sonnet high). start → 실제 구현 → attempt --evidence.
  const work = await agent(`${CTX}

## goals-run 작업 — 프로젝트 ${DIR}, 목표 [${next.id}] "${next.title}"
완료기준: ${(next.criteria || []).join(' / ') || '(명시 없음 — title 기준 합리적 판단)'}

임무: 이 목표를 실제로 구현한다(코드 변경·테스트). 규율:
- 먼저 Bash로 \`${G} start --id ${next.id}\`(이미 in_progress면 무해).
- 실제 코드를 읽고 변경하라(Edit/Write). "green≠작동" — 테스트·타입체크를 실제로 돌려 통과를 확인하고, 픽스처가 실제 흐름을 우회하지 않는지 본다.
- **되돌리기 어렵거나 외부영향(push·배포·DB 마이그레이션 실행·비밀변경·외부전송·자금경로)이면 그 부분은 하지 말고 self_status='needs_human'으로 반환**(이 루프는 그런 걸 자동 실행하지 않는다).
- 끝나면 \`${G} attempt --id ${next.id} --evidence "<검증한 실제 근거>"\`로 증거를 원장에 기록(이게 있어야 게이트가 돈다).
- evidence_ref엔 reviewer가 재확인할 수 있는 구체 근거(file:line·테스트 출력)를 담아라 — 추측·자기선언 금지.`,
    { label: `work:${next.id}`, phase: 'Run', model: 'sonnet', schema: WORK_SCHEMA })

  if (!work || work.self_status === 'needs_human') {
    skipped.push({ id: next.id, title: next.title, why: (work && work.block_reason) || 'worker가 needs_human 판정(되돌리기 어려움/판단 필요)' })
    log(`⛔ worker→needs_human: [${next.id}] — 사람에게 넘김.`)
    // 원장은 in_progress로 남음(다음 세션 복원). block 처리는 사람 몫.
    continue
  }
  if (work.self_status === 'blocked') {
    await agent(`Bash로 실행: \`${G} block --id ${next.id} --reason ${JSON.stringify((work.block_reason || 'dependency').slice(0, 120))}\``, { label: `block:${next.id}`, phase: 'Run', model: 'haiku' }).catch(() => {})
    skipped.push({ id: next.id, title: next.title, why: 'blocked: ' + (work.block_reason || '') })
    continue
  }

  // evidence-gate — reviewer(opus xhigh read-only)가 criteria 대비 증거를 adversarial 검증.
  const gate = await agent(`${CTX}

## goals-run evidence-gate — 목표 [${next.id}] "${next.title}"
완료기준: ${(next.criteria || []).join(' / ') || '(title 기준)'}
worker가 한 것: ${work.did}
worker가 댄 증거: ${work.evidence_ref}

임무: 이 목표가 **실제로** 완료기준을 충족했는지 회의적으로 검증하라. worker의 self-report·증거 인용을 믿지 말고 **실제 파일을 다시 열어 확인**한다. criteria가 코드/테스트로 실증되면 pass, 미충족·환각·픽스처 우회면 refuted, 검증이 rate-limit 등으로 불완전하면 degraded. 기본자세는 의심.`,
    { label: `gate:${next.id}`, phase: 'Run', agentType: 'reviewer', schema: GATE_SCHEMA })

  const verdict = (gate && gate.verdict) || 'degraded'
  // 게이트 결과를 원장에 기록(pass만 completed로 봉인 — 코드가 강제). reviewer 라벨은 실제 검증 tier.
  await agent(`Bash로 실행(그대로): \`${G} gate --id ${next.id} --verdict ${verdict} --reviewer reviewer-opus --evidence-ref ${JSON.stringify((work.evidence_ref || '').slice(0, 160))}\`\n출력을 그대로 반환.`,
    { label: `record:${next.id}`, phase: 'Run', model: 'haiku' }).catch(() => {})

  if (verdict === 'pass') {
    done.push({ id: next.id, title: next.title })
    log(`✓ [${next.id}] 게이트 통과 → completed.`)
  } else {
    log(`✗ [${next.id}] ${verdict} — ${(gate && gate.reason || '').slice(0, 100)} (원장에 남아 재시도/사람)`)
    // refuted/degraded면 다음 루프에서 같은 목표 재선택 → attempt 카운터가 무한루프 방지.
  }
}

const fin = await readStatus().catch(() => null)
const remaining = fin ? (fin.actionable || []).length : '?'
if (processed >= maxGoals && remaining && remaining !== 0) {
  log(`⏸ 세션 예산(${maxGoals}) 도달 — 남은 actionable ${remaining}개는 다음 세션이 이어간다(원장이 SSOT, 마라톤 방지 suspend).`)
}
if (skipped.length) log(`⚠ 사람 처리 필요 ${skipped.length}건(red-lane/반복실패/needs_human) — 아래 목록.`)

return {
  project: DIR,
  completed_this_session: done,
  needs_human: skipped,
  remaining_actionable: remaining,
  suspended: processed >= maxGoals && remaining !== 0,
  note: '완료=reviewer 게이트통과만(원장 상태 기준). red-lane·되돌리기 어려운 건 자동 실행 안 하고 needs_human으로 격리. 다음 세션은 goal-status.sh가 복원.',
}
