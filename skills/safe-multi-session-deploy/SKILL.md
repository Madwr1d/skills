---
name: safe-multi-session-deploy
description: Use BEFORE committing or deploying any repo that multiple Claude/agent sessions may share (Vercel/Railway/Node web apps). Prevents the three failure modes of concurrent sessions on one working tree — clobbering another session's unsaved work, deploying to the WRONG linked project, and not knowing which session's build is actually live. Stamps a session-tagged build provenance marker and verifies it post-deploy.
---

# Safe Multi-Session Deploy

When several agent sessions share one working directory (a real situation:
4 sessions once raced on the same repo), three things go wrong. This skill is
the checklist that prevents each.

## The three failure modes (all observed in production)

1. **Clobbering unsaved work** — a deploy uploads the whole working tree, so
   another session's in-progress edits ship (or your edits get overwritten).
2. **Wrong-project deploy** — `.vercel/project.json` is linked to a stale or
   duplicate project, so `vercel --prod` builds successfully but to a project
   with no live domain; the real site never updates and you think you shipped.
3. **Invisible provenance** — after deploy you can't tell *which session's* code
   is actually live, or whether the alias even moved.

## Identify your session

At the start, derive a stable short session code and remember it for the rest of
the session:

```bash
SESSION=$(echo "${CLAUDE_SESSION_ID:-$$-$(date +%s)}" | sha1sum | cut -c1-6)
```

Use it in commit trailers and the build stamp.

## Before you COMMIT

- Never `git add -A`. Stage only the specific files you changed.
- Add a session trailer so concurrent sessions are distinguishable in history:
  `git commit -m "<msg>" -m "Session: $SESSION"`
- If two sessions edit the same file, prefer one git worktree per session
  (`git worktree add ../wt-$SESSION <branch>`) — hard isolation beats
  coordination (the 2026 industry-standard pattern for parallel agents).

## Before you DEPLOY — run the guard

Run `scripts/deploy-guard.sh` (see below) or do these checks by hand:

1. **Confirm the linked project is the intended one.** Read
   `.vercel/project.json` `projectName` and compare to the project that actually
   owns the target domain (`vercel project ls` → match the Latest Production URL
   to your domain). If they differ, STOP — re-link with
   `vercel link --project <correct> --yes` first. (This is failure mode #2.)
2. **Check for foreign unsaved work.** `git status --porcelain` must show no
   uncommitted changes you didn't make; and no source file modified in the last
   ~15 min that isn't yours. If found, coordinate before deploying. (Mode #1.)
3. **Build locally as the gate.** Never deploy a tree that fails `build`/`tsc`.
4. **Stamp provenance.** Write `public/version.json` (or pass a build env) with
   `{ session, sha, builtAt, project }` so the live artifact reveals its origin.
5. **Verify post-deploy.** After deploy, fetch `https://<domain>/version.json`
   and assert `session` + `sha` match what you just built. If it doesn't match,
   the alias didn't move or you hit the wrong project — investigate, don't
   declare success. (Modes #2 and #3.)

## The script

`scripts/deploy-guard.sh <domain> [vercel-project-name]` runs all of the above
for a Vercel + Next.js/Vite repo. Read it before first use; adapt paths
(`public/` for static, `--build-env GIT_SHA=` for SSR) to the project.

## Showing provenance in-app (optional but recommended)

Render the stamp somewhere subtle (a footer chip, like the xXTrade floor game's
in-game version hash): fetch `/version.json` client-side and show
`session·sha`. Then anyone — you or another session — can read which build is
live at a glance.

## Combining every session's work into one build (the "pre folder", done right)

The goal: when N sessions work in parallel, the deployed build contains ALL of
their work, nothing is silently lost, and you can prove whose code is live.

Do NOT implement this as a shared folder that sessions copy into and "merge" —
file-copy can't do a real merge, so same-file edits silently clobber each other.
Git is the correct "pre folder": it does true 3-way merges and FLAGS conflicts.

The workflow (`scripts/integrate-and-deploy.sh` automates it):

1. **Every session commits to its own branch** `session/<code>` — committed, not
   left in the working tree. (Pre-req: the whole app must be git-tracked. If
   most files are untracked, fix THAT first — `git add` the app — or no merge
   can include them.)
2. **Integration branch** `pre` (or `staging`): merge every `session/*` branch
   into it with `git merge --no-ff`. If git reports a conflict, STOP and have it
   resolved — that conflict is exactly the "two sessions changed the same thing"
   case a folder copy would have destroyed.
3. **Build gate** on the merged `pre`.
4. **Stamp `version.json` with ALL contributing sessions + shas** so the live
   build proves it contains everyone's work.
5. **Deploy from the committed `pre` branch**, never the mutable working tree.
6. **Verify** the live `version.json` lists your session among the merged set.
7. **Serialize deploys** with a lock (a short-lived `pre`-branch tag or a
   `.deploy-lock` file) so two sessions don't deploy simultaneously.

This gives you exactly what the folder idea wanted — all sessions' work in one
live build, always visible — but with conflict safety and provenance.

## Red flags that mean STOP

- "The build succeeded so it must be live" — verify `/version.json`, always.
- "git status looks clean" but files were modified minutes ago by no one you
  know — another session is active; coordinate.
- The domain you expect isn't in the linked project's `vercel project ls` row.
