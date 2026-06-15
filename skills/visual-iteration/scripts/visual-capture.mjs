#!/usr/bin/env node
/* visual-capture — render deterministic frames of a web page or WebGL/3D scene
   so an AI can LOOK at its own output and iterate toward a visual target.

   Two modes, one script:
     • Web/UI  — bundled Playwright chromium is fine.
     • 3D/post-FX — drive a real-GPU Chrome over CDP (--chrome), because headless
       SwiftShader renders bloom/SSAO/tonemapping differently than users see.

   Usage:
     node visual-capture.mjs --url http://localhost:3000 [options]

   Options:
     --url <url>          Base URL of the served app (required).
     --out <dir>          Output dir for PNGs + manifest.json (default ./captures/<ts>).
     --selector <css>     Clip screenshot to this element (default: full page).
     --ready <flag>       window flag to await before shooting (e.g. __captureReady).
     --settle <ms>        Extra wait after ready/load for streaming assets (default 1500).
     --viewport <WxH>     Viewport size (default 1600x900).
     --stations <a|b|c>   '|'-separated query strings; one frame each (e.g. 3D camera poses).
                          Each becomes  <url>?<station>  and the file is named station-N.
     --query <qs>         Query string appended to EVERY frame (determinism flags:
                          nonet, freeze, seed, clock, hud=0 …).
     --tag <suffix>       Filename suffix (e.g. "after") for before/after pairs.
     --chrome <path>      Use this Chrome binary over CDP (real GPU) instead of bundled.
     --cdp-port <n>       CDP port for --chrome mode (default 9223).

   The manifest records the resolved URL, file, ready-state, and the WebGL
   renderer per frame — if renderer is "SwiftShader", treat any post-FX critique
   as INVALID and re-shoot with --chrome on a real GPU. */

import { spawn } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
function loadPlaywright() {
  for (const c of ['playwright', 'playwright-core']) {
    try { return require(c) } catch { /* next */ }
  }
  throw new Error('Install Playwright: `npm i -D playwright` (or playwright-core).')
}

function arg(name, dflt) {
  const i = process.argv.indexOf(`--${name}`)
  return i > -1 ? process.argv[i + 1] : dflt
}
const has = (name) => process.argv.includes(`--${name}`)

const URL_ = arg('url')
if (!URL_) { console.error('--url is required'); process.exit(1) }
const OUT = arg('out', `./captures/${new Date().toISOString().slice(0, 16).replace(/[T:]/g, '-')}`)
const SELECTOR = arg('selector', '')
const READY = arg('ready', '')
const SETTLE = Number(arg('settle', 1500))
const [VW, VH] = arg('viewport', '1600x900').split('x').map(Number)
const QUERY = arg('query', '')
const TAG = arg('tag', '')
const CHROME = arg('chrome', '')
const CDP_PORT = Number(arg('cdp-port', 9223))
const stationsArg = arg('stations', '')
const stations = stationsArg ? stationsArg.split('|') : ['']

function buildUrl(station) {
  const parts = [QUERY, station].filter(Boolean)
  return parts.length ? `${URL_}${URL_.includes('?') ? '&' : '?'}${parts.join('&')}` : URL_
}

async function getBrowser(chromium) {
  if (!CHROME) return { browser: await chromium.launch(), chrome: null }
  // Real-GPU path: launch the given Chrome with remote debugging, connect over CDP.
  const chrome = spawn(CHROME, [
    '--headless=new',
    `--remote-debugging-port=${CDP_PORT}`,
    `--window-size=${VW},${VH}`,
    '--hide-scrollbars',
    'about:blank',
  ], { stdio: 'ignore' })
  let browser = null
  for (let i = 0; i < 30 && !browser; i++) {
    browser = await chromium.connectOverCDP(`http://localhost:${CDP_PORT}`).catch(() => null)
    if (!browser) await new Promise((r) => setTimeout(r, 500))
  }
  if (!browser) { chrome.kill(); throw new Error('Could not reach Chrome over CDP — is the binary path right / not blocked?') }
  return { browser, chrome }
}

async function main() {
  mkdirSync(OUT, { recursive: true })
  const ping = await fetch(URL_, { signal: AbortSignal.timeout(5000) }).catch(() => null)
  if (!ping || !ping.ok) throw new Error(`${URL_} is not serving — start your dev server / preview first.`)

  const { chromium } = loadPlaywright()
  const { browser, chrome } = await getBrowser(chromium)
  const ctx = browser.contexts()[0] ?? (await browser.newContext())
  const manifest = []
  try {
    for (let i = 0; i < stations.length; i++) {
      const station = stations[i]
      const page = await ctx.newPage()
      await page.setViewportSize({ width: VW, height: VH })
      const url = buildUrl(station)
      const base = stations.length > 1 ? `station-${i + 1}` : 'frame'
      const file = `${OUT}/${base}${TAG ? `-${TAG}` : ''}.png`
      try {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 })
        if (READY) await page.waitForFunction((f) => window[f], READY, { timeout: 90000 })
        else await page.waitForLoadState('networkidle', { timeout: 30000 }).catch(() => {})
        await page.waitForTimeout(SETTLE)
        const el = SELECTOR ? page.locator(SELECTOR).first() : null
        if (el && await el.count()) await el.screenshot({ path: file })
        else await page.screenshot({ path: file })
        const gpu = await page.evaluate(() => {
          const c = document.createElement('canvas')
          const gl = c.getContext('webgl2') || c.getContext('webgl')
          const ext = gl && gl.getExtension('WEBGL_debug_renderer_info')
          return ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : 'n/a'
        }).catch(() => 'n/a')
        manifest.push({ station: station || '(default)', url, file, gpu })
        const warn = /swiftshader|llvmpipe|software/i.test(String(gpu)) ? '  ⚠ SOFTWARE GPU — post-FX critique invalid' : ''
        console.log(`✓ ${base}  gpu=${gpu}${warn}`)
      } catch (e) {
        manifest.push({ station: station || '(default)', url, file, error: String(e).slice(0, 200) })
        console.error(`✗ ${base}: ${String(e).slice(0, 160)}`)
      } finally {
        await page.close().catch(() => {})
      }
    }
  } finally {
    if (chrome) { try { const s = await browser.newBrowserCDPSession(); await s.send('Browser.close') } catch { /* */ } }
    await browser.close().catch(() => {})
    if (chrome) chrome.kill()
  }
  writeFileSync(`${OUT}/manifest.json`, JSON.stringify(manifest, null, 2))
  const ok = manifest.filter((m) => !m.error).length
  console.log(`\n${ok}/${stations.length} captured → ${OUT}`)
  console.log('Next: read each PNG, compare to your reference/brief, make ONE change, re-run.')
}

main().catch((e) => { console.error(e); process.exit(1) })
