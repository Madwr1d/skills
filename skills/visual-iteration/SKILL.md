---
name: visual-iteration
description: Use when an AI agent must get something *visually* right — a web page's design/layout/CSS, or a 3D scene/game's character, mesh, texture, or placement — and cannot judge it from code alone. Establishes the render → see → compare-to-reference → fix → re-render loop: deterministically render ONE frame, actually look at it (read the image), compare against reference images or a written style brief, and iterate until it matches. Covers web (any framework) and WebGL/Three.js/canvas scenes.
---

# Visual Iteration — let the AI see what it builds

Code review cannot tell you whether a button is misaligned, a texture looks
plastic, a character's hat is floating off its head, or a hero section feels
cramped. **You have to look.** This skill is the disciplined loop for doing that:
render a single deterministic frame, view it, compare it to the target, change
the code, render again — until the pixels match the intent.

It works for two cases:
- **Web / UI design** — layout, spacing, typography, color, responsive behavior.
- **3D / game / canvas** — character look, mesh/texture quality, object placement,
  lighting, camera framing (Three.js, react-three-fiber, raw WebGL, `<canvas>`).

## The loop

1. **Define the target.** Either reference image(s) (a mockup, a competitor, a
   real photo) or a written brief ("warm, editorial, lots of whitespace; the CTA
   must dominate"). Be explicit about what "correct" means *before* rendering.
2. **Render ONE frame deterministically** (see `scripts/visual-capture.mjs`).
   Determinism is everything — same input must produce a pixel-comparable output
   every run, or you can't tell whether your edit helped.
3. **Look at it.** Read the PNG into context. Describe what you actually see —
   not what you intended. Name specific defects with their location.
4. **Compare to the target.** If you have a reference image, view both and list
   concrete differences (position, scale, color, density, mood). If you have a
   brief, score the frame against each requirement.
5. **Make ONE focused change**, then re-render the *same* station/viewport and
   compare before/after. Loop until it matches. Stop when defects are gone, not
   when you're tired.

## Rendering deterministically

The #1 mistake is comparing two frames that differ for reasons other than your
edit. Pin everything that isn't under test:

- **Fixed viewport / window size** (e.g. 1600×900). Never rely on the default.
- **Fixed camera** for 3D — capture from named "stations" (a fixed
  position+target+FOV passed via URL query), so every run of a station is
  comparable. Don't free-fly the camera between captures.
- **Freeze time / animation** — pin the clock, freeze the sim at a fixed t,
  fix any RNG seed, disable network/live data (`?nonet`), hide cursors/HUD.
- **Wait for "ready"** — expose a `window.__captureReady` flag your app sets when
  fonts, textures, avatars, and async data have all settled, then `waitFor` it
  plus a short settle delay. Screenshotting too early is the #2 mistake.
- **Clip to the region under test** — screenshot just the canvas / the component,
  not the whole chrome, so diffs aren't dominated by irrelevant UI.

## ⚠️ GPU caveat (critical for 3D / post-processing)

Headless Chrome on Linux/CI often falls back to **SwiftShader** (software WebGL,
~2 fps) whose **post-processing output differs from a real GPU** — bloom, SSAO,
tone-mapping, and antialiasing will not match what users see. **Never
vision-tune a 3D scene against a software-rendered frame.** Render against a real
GPU:

- On WSL/Windows, drive the Windows-side `chrome.exe --headless=new` (it sees the
  discrete GPU via D3D11) over CDP, instead of Linux-side headless. The capture
  script supports `--chrome <path>` + CDP for exactly this.
- Confirm the renderer per frame via `WEBGL_debug_renderer_info` and record it in
  the manifest — if it says "SwiftShader", your post-FX critique is invalid.

For plain web/UI (no WebGL post-processing), the bundled Playwright chromium is
fine.

## Comparing to references

- **Reference images:** load the reference and your render together and diff them
  *verbally* — "logo is ~40px too low and too warm; reference is cooler and
  tighter." Pixel-diff tools help for regressions but the AI's own visual
  judgment is what catches design problems.
- **Reference video / style words:** sample a frame or two from the video, or
  turn the brief into a checklist, and grade each render against it.
- **Never claim it looks right without having looked** — read the actual output
  frame first. (See the `verification-before-completion` discipline.)

## Quick start

```bash
# Web page (bundled chromium, clip to a selector):
node scripts/visual-capture.mjs --url http://localhost:3000 \
  --selector "main" --out ./captures/home --settle 1500

# 3D scene at fixed camera stations, real GPU over CDP (WSL example):
node scripts/visual-capture.mjs --url http://localhost:4173 \
  --chrome "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe" \
  --selector ".scene-canvas canvas" --ready __captureReady \
  --stations "cam=0,7,33,0,4,-6,55|cam=5.5,2.4,10.5,1.5,1.8,4.5,45" \
  --out ./captures/scene --settle 3500
```

Then **read each PNG**, compare to your target, edit, and re-run the same command.
The output is pixel-comparable across runs, so before/after tells you the truth.

## Requirements

- Node 18+ and `playwright-core` (or `playwright`) available.
- The thing under test served locally (dev server or `build && preview`).
- For real-GPU 3D: a Chrome/Chromium binary with GPU access.
