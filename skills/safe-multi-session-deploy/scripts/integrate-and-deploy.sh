#!/usr/bin/env bash
# Integrate every session's branch into one build, then deploy + verify.
# The git-native form of "a pre folder that merges all sessions' work" — with
# real 3-way merges, conflict detection, multi-session provenance, and a lock.
#
# Usage:
#   integrate-and-deploy.sh <domain> <expected-project> \
#       [integration-branch=pre] [session-glob='session/*'] [base-branch=main] [public-dir=public]
#
# Pre-req: the whole app is git-tracked, and each session committed its work to a
# branch matching <session-glob> (e.g. session/<code>). Untracked files are NOT
# merged — commit them first.
set -euo pipefail

DOMAIN="${1:?usage: integrate-and-deploy.sh <domain> <project> [pre] [session/*] [main] [public]}"
EXPECT_PROJECT="${2:?expected vercel project name required}"
INTEG="${3:-pre}"
GLOB="${4:-session/*}"
BASE="${5:-main}"
PUBDIR="${6:-public}"

SESSION=$(echo "${CLAUDE_SESSION_ID:-$$-$(date +%s)}" | sha1sum | cut -c1-6)
say() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; release_lock 2>/dev/null || true; exit 1; }

LOCK=".deploy-lock"
acquire_lock() {
  if [ -f "$LOCK" ]; then
    die "Another deploy is in progress ($(cat "$LOCK")). Wait or remove $LOCK if stale."
  fi
  echo "$SESSION @ $(date -u +%H:%M:%SZ)" > "$LOCK"
}
release_lock() { rm -f "$LOCK"; }

# 0) Right project + clean tree -------------------------------------------------
LINKED=$(grep -o '"projectName":"[^"]*"' .vercel/project.json 2>/dev/null | cut -d'"' -f4 || echo "")
[ "$LINKED" = "$EXPECT_PROJECT" ] || die "Linked project '$LINKED' != '$EXPECT_PROJECT'. Re-link: vercel link --project $EXPECT_PROJECT --yes"
[ -z "$(git status --porcelain | grep -vE '^\?\?')" ] || die "Commit your working changes (to your session/<code> branch) before integrating."

acquire_lock
trap release_lock EXIT

# 1) Build the integration branch fresh from base ------------------------------
say "Rebuilding integration branch '$INTEG' from '$BASE'"
git fetch --all --quiet || true
git checkout -B "$INTEG" "$BASE"

# 2) Merge every session branch; stop on conflict ------------------------------
MERGED=""
for b in $(git branch --list "$GLOB" --format='%(refname:short)'); do
  say "Merging $b"
  if git merge --no-ff --no-edit "$b"; then
    MERGED="$MERGED $b@$(git rev-parse --short "$b")"
  else
    git merge --abort
    die "CONFLICT merging $b — two sessions changed the same lines. Resolve manually (git merge $b, fix, commit) then re-run. (This is the case a folder-copy would have silently destroyed.)"
  fi
done
[ -n "$MERGED" ] || say "No '$GLOB' branches to merge — deploying $BASE as-is."

# 3) Build gate ----------------------------------------------------------------
say "Building merged tree (gate)"
npm run build

# 4) Stamp multi-session provenance --------------------------------------------
say "Stamping $PUBDIR/version.json with all merged sessions"
mkdir -p "$PUBDIR"
INTEG_SHA=$(git rev-parse --short HEAD)
cat > "$PUBDIR/version.json" <<EOF
{ "deployedBy": "$SESSION", "integrationSha": "$INTEG_SHA", "project": "$LINKED", "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "merged": "$(echo "$MERGED" | sed 's/^ *//')" }
EOF
git add "$PUBDIR/version.json" && git commit -m "build: provenance stamp $INTEG_SHA" -m "Session: $SESSION" --quiet || true
cat "$PUBDIR/version.json"

# 5) Deploy from the committed integration branch -----------------------------
say "Deploying $INTEG to production"
vercel deploy --prod --yes --build-env GIT_SHA="$(git rev-parse --short HEAD)" --build-env BUILD_SESSION="$SESSION"

# 6) Verify live ----------------------------------------------------------------
say "Verifying https://$DOMAIN/version.json"
sleep 4
LIVE=$(curl -fsS "https://$DOMAIN/version.json?cb=$(date +%s)" 2>/dev/null || echo "{}")
echo "  live: $LIVE"
echo "$LIVE" | grep -q "\"deployedBy\": \"$SESSION\"" \
  && printf '\n\033[32m✓ Live build is this integration (deployedBy %s) on %s\033[0m\n' "$SESSION" "$DOMAIN" \
  || die "Live version.json does not match — alias didn't move or wrong project/domain. Investigate."
