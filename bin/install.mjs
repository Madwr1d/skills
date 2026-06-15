#!/usr/bin/env node
/* Installer for Madwr1d's Claude Code skills.
   Copies the bundled skills into ~/.claude/skills so Claude Code picks them up.

   Usage:
     npx madwr1d-skills              # install all skills
     npx madwr1d-skills <name> ...   # install only the named skill(s)
     npx madwr1d-skills --list       # list available skills
*/
import { cpSync, mkdirSync, readdirSync, existsSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const skillsDir = join(here, '..', 'skills')
const dest = join(homedir(), '.claude', 'skills')

const all = readdirSync(skillsDir).filter((n) => statSync(join(skillsDir, n)).isDirectory())
const args = process.argv.slice(2)

if (args.includes('--list') || args.includes('-l')) {
  console.log('Available skills:')
  for (const s of all) console.log('  •', s)
  process.exit(0)
}

const wanted = args.filter((a) => !a.startsWith('-'))
const picked = wanted.length ? all.filter((s) => wanted.includes(s)) : all
if (!picked.length) {
  console.error('No matching skills. Available:', all.join(', '))
  process.exit(1)
}

mkdirSync(dest, { recursive: true })
for (const s of picked) {
  const target = join(dest, s)
  cpSync(join(skillsDir, s), target, { recursive: true })
  console.log(`✓ installed ${s} → ${target}`)
}
console.log(`\nDone. Restart Claude Code (or your agent) to pick up ${picked.length} skill(s).`)
