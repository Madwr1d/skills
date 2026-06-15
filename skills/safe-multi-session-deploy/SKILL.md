---
name: safe-multi-session-deploy
description: Use BEFORE committing or shipping any project that more than one AI agent or person works on at the same time. When you push code to a live website, app, or server — via any host (Vercel, Netlify, Cloudflare, Railway, Render, Fly, AWS/S3, a VPS over SSH/rsync, Docker, or FTP) — three things go wrong with concurrent sessions: one session's unsaved work gets clobbered, the deploy lands on the wrong target/environment so the real site never updates, and afterward nobody can tell which session's build is actually live. This skill is the checklist + scripts that prevent each, by isolating work, gating the deploy, and stamping + verifying a build-provenance marker on the live artifact.
---

# Safe Multi-Session Deploy

When more than one agent or person works on the same project and ships it to a
**live target** — a website, an app, a server, a bucket — three failures show up
again and again, on every host, not just one. (Real case: four AI sessions once
raced on the same repo.) This skill prevents each, regardless of how you deploy.

It is **host-agnostic.** "Deploy" here means *any* path that puts your code in
front of users: `vercel`/`netlify`/`wrangler` deploys, `git push` to a PaaS
(Railway, Render, Fly, Heroku), `rsync`/`scp` to a VPS, `docker build && push`,
`aws s3 sync`, an FTP upload, or a CI pipeline trigger. The principles are the
same; only the commands differ.

## The three failure modes (host-independent)

1. **Clobbering unsaved work** — most deploys ship the *current working tree* (or
   a fresh build of it), so another session's in-progress, uncommitted edits get
   pushed live, or your own edits get overwritten by theirs. Nobody chose this;
   the tool just uploaded whatever was on disk.
2. **Wrong target** — you deploy successfully, but to the *wrong place*: a stale
   linked project, the wrong environment (staging vs prod), the wrong server,
   bucket, branch, or app. The command exits 0, so you believe you shipped — but
   the live site never changes. (On Vercel this is a stale `.vercel/project.json`
   pointing at a project with no live domain; on a VPS it's the wrong host or
   path; on S3 the wrong bucket; on a PaaS the wrong app/service.)
3. **Invisible provenance** — after deploying you can't tell *which session's*
   code is live, or whether the live version even moved. So "I shipped my fix"
   is unverified hope, not fact.

## Identify your session

Derive a short, stable session code at the start and reuse it everywhere:

```bash
SESSION=$(echo "${CLAUDE_SESSION_ID:-$$-$(date +%s)}" | sha1sum | cut -c1-6)
```

Use it in commit trailers and in the build stamp.

## Before you COMMIT

- Never `git add -A` / `git add .` blindly — stage only the files you changed, so
  you can't sweep up another session's in-progress work or a stray secret.
- Tag your commits so concurrent sessions are distinguishable in history:
  `git commit -m "<msg>" -m "Session: $SESSION"`.
- If two sessions touch the same files, give each its **own git worktree**
  (`git worktree add ../wt-$SESSION <branch>`). Hard isolation beats coordination
  — it's the standard pattern for running parallel agents safely.

## Before you DEPLOY — run the guard

Use `scripts/deploy-guard.sh` (configurable for any host — see below) or perform
these checks by hand, in order:

1. **Confirm the target is the intended one.** Whatever your host: verify *where
   this deploy will land* before running it.
   - Vercel: `.vercel/project.json` `projectName` must own the live domain
     (`vercel project ls`); if not, `vercel link --project <correct> --yes`.
   - Netlify/Cloudflare: confirm the linked site/project id.
   - PaaS (Railway/Render/Fly): confirm the linked service **and environment**
     (prod, not staging).
   - VPS/SSH or rsync: confirm the host **and the target path**.
   - S3/static: confirm the bucket + distribution.
   If the target isn't unambiguously the right one, STOP and fix the link first.
   (Failure mode #2.)
2. **Check for foreign / unsaved work.** `git status --porcelain` must show no
   uncommitted changes you didn't make, and no source file modified in the last
   ~15 min that isn't yours. If you find some, another session is active —
   coordinate before shipping. (Failure mode #1.)
3. **Build locally as the gate.** Never deploy a tree that fails its build /
   type-check / tests.
4. **Stamp provenance.** Write a small build marker — `{ session, sha, builtAt,
   target }` — into the artifact. For a web app, `public/version.json` (served at
   `/version.json`). For a container, a `BUILD_INFO` label or env. For static
   uploads, a `version.json` next to `index.html`. The point: the live artifact
   can reveal its own origin.
5. **Verify the LIVE artifact.** After deploying, read the provenance back *from
   the live target* and assert it matches what you just built:
   - Web: `curl https://<domain>/version.json` → check `session` + `sha`.
   - API/app: hit a `/health` or version endpoint.
   - Server/file deploy: `ssh host cat <path>/version.json`, or check the
     deployed file's checksum/mtime.
   If it doesn't match, the live version didn't move or you hit the wrong target
   — investigate; do **not** declare success. (Failure modes #2 and #3.)

## The script

`scripts/deploy-guard.sh <verify-url-or-cmd> [options]` runs all of the above. By
default it builds, stamps `public/version.json`, deploys, and verifies the live
marker. The **deploy command is pluggable** via `DEPLOY_CMD` (or the built-in
Vercel default), so the same guard works for Netlify, Cloudflare, a `git push`
PaaS, `rsync`, Docker, or `aws s3 sync` — you just supply your host's deploy
command and the URL/command that reads the live marker back. Read it once and set
the env vars for your stack; the safety logic is identical across hosts.

## Showing provenance in-app (optional but recommended)

Render the stamp somewhere subtle — a footer chip showing `session·sha` (like the
in-app version hash on a game build). Fetch `/version.json` client-side and show
it. Then you, a teammate, or another agent can read which build is live at a
glance, on any environment.

## Combining every session's work into one build (the "shared folder", done right)

Goal: when N sessions work in parallel, the deployed build contains **all** their
work, nothing is silently lost, and you can prove whose code is live.

Do **not** do this with a shared folder that sessions copy into and "merge" —
file-copy can't merge, so same-file edits silently clobber each other. **Git is
the correct merge surface**: it does true 3-way merges and *flags* conflicts.

Workflow (`scripts/integrate-and-deploy.sh` automates it):

1. **Each session commits to its own branch** `session/<code>` — committed, not
   left dirty in the tree. (Pre-req: the whole app is git-tracked. If most files
   are untracked, fix that first — `git add` the app — or no merge can include
   them.)
2. **Integration branch** `pre` (or `staging`): merge each `session/*` branch in
   with `git merge --no-ff`. A reported conflict is exactly the "two sessions
   changed the same thing" case a folder copy would have destroyed — resolve it.
3. **Build gate** on the merged `pre`.
4. **Stamp the marker with ALL contributing sessions + shas** so the live build
   proves it contains everyone's work.
5. **Deploy from the committed `pre` branch**, never the mutable working tree.
6. **Verify** the live marker lists your session among the merged set.
7. **Serialize deploys** with a lock (a short-lived tag or a `.deploy-lock`
   file) so two sessions don't deploy at the same instant.

## Red flags that mean STOP

- "The build succeeded, so it must be live." — No. Verify the live marker, always.
- "`git status` looks clean" but files were modified minutes ago by no one you
  know — another session is active; coordinate.
- You can't say, with certainty, **which target** this deploy will hit.
- You're about to `git add -A` in a repo more than one session touches.
