#!/usr/bin/env bash
# safe-multi-session-deploy guard for Vercel projects.
# Usage: deploy-guard.sh <domain> [expected-vercel-project] [public-dir]
#   <domain>                 e.g. ithild.info  (the domain that MUST update)
#   [expected-vercel-project] e.g. ithildin-app (the project that owns <domain>)
#   [public-dir]             where version.json is served from (default: public)
#
# Exits non-zero and refuses to deploy if a safety check fails. On success it
# builds, stamps provenance, deploys, and verifies the live version.json.
set -euo pipefail

DOMAIN="${1:?usage: deploy-guard.sh <domain> [project] [public-dir]}"
EXPECT_PROJECT="${2:-}"
PUBDIR="${3:-public}"

SESSION=$(echo "${CLAUDE_SESSION_ID:-$$-$(date +%s)}" | sha1sum | cut -c1-6)
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
say() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# 1) Right project? ----------------------------------------------------------
say "Checking linked Vercel project"
LINKED=$(grep -o '"projectName":"[^"]*"' .vercel/project.json 2>/dev/null | cut -d'"' -f4 || echo "")
echo "  linked project: ${LINKED:-<none>}"
if [ -n "$EXPECT_PROJECT" ] && [ "$LINKED" != "$EXPECT_PROJECT" ]; then
  die "Linked project '$LINKED' != expected '$EXPECT_PROJECT'. Re-link first: vercel link --project $EXPECT_PROJECT --yes"
fi
echo "  domain that must update: $DOMAIN"

# 2) Foreign unsaved work? ---------------------------------------------------
say "Checking for uncommitted / foreign in-progress edits"
DIRTY=$(git status --porcelain 2>/dev/null | grep -vE '^\?\?' || true)
if [ -n "$DIRTY" ]; then
  echo "$DIRTY"
  die "Uncommitted changes to tracked files — commit or stash yours, and confirm none belong to another session, before deploying."
fi
RECENT=$(find . -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.css' \) \
  -mmin -15 2>/dev/null | grep -vE 'node_modules|\.next|\.git|dist|build' | head -20 || true)
if [ -n "$RECENT" ]; then
  echo "  ⚠ source files modified in the last 15 min:"; echo "$RECENT" | sed 's/^/    /'
  echo "  If any are not yours, ANOTHER SESSION is active — coordinate before deploying."
fi

# 3) Build gate --------------------------------------------------------------
say "Building locally (gate — a broken tree never deploys)"
npm run build

# 4) Stamp provenance --------------------------------------------------------
say "Stamping $PUBDIR/version.json"
mkdir -p "$PUBDIR"
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$PUBDIR/version.json" <<EOF
{ "session": "$SESSION", "sha": "$SHA", "builtAt": "$BUILT_AT", "project": "${LINKED:-unknown}" }
EOF
cat "$PUBDIR/version.json"

# 5) Deploy ------------------------------------------------------------------
say "Deploying to production"
vercel deploy --prod --yes --build-env GIT_SHA="$SHA" --build-env BUILD_SESSION="$SESSION"

# 6) Verify the LIVE artifact matches what we built --------------------------
say "Verifying live https://$DOMAIN/version.json"
sleep 4
LIVE=$(curl -fsS "https://$DOMAIN/version.json?cb=$(date +%s)" 2>/dev/null || echo "{}")
echo "  live: $LIVE"
if echo "$LIVE" | grep -q "\"session\": \"$SESSION\"" && echo "$LIVE" | grep -q "\"sha\": \"$SHA\""; then
  printf '\n\033[32m✓ Live build matches this session (%s @ %s) on %s\033[0m\n' "$SESSION" "$SHA" "$DOMAIN"
else
  die "Live version.json does NOT match what we built (session=$SESSION sha=$SHA). The alias did not move or you deployed to the wrong project/domain. Investigate before claiming success."
fi
