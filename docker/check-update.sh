#!/bin/sh
# Answer one question from the host: restart (source only) or pull (deps moved)?
# Runs against the GitHub API + the running container, builds nothing.
set -eu

SLUG="${UPSTREAM_REPO_SLUG:-lij768423-svg/grok-register-panel}"
REF="${UPSTREAM_REF:-main}"
SERVICE="${SERVICE:-panel}"
API="https://api.github.com/repos/$SLUG"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 2; }; }
need curl
need docker

api() { curl -fsSL -H 'Accept: application/vnd.github+json' \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$1"; }

# jq is optional; these two fields are flat enough for sed.
field() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

api "$API/commits/$REF" > "$tmp/head.json"
remote_rev="$(field "$tmp/head.json" sha)"
[ -n "$remote_rev" ] || { echo "could not resolve $SLUG@$REF" >&2; exit 2; }

local_rev="$(docker compose exec -T "$SERVICE" git rev-parse HEAD 2>/dev/null || true)"
[ -n "$local_rev" ] || { echo "container '$SERVICE' not running; start it first" >&2; exit 2; }

short() { printf '%.7s' "$1"; }

if [ "$remote_rev" = "$local_rev" ]; then
    echo "up to date at $(short "$local_rev")"
    exit 0
fi

echo "upstream moved: $(short "$local_rev") -> $(short "$remote_rev")"

# Did requirements.txt change between the two revisions? That is the only thing
# the image carries, so it is the only thing that forces a pull.
api "$API/compare/$local_rev...$remote_rev" > "$tmp/cmp.json"
if grep -q '"filename"[[:space:]]*:[[:space:]]*"requirements.txt"' "$tmp/cmp.json"; then
    echo "requirements.txt changed -> pull a CI-built image:"
    echo "    docker compose pull && docker compose up -d"
    exit 10
fi

echo "source-only change -> restart is enough:"
echo "    docker compose restart $SERVICE"
exit 11
