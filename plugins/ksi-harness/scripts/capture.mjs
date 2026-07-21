#!/usr/bin/env node
// capture.mjs — 시각-QA 캡처 러너 (ui-audit §2 local/CI 공용 — 게이트가 아니라 캡처 자체를 싸게).
//
// 픽셀 불변 원칙: 시각 감사의 입력을 바꾸는 최적화(폰트/이미지 차단, scale 축소)는 하지 않는다.
//   싸게 만드는 레버는 픽셀-중립만: 애니메이션 고정(reduced-motion+CSS) · 트래커 차단 · self-nice · 부하 적응 동시성.
// 사용:
//   node ~/.claude/scripts/capture.mjs --pages <pages.json 경로 | '[{"key":"dash","path":"/"}]'>
//     [--base http://localhost:3000] [--out shots] [--viewports mobile-390,tablet-768,desktop-1440|800x600]
//     [--no-fullpage] [--settle 300] [--concurrency N]
// CI: 이 파일을 repo scripts/visual-qa-capture.mjs로 복사해 쓴다(외부 의존 0 — templates/visual-qa.yml 참조).
// playwright 해석: 실행 cwd(프로젝트 루트) 기준 — 프로젝트에 설치된 버전을 쓴다.
// exit: 0=전체 성공, 3=부분 실패(DEGRADED로 보고할 것), 64=usage, 69=playwright 미설치.

import { createRequire } from 'node:module';
import { mkdirSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';

function die(code, msg) { console.error(msg); process.exit(code); }

// --- args ---
const opt = {
  base: process.env.QA_BASE_URL ?? 'http://localhost:3000',
  out: 'shots', viewports: 'mobile-390,tablet-768,desktop-1440',
  fullpage: true, settle: 300, concurrency: 0, pages: null,
};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--base') opt.base = argv[++i];
  else if (a === '--out') opt.out = argv[++i];
  else if (a === '--pages') opt.pages = argv[++i];
  else if (a === '--viewports') opt.viewports = argv[++i];
  else if (a === '--no-fullpage') opt.fullpage = false;
  else if (a === '--settle') opt.settle = Number(argv[++i]);
  else if (a === '--concurrency') opt.concurrency = Number(argv[++i]);
  else die(64, `unknown arg: ${a}\nusage: capture.mjs --pages <pages.json|JSON> [--base URL] [--out DIR] [--viewports ...]`);
}
if (!opt.pages) die(64, 'usage: capture.mjs --pages <pages.json|JSON> [--base URL] [--out DIR] [--viewports ...]');

let pages;
try {
  pages = JSON.parse(opt.pages.trim().startsWith('[') ? opt.pages : readFileSync(opt.pages, 'utf8'));
} catch (e) { die(64, `--pages 해석 실패: ${e.message}`); }
if (!Array.isArray(pages) || pages.length === 0 || !pages.every((p) => p.key && typeof p.path === 'string'))
  die(64, '--pages는 비어있지 않은 [{key, path}] 배열이어야 함');

const PRESETS = {
  'mobile-390': { width: 390, height: 844 },
  'tablet-768': { width: 768, height: 1024 },
  'desktop-1440': { width: 1440, height: 900 },
};
const viewports = opt.viewports.split(',').map((v) => {
  v = v.trim();
  if (PRESETS[v]) return { key: v, ...PRESETS[v] };
  const m = v.match(/^(\d+)x(\d+)$/);
  if (m) return { key: v, width: +m[1], height: +m[2] };
  die(64, `viewport 해석 불가: ${v} (프리셋 ${Object.keys(PRESETS).join('/')} 또는 WxH)`);
});

// 상주 워크로드(dev server·빌드·다른 세션)에 양보 — 캡처는 배치성이라 자기 우선순위를 낮춘다(root 불필요).
try { os.setPriority(10); } catch { /* 비지원 플랫폼 무시 */ }

// 부하 적응 동시성(뷰포트 컨텍스트 단위) — 명시 --concurrency가 우선.
function autoConcurrency() {
  try {
    const ratio = os.loadavg()[0] / os.cpus().length;
    return ratio >= 3 ? 1 : ratio >= 1.5 ? 2 : 3;
  } catch { return 2; }
}
const conc = opt.concurrency > 0 ? opt.concurrency : autoConcurrency();

// playwright는 실행한 프로젝트의 것을 쓴다(이 파일의 위치가 아니라 cwd 기준 해석).
let chromium;
try {
  ({ chromium } = createRequire(path.join(process.cwd(), 'noop.js'))('playwright'));
} catch {
  die(69, 'playwright 모듈을 cwd 기준으로 찾지 못함 — 프로젝트 루트에서 실행하거나 `npm i -D playwright`.');
}

// 픽셀-중립 결정성: 애니메이션·트랜지션·캐럿 고정(시각 회귀 표준 관행 — 렌더 결과 자체는 불변).
const FREEZE_CSS = '*,*::before,*::after{animation-duration:0s!important;animation-delay:0s!important;'
  + 'transition-duration:0s!important;transition-delay:0s!important;caret-color:transparent!important;'
  + 'scroll-behavior:auto!important}';
// 렌더에 관여하지 않는 트래커만 차단(짧은 고신뢰 목록 — 앱 리소스는 절대 차단 안 함).
const TRACKERS = /google-analytics\.com|googletagmanager\.com|sentry\.io|hotjar\.com|segment\.(io|com)|clarity\.ms|doubleclick\.net/;

mkdirSync(opt.out, { recursive: true });
console.log(`capture: ${pages.length}p × ${viewports.length}vp → ${opt.out}/ (base=${opt.base}, concurrency=${conc}, nice=10)`);
const browser = await chromium.launch({ args: ['--disable-dev-shm-usage', '--disable-gpu'] });
const t0 = Date.now();
let shot = 0;
const failed = [];

async function captureViewport(vp) {
  const context = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    reducedMotion: 'reduce',
  });
  await context.route('**/*', (route) =>
    TRACKERS.test(route.request().url()) ? route.abort() : route.continue());
  const page = await context.newPage();
  for (const p of pages) {
    const dest = path.join(opt.out, `${p.key}--${vp.key}.png`);
    try {
      await page.goto(opt.base + p.path, { waitUntil: 'load', timeout: 90_000 });
      await page.addStyleTag({ content: FREEZE_CSS });
      await page.evaluate(() => document.fonts?.ready);
      await page.waitForTimeout(opt.settle);
      await page.screenshot({ path: dest, fullPage: opt.fullpage });
      shot += 1;
    } catch (e) {
      failed.push(`${p.key}--${vp.key}: ${String(e.message).split('\n')[0]}`);
    }
  }
  await context.close();
}

const queue = [...viewports];
await Promise.all(Array.from({ length: Math.min(conc, queue.length) }, async () => {
  while (queue.length) await captureViewport(queue.shift());
}));
await browser.close();

console.log(`capture: ${shot}/${pages.length * viewports.length} shots (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
if (failed.length) {
  console.error(`실패 ${failed.length}건 — 부분 캡처는 DEGRADED로 보고할 것:\n  ${failed.join('\n  ')}`);
  process.exit(3);
}
