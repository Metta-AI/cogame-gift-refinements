#!/usr/bin/env node
// DOM text smoke: the chrome's STRINGS, measured, at every viewport that
// matters.
//
// Goes to:  tools/ci/dom_text_smoke.mjs  in the coworld repo.
// Runs in:  ci.yml's `wasm-viewer` job, right after viewer_smoke.mjs.
//
// WHY (collab-cooking, 2026-08-25)
// --------------------------------
// `viewer_smoke.mjs --strict-text-bounds` watches the CANVAS. The chrome that
// carries this game's LLM text -- the feed rows, the trust-graph rows, the
// roster chips -- is DOM, and a DOM string that overflows its box is clipped
// silently: the page still loads, the screenshot still looks plausible, and
// the featured-match iframe shows "CYR · …" where a policy name should be.
//
// This opens the worst-case renderer fixture at 13 viewports down to 360 px
// and asserts, at each one:
//   * the feed rows, the feed's EXPANDED `notes` row, the trust-graph rows and
//     the roster chips EXIST;
//   * every one of them has its FULL string (nothing was cut server-side or by
//     a JS slice -- CSS ellipsis is fine, a truncated textContent is not);
//   * no row overflows its own box (scrollWidth <= clientWidth + 1) UNLESS it
//     opted into `text-overflow: ellipsis`, which is a deliberate degrade;
//   * nothing that must stay readable is zero-sized or off-screen.
//
// USAGE
//   node tools/ci/dom_text_smoke.mjs --url <fixture url> [--timeout 60]
//   node tools/ci/dom_text_smoke.mjs --url <url> --out <dir>
//
// EXIT CODES
//   0  every viewport passed; a JSON line on stdout and dom-text-smoke.json saved.
//   1  a viewport failed; the offending selectors and measurements are printed.
//   2  bad arguments / missing Playwright.
//
// Playwright is pinned to 1.55.0, module and browser together, exactly as in
// viewer_smoke.mjs.

import { writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

const VIEWPORTS = [
  [1600, 900], [1440, 900], [1280, 800], [1180, 820], [1024, 768],
  [960, 720], [900, 640], [820, 600], [768, 1024], [640, 480],
  [560, 720], [430, 932], [360, 640],
];

function parseArgs(argv) {
  const args = { timeout: 60, out: '.' };
  for (let i = 2; i < argv.length; i++) {
    const key = argv[i];
    if (key === '--url') args.url = argv[++i];
    else if (key === '--timeout') args.timeout = Number(argv[++i]);
    else if (key === '--out') args.out = argv[++i];
    else if (key === '--headed') args.headed = true;
    else {
      console.error(`unknown argument: ${key}`);
      process.exit(2);
    }
  }
  if (!args.url) {
    console.error('usage: dom_text_smoke.mjs --url <fixture url> [--timeout 60]');
    process.exit(2);
  }
  return args;
}

function loadPlaywright() {
  const explicit = process.env.PLAYWRIGHT_MODULE;
  try {
    return require(explicit || 'playwright');
  } catch (error) {
    console.error('Playwright is not installed. Install the pinned pair:');
    console.error('  npm install --no-save playwright@1.55.0');
    console.error('  npx --yes playwright@1.55.0 install --with-deps chromium');
    console.error(String(error));
    process.exit(2);
  }
}

// Runs INSIDE the page.
function measure() {
  const groups = [
    { name: 'feed rows', selector: '.feed-row', minCount: 1 },
    { name: 'expanded notes', selector: '.feed-row.gr-open .gr-notes', minCount: 1 },
    { name: 'trust rows', selector: '#gr-rows .gr-row', minCount: 1 },
    { name: 'roster chips', selector: '.gr-chip', minCount: 6 },
    { name: 'plate names', selector: '.plate .team-name', minCount: 2 },
  ];
  const problems = [];
  const seen = {};
  for (const group of groups) {
    const nodes = Array.from(document.querySelectorAll(group.selector));
    seen[group.name] = nodes.length;
    if (nodes.length < group.minCount) {
      problems.push(`${group.name}: found ${nodes.length}, expected at least ${group.minCount}`);
      continue;
    }
    for (const node of nodes) {
      const style = getComputedStyle(node);
      const rect = node.getBoundingClientRect();
      const text = (node.textContent || '').trim();
      if (!text) {
        problems.push(`${group.name}: an element rendered with no text at all`);
        continue;
      }
      if (rect.width < 1 || rect.height < 1) {
        problems.push(`${group.name}: "${text.slice(0, 24)}" collapsed to ${Math.round(rect.width)}x${Math.round(rect.height)}`);
        continue;
      }
      if (rect.right < 0 || rect.bottom < 0 ||
          rect.left > window.innerWidth || rect.top > window.innerHeight) {
        problems.push(`${group.name}: "${text.slice(0, 24)}" is off-screen`);
        continue;
      }
      // A row that has NOT opted into an ellipsis must fit its own box.
      const ellipsises = style.textOverflow === 'ellipsis' ||
        Array.from(node.querySelectorAll('*')).some(
          (child) => getComputedStyle(child).textOverflow === 'ellipsis');
      if (!ellipsises && node.scrollWidth > node.clientWidth + 1) {
        problems.push(`${group.name}: "${text.slice(0, 24)}" overflows (${node.scrollWidth} > ${node.clientWidth}) with no ellipsis`);
      }
    }
  }
  // The strings themselves must still be FULL length: the cap is the server's
  // job and nothing in the chrome may shorten one further.
  const says = Array.from(document.querySelectorAll('.gr-say'));
  if (!says.length) problems.push('no LLM say row is present');
  for (const say of says) {
    const runes = Array.from((say.textContent || '').replace(/[\u201c\u201d]/g, ''));
    if (runes.length !== 80) {
      problems.push(`a say row carries ${runes.length} runes, expected the full 80`);
    }
  }
  // `notes` is the other LLM-authored string that reaches the chrome, drawn in
  // the feed's expanded row. Same rule: full length, in the box it opened into.
  const notes = Array.from(document.querySelectorAll('.gr-notes'));
  if (!notes.length) problems.push('no LLM notes row is present');
  for (const note of notes) {
    const runes = Array.from(note.textContent || '');
    if (runes.length !== 320) {
      problems.push(`a notes row carries ${runes.length} runes, expected the full 320`);
    }
  }
  return { problems, seen };
}

async function main() {
  const args = parseArgs(process.argv);
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ headless: !args.headed });
  const results = [];
  let failed = 0;
  try {
    for (const [width, height] of VIEWPORTS) {
      const context = await browser.newContext({ viewport: { width, height } });
      const page = await context.newPage();
      const console_messages = [];
      page.on('console', (m) => console_messages.push(`${m.type()}: ${m.text()}`));
      await page.goto(args.url, { waitUntil: 'domcontentloaded' });
      try {
        await page.waitForFunction(
          () => document.documentElement.getAttribute('data-replay-loaded') === 'true' ||
                document.documentElement.hasAttribute('data-replay-error'),
          undefined, { timeout: args.timeout * 1000 });
      } catch (error) {
        console.error(`::error::${width}x${height}: the fixture never signalled`);
        console.error(console_messages.slice(-20).join('\n'));
        failed++;
        await context.close();
        continue;
      }
      const pageError = await page.evaluate(
        () => document.documentElement.getAttribute('data-replay-error'));
      if (pageError) {
        console.error(`::error::${width}x${height}: ${pageError}`);
        failed++;
        await context.close();
        continue;
      }
      const measured = await page.evaluate(measure);
      results.push({ width, height, ...measured });
      if (measured.problems.length) {
        failed++;
        console.error(`::error::${width}x${height}:`);
        for (const problem of measured.problems) console.error(`  ${problem}`);
      } else {
        console.log(`ok ${width}x${height}: ` +
          Object.entries(measured.seen).map(([k, v]) => `${k}=${v}`).join(' '));
      }
      await context.close();
    }
  } finally {
    await browser.close();
  }
  writeFileSync(`${args.out}/dom-text-smoke.json`,
    JSON.stringify({ url: args.url, viewports: results }, null, 2));
  if (failed) {
    console.error(`dom text smoke FAILED at ${failed} of ${VIEWPORTS.length} viewports`);
    process.exit(1);
  }
  console.log(JSON.stringify({ ok: true, viewports: VIEWPORTS.length }));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
