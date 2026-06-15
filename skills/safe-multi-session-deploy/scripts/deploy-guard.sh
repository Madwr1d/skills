#!/usr/bin/env bash
# safe-multi-session-deploy guard — host-agnostic.
#
# Builds, stamps a provenance marker, deploys via YOUR host's command, then
# verifies the marker on the LIVE target. Refuses to deploy if a safety check
# fails. Works with any host — you supply the deploy command and the way to read
# the live marker back.
#
# Usage:
#   deploy-guard.sh <verify> [public-dir]
#     <verify>      How to read the live marker back. Either:
#                     • an https URL  (e.g. https://example.com/version.json), or
#                     • a shell command that prints the live marker JSON
#                       (e.g. "ssh host cat /srv/app/version.json")
#     [public-dir]  Where version.json is written/served from (default: public)
#
# Environment:
#   DEPLOY_CMD       Command that ships the build. Defaults to Vercel:
#                      vercel deploy --prod --yes --build-env GIT_SHA=$SHA --build-env BUILD_SESSION=$SESSION
#                    Examples for other hosts:
#                      DEPLOY_CMD='netlify deploy --prod'
#                      DEPLOY_CMD='wrangler pages deploy ./dist'
#                      DEPLOY_CMD='git push railway main'      # or render/fly/heroku
#                      DEPLOY_CMD='rsync -az --delete ./dist/ user@host:/srv/app/'
#                      DEPLOY_CMD='aws s3 sync ./dist s3://my-bucket --delete'
#                      DEPLOY_CMD='flyctl deploy'
#   BUILD_CMD        Build/gate command (default: "npm run build"). Set to your
#                    test/typecheck/build, or "true" to skip.
#   EXPECT_TARGET    Optional string the linked-target check must match (see below).
#   TARGET_CMD       Optional command that prints the CURRENT linked target, so we
#                    can compare it to EXPECT_TARGET before deploying. Default reads
#                    Vercel's .vercel/project.json projectName.
set -euo pipefail

VERIFY="${1:?usage: deploy-guard.sh <verify-url-or-cmd> [public-dir]}"
PUBDIR="${2:-public}"

SESSION=$(echo "${CLAUDE_SESSION_ID:-$$-$(date +%s)}" | sha1sum | cut -c1-6)
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
say() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# 1) Right target? -----------------------------------------------------------
say "Confirming the deploy target"
TARGET_CMD="${TARGET_CMD:-grep -o '\"projectName\":\"[^\"]*\"' .vercel/project.json 2>/dev/null | cut -d'\"' -f4}"
LINKED=$(bash -c "$TARGET_CMD" 2>/dev/null || echo "")
echo "  current target: ${LINKED:-<unknown — confirm manually>}"
if [ -n "${EXPECT_TARGET:-}" ] && [ "$LINKED" != "$EXPECT_TARGET" ]; then
  die "Linked target '$LINKED' != expected '$EXPECT_TARGET'. Re-link / fix the target before deploying."
fi
echo "  will verify live marker via: $VERIFY"

# 2) Foreign unsaved work? ---------------------------------------------------
say "Checking for uncommitted / foreign in-progress edits"
DIRTY=$(git status --porcelain 2>/dev/null | grep -vE '^\?\?' || true)
if [ -n "$DIRTY" ]; then
  echo "$DIRTY"
  die "Uncommitted changes to tracked files — commit or stash yours, and confirm none belong to another session, before deploying."
fi
RECENT=$(find . -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.css' -o -name '*.py' -o -name '*.go' -o -name '*.rb' \) \
  -mmin -15 2>/dev/null | grep -vE 'node_modules|\.next|\.git|dist|build|vendor' | head -20 || true)
if [ -n "$RECENT" ]; then
  echo "  ⚠ source files modified in the last 15 min:"; echo "$RECENT" | sed 's/^/    /'
  echo "  If any are not yours, ANOTHER SESSION is active — coordinate before deploying."
fi

# 3) Build gate --------------------------------------------------------------
say "Building locally (gate — a broken tree never deploys)"
bash -c "${BUILD_CMD:-npm run build}"

# 4) Stamp provenance --------------------------------------------------------
say "Stamping $PUBDIR/version.json"
mkdir -p "$PUBDIR"
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$PUBDIR/version.json" <<EOF
{ "session": "$SESSION", "sha": "$SHA", "builtAt": "$BUILT_AT", "target": "${LINKED:-unknown}" }
EOF
cat "$PUBDIR/version.json"

# 5) Deploy ------------------------------------------------------------------
say "Deploying"
DEPLOY_CMD="${DEPLOY_CMD:-vercel deploy --prod --yes --build-env GIT_SHA=$SHA --build-env BUILD_SESSION=$SESSION}"
echo "  \$ $DEPLOY_CMD"
bash -c "$DEPLOY_CMD"

# 6) Verify the LIVE artifact matches what we built --------------------------
say "Verifying the live marker"
sleep 4
case "$VERIFY" in
  http://*|https://*) LIVE=$(curl -fsS "${VERIFY}$([[ "$VERIFY" == *\?* ]] && echo "&" || echo "?")cb=$(date +%s)" 2>/dev/null || echo "{}") ;;
  *)                  LIVE=$(bash -c "$VERIFY" 2>/dev/null || echo "{}") ;;
esac
echo "  live: $LIVE"
if echo "$LIVE" | grep -q "\"session\": \"$SESSION\"" && echo "$LIVE" | grep -q "\"sha\": \"$SHA\""; then
  printf '\n\033[32m✓ Live build matches this session (%s @ %s)\033[0m\n' "$SESSION" "$SHA"
else
  die "Live marker does NOT match what we built (session=$SESSION sha=$SHA). The live version didn't move or you deployed to the wrong target. Investigate before claiming success."
fi
