export const meta = {
  name: 'audit-loop',
  description: '재사용 감사 루프 — analyze fan-out → adversarial verify → critic(검증 후 재투입) → 수렴. codebase-audit/ui-audit §0.5의 실행형 골격.',
  whenToUse: '병렬 감사가 필요할 때 매번 pipeline을 재작성하지 말고 units(키+프롬프트)와 dial만 args로 넘긴다.',
}

// ==== LOOP CONTRACT (SSOT — codebase-audit/ui-audit 스킬 산문은 의미를 재명세하지 말고 여기를 참조) ====
//  survivor   = verdict ≠ 'refuted' 인 finding (verify 실패=error 는 confirmed 아님 → degraded 버킷).
//  verify 트리거 = verifySeverities(기본 critical/high). 미트리거 = 'unverified'(정책 skip, 실패 아님).
//  verify 실패(throw/rate-limit) = 'error' → degraded[]에 격리, counts에 confirmed로 세지 않음, return.degraded=true.
//  정지       = critic 무소득 또는 round == maxRounds(기본 2 · 천장 4, dial). 남은 미탐색 단위 = units_deferred.
//  tier       = analyze:sonnet(dial) · verify/critic:reviewer(opus·xhigh·read-only, 부재 시 opus 폴백).
// ====

// ---- args (dial) ----
// units: [{key, prompt}]  필수 — 단위별 분석 지시(출력 지시는 불필요, 스키마가 강제).
// context: 모든 에이전트 프롬프트 앞에 붙는 공통 맥락(제품·페르소나·경로·design-side spec). 강력 권장.
// analyzeModel='sonnet'  (alias만 — 풀 ID 금지)
// reviewerAgent='reviewer' (기본) — verify·critic을 reviewer 서브에이전트(opus·xhigh·read-only)로 라우팅: frontmatter가
//   effort·read-only를 고정해 비-ultracode 세션에서도 xhigh로 검증. false면 model 기반(verifyModel/criticModel)으로 폴백.
// verifyModel='opus' | criticModel='opus' — reviewerAgent=false일 때만 쓰는 폴백 모델.
// maxRounds — critic 재투입 포함 상한: 기본 2, 천장 4(스킬 문서의 '상한 2'는 기본값 서술). verifySeverities=['critical','high'] — verify 트리거(dial).
// critic=true — false면 critic 생략(작은 감사).
// args가 JSON-encoded 문자열로 도착하는 호출 경로 방어(스모크 런에서 실측된 함정)
let A = args || {}
if (typeof A === 'string') {
  try { A = JSON.parse(A) } catch (e) { return { error: 'args가 문자열인데 JSON 파싱 실패 — 객체로 넘기거나 유효한 JSON으로' } }
}
const units0 = Array.isArray(A.units) ? A.units.filter((u) => u && u.key && u.prompt) : []
if (!units0.length) return { error: 'args.units가 비어 있음 — [{key, prompt}] 필요' }
const CTX = A.context || ''
const analyzeModel = A.analyzeModel || 'sonnet'
const verifyModel = A.verifyModel || 'opus'
const criticModel = A.criticModel || 'opus'
const maxRounds = Math.max(1, Math.min(4, A.maxRounds || 2))
const verifySev = Array.isArray(A.verifySeverities) ? A.verifySeverities : ['critical', 'high']
const useCritic = A.critic !== false
// batchSize: 한 라운드의 analyze fan-out을 N개 단위씩 끊어 실행(청크 사이 barrier) — 동시
// 실행 에이전트 수를 줄여 API rate-limit(TPM/ITPM) cascade 실패를 회피. 기본=전체(끊지 않음, 종전 동작).
const batchSize = Math.max(1, A.batchSize || units0.length)
// verify/critic = reviewer tier(opus·xhigh·read-only). reviewerAgent=false면 처음부터 model 기반.
const reviewerAgent = A.reviewerAgent === undefined ? 'reviewer' : A.reviewerAgent
// reviewer로 실행하되 미설치·미해석(agentType 미등록)이면 model 기반 opus로 폴백 —
// verify가 silent no-op(미검증 finding을 그냥 confirmed)으로 무너지지 않게(가짜 green 방지).
const reviewAgent = (prompt, label, phase, schema, fallbackModel) =>
  reviewerAgent
    ? agent(prompt, { label, phase, schema, agentType: reviewerAgent }).catch(() => agent(prompt, { label, phase, schema, model: fallbackModel }))
    : agent(prompt, { label, phase, schema, model: fallbackModel })

const FINDINGS = {
  type: 'object',
  additionalProperties: false,
  required: ['summary', 'findings'],
  properties: {
    summary: { type: 'string', description: '이 단위의 전반 평가 1~3문장 (한국어)' },
    findings: {
      type: 'array',
      maxItems: 12,
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'severity', 'where', 'evidence', 'impact', 'recommendation', 'confidence'],
        properties: {
          title: { type: 'string' },
          severity: { enum: ['critical', 'high', 'medium', 'low'] },
          where: { type: 'string', description: '파일:줄 또는 화면/위치' },
          evidence: { type: 'string', description: '실제로 읽고 본 것 — 추측 금지, 불확실하면 confidence를 낮춰 명시' },
          impact: { type: 'string' },
          recommendation: { type: 'string' },
          confidence: { enum: ['high', 'medium', 'low'] },
        },
      },
    },
  },
}

const VERDICT = {
  type: 'object',
  additionalProperties: false,
  required: ['verdict', 'corrected_severity', 'note'],
  properties: {
    verdict: { enum: ['confirmed', 'refuted', 'adjust'], description: 'confirmed=실재·심각도 적정, adjust=실재하나 심각도/표현 수정, refuted=환각·오류·재현불가' },
    corrected_severity: { type: ['string', 'null'], enum: ['critical', 'high', 'medium', 'low', null] },
    note: { type: 'string', description: '검증 근거 (실제 재확인 결과, 한국어)' },
  },
}

const CRITIC = {
  type: 'object',
  additionalProperties: false,
  required: ['missed_findings', 'unexplored_units'],
  properties: {
    missed_findings: { type: 'array', maxItems: 8, items: FINDINGS.properties.findings.items },
    unexplored_units: {
      type: 'array',
      maxItems: 6,
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['key', 'prompt'],
        properties: {
          key: { type: 'string' },
          prompt: { type: 'string', description: '다음 라운드 분석 지시(공통 context는 자동으로 앞에 붙음)' },
        },
      },
    },
  },
}

const keyOf = (f) => `${f.title}@@${f.where}`
const seen = new Set()
const confirmed = []
const refuted = []
const degraded = [] // verify가 throw/실패한 finding — confirmed로 세지 않는다(가짜 green 방지 · LOOP CONTRACT)

const verifyOne = (f, round) =>
  reviewAgent(
    `${CTX}
## adversarial 검증 — 반증을 시도하라
아래 finding이 실재하는지 회의적으로 재검증한다. 인용된 파일/근거를 직접 다시 열어 확인하고 환각·과장·심각도 오류를 잡는다.
기본 태도는 의심 — 증거가 약하면 refuted 또는 adjust. 명백히 실재하면 confirmed.

제목: ${f.title}
심각도(주장): ${f.severity}
위치: ${f.where}
증거(주장): ${f.evidence}
영향(주장): ${f.impact}`,
    `verify:${String(f.title).slice(0, 24)}`,
    `Round ${round}`,
    VERDICT,
    verifyModel,
  )
    .then((v) => ({ ...f, verdict: v }))
    .catch(() => {
      log(`  ⚠ verify 실패: "${String(f.title).slice(0, 36)}" — rate-limit/세션한도 추정 → DEGRADED(미검증, confirmed 아님)`)
      return { ...f, verdict: { verdict: 'error', corrected_severity: null, note: 'verify 호출 실패(throw) — 미검증' } }
    })

// LOOP CONTRACT: refuted→버림, verify 실패(error/null)→degraded, 그 외(confirmed/adjust/unverified)→confirmed
const absorb = (f, unit) => {
  const v = f.verdict
  if (v && v.verdict === 'refuted') refuted.push({ ...f, unit })
  else if (!v || v.verdict === 'error') degraded.push({ ...f, unit, final_severity: f.severity })
  else confirmed.push({ ...f, unit, final_severity: (v.verdict === 'adjust' && v.corrected_severity) || f.severity, verify_state: v.verdict })
}

const coveredUnits = []
let pending = units0
let round = 0

while (pending.length && round < maxRounds) {
  round++
  phase(`Round ${round}`)
  log(`Round ${round}: ${pending.length}개 단위 분석 (analyze=${analyzeModel}, verify=${verifyModel})`)
  coveredUnits.push(...pending.map((u) => u.key))

  // canonical no-barrier: 단위별로 분석이 끝나는 즉시 그 단위의 verify가 돈다.
  // batchSize로 동시 분석 단위 수를 제한(청크 사이는 barrier) — API rate-limit cascade 회피.
  const analyzeStage = (u) =>
    agent(`${CTX}\n${u.prompt}`, { label: `analyze:${u.key}`, phase: `Round ${round}`, schema: FINDINGS, model: analyzeModel })
  const verifyStage = (r, u) => {
    if (!r) return { unit: u.key, findings: [] }
    const fresh = (r.findings || []).filter((f) => !seen.has(keyOf(f)))
    fresh.forEach((f) => seen.add(keyOf(f)))
    const toV = fresh.filter((f) => verifySev.includes(f.severity))
    const rest = fresh.filter((f) => !verifySev.includes(f.severity)).map((f) => ({ ...f, verdict: { verdict: 'unverified', corrected_severity: null, note: 'verify 트리거 미해당(dial)' } }))
    if (!toV.length) return { unit: u.key, findings: rest }
    return parallel(toV.map((f) => () => verifyOne(f, round))).then((vs) => ({ unit: u.key, findings: [...vs.filter(Boolean), ...rest] }))
  }
  for (let i = 0; i < pending.length; i += batchSize) {
    const chunk = pending.slice(i, i + batchSize)
    if (pending.length > batchSize) log(`  배치 ${Math.floor(i / batchSize) + 1}/${Math.ceil(pending.length / batchSize)}: ${chunk.map((u) => u.key).join(', ')}`)
    const res = await pipeline(chunk, analyzeStage, verifyStage)
    for (const r of res.filter(Boolean)) for (const f of r.findings) absorb(f, r.unit)
  }

  pending = []
  if (useCritic) {
    const cr = await reviewAgent(
      `${CTX}
## 완성도 critic — 빠진 게 뭔가
지금까지 분석한 단위: ${coveredUnits.join(', ')}
확정 findings 제목: ${confirmed.map((f) => f.title).join(' | ') || '(없음)'}
안 본 단위·미검증 주장·안 돌린 렌즈를 재점검하라. 새 finding은 missed_findings로(직접 확인한 것만 — 추측 금지),
추가 분석이 필요한 단위는 unexplored_units로(이미 본 단위 재탕 금지). 없으면 둘 다 빈 배열.`,
      `critic:r${round}`,
      `Round ${round}`,
      CRITIC,
      criticModel,
    ).catch(() => null)

    if (cr) {
      // critic 산출물도 verify 재통과 — 무검증 채택 금지(§5)
      const fresh = (cr.missed_findings || []).filter((f) => !seen.has(keyOf(f)))
      fresh.forEach((f) => seen.add(keyOf(f)))
      if (fresh.length) {
        log(`critic이 새 finding ${fresh.length}건 → verify 재통과`)
        const vs = (await parallel(fresh.map((f) => () => verifyOne(f, round)))).filter(Boolean)
        for (const f of vs) absorb(f, 'critic')
      }
      pending = (cr.unexplored_units || []).filter((u) => u && u.key && u.prompt && !coveredUnits.includes(u.key))
      if (pending.length && round < maxRounds) log(`critic이 미탐색 ${pending.length}개 단위 반환 → Round ${round + 1} 재투입`)
      else if (!fresh.length && !pending.length) log('critic 무소득 → 수렴, 정지')
    }
  }
}

const rank = { critical: 0, high: 1, medium: 2, low: 3 }
confirmed.sort((a, b) => (rank[a.final_severity] ?? 9) - (rank[b.final_severity] ?? 9))
degraded.sort((a, b) => (rank[a.final_severity] ?? 9) - (rank[b.final_severity] ?? 9))

// LOOP CONTRACT: degraded(verify 실패)가 1건이라도 있으면 결과는 DEGRADED — 위임자는 낙관 top-line을 보류한다.
if (degraded.length) log(`⚠ DEGRADED: ${degraded.length}건이 verify 실패로 미검증 — confirmed로 세지 않음. 낙관 결론 보류 권장.`)
if (pending.length) log(`⚠ 미탐색 단위 ${pending.length}개 남음(maxRounds 도달) → units_deferred`)

return {
  rounds: round,
  degraded: degraded.length > 0, // true면 verify 부분실패 — 낙관 결론 relay 금지(green≠작동)
  incomplete_coverage: pending.length > 0, // true면 critic이 반환한 단위를 maxRounds로 다 못 봄
  units_covered: coveredUnits,
  units_deferred: pending.map((u) => u.key),
  counts: {
    confirmed: confirmed.length,
    refuted: refuted.length,
    verify_failed: degraded.length,
    by_verdict: {
      verified: confirmed.filter((f) => f.verify_state === 'confirmed').length,
      adjusted: confirmed.filter((f) => f.verify_state === 'adjust').length,
      unverified_skipped: confirmed.filter((f) => f.verify_state === 'unverified').length,
    },
    by_severity: {
      critical: confirmed.filter((f) => f.final_severity === 'critical').length,
      high: confirmed.filter((f) => f.final_severity === 'high').length,
      medium: confirmed.filter((f) => f.final_severity === 'medium').length,
      low: confirmed.filter((f) => f.final_severity === 'low').length,
    },
  },
  findings: confirmed,
  degraded_findings: degraded, // verify 실패로 미검증 — 별도 추적(confirmed와 분리)
  refuted,
}
