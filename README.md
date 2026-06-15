# Madwr1d · Claude Skills

Free, practical [Claude Code](https://docs.claude.com/en/docs/claude-code) skills. MIT licensed — use, modify, redistribute freely.

## Install as a plugin marketplace

```
/plugin marketplace add Madwr1d/skills
```

Then install any skill from it:

```
/plugin install safe-multi-session-deploy@madwr1d-skills
```

Or just copy a skill folder into `~/.claude/skills/`.

## Skills

### safe-multi-session-deploy
Stops three real footguns when **multiple AI coding sessions share one repo**:
1. **Clobbering unsaved work** — a deploy ships another session's in-progress edits.
2. **Wrong-project deploy** — a stale `.vercel/project.json` builds cleanly to a project with no live domain; the real site never updates.
3. **Invisible provenance** — you can't tell which session's code is actually live.

It stamps a session-tagged build-provenance marker (`/version.json`) and verifies it post-deploy. Framework-agnostic (Vercel/Railway/Node).
