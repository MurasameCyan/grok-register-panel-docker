#!/bin/sh
# Answer one question from the host: restart (source only) or pull (image moved)?
# Two things can move independently -- the upstream source, which the entrypoint
# git-pulls at start, and this repo's image, which carries every runtime dep.
# Runs against the GitHub API + the registry + the running container, builds
# nothing.
set -eu

SLUG="${UPSTREAM_REPO_SLUG:-lij768423-svg/grok-register-panel}"
REF="${UPSTREAM_REF:-main}"
SERVICE="${SERVICE:-panel}"
API="https://api.github.com/repos/$SLUG"

need() { command -v "$1" >/dev/null || { echo "need $1" >&2; exit 2; }; }

api() { curl -fsSL -H 'Accept: application/vnd.github+json' \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$1"; }

# jq is optional; these two fields are flat enough for sed.
field() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n1; }

# "host[:port]/path:tag" -> "host path tag" on stdout, or non-zero for a ref this
# script cannot check. Own function because the splitting is where this gets
# subtle: a colon can be a tag separator OR a registry port, and only its
# position relative to the last slash says which.
parse_ref() {
    _r="$1"
    # A digest-pinned ref (image: repo@sha256:...) cannot move by definition, so
    # there is nothing to check. Rejected here rather than left to produce a
    # nonsense tag below.
    case "$_r" in *@sha256:*) return 1 ;; esac
    # Only the part after the last slash can hold a tag.
    case "${_r##*/}" in
        *:*) _tag="${_r##*:}"; _repo="${_r%:*}" ;;
        *)   _tag=latest;      _repo="$_r" ;;
    esac
    _host="${_repo%%/*}"
    _path="${_repo#*/}"
    # ghcr.io only: the token endpoint and its scope syntax are per-registry, and
    # this image is published to exactly one. A fork elsewhere (or a ref with no
    # registry at all, where _host is just the image name) keeps the upstream half
    # of the script working instead of erroring out.
    [ "$_host" = ghcr.io ] || return 1
    printf '%s %s %s\n' "$_host" "$_path" "$_tag"
}

# Runnable check for the above, since a mis-split ref would silently query the
# wrong repo (or silently skip the check) rather than fail loudly. Needs neither
# docker nor network, so it sits above the `need` calls: docker/check-update.sh --self-check
if [ "${1:-}" = --self-check ]; then
    ok=0
    # ref -> expected "host path tag", or "reject" for refs we decline to check.
    for c in \
        "ghcr.io/o/n:latest|ghcr.io o/n latest" \
        "ghcr.io/o/n|ghcr.io o/n latest" \
        "ghcr.io/o/n:reqs-abc123|ghcr.io o/n reqs-abc123" \
        "ghcr.io/o/sub/n:1.2.3|ghcr.io o/sub/n 1.2.3" \
        "ghcr.io/o/n@sha256:dead|reject" \
        "registry:5000/o/n:latest|reject" \
        "docker.io/o/n:latest|reject" \
        "alpine:3.19|reject"; do
        in="${c%%|*}"; want="${c#*|}"
        got="$(parse_ref "$in" || echo reject)"
        if [ "$got" = "$want" ]; then
            echo "ok   $in -> $got"
        else
            echo "FAIL $in -> '$got', want '$want'" >&2
            ok=1
        fi
    done
    # `if`, not `[ ... ] && echo`: a failed && list trips set -e, which would exit
    # before reaching the explicit `exit` below -- right code, wrong reason.
    if [ "$ok" = 0 ]; then echo "parse_ref: all cases pass"; fi
    exit "$ok"
fi

need curl
need docker

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

api "$API/commits/$REF" > "$tmp/head.json"
remote_rev="$(field "$tmp/head.json" sha)"
[ -n "$remote_rev" ] || { echo "could not resolve $SLUG@$REF" >&2; exit 2; }

# safe.directory: the image has no `USER app` (the entrypoint needs root to chown
# the mounts, then gosu-execs itself as uid 10001), so `exec` lands as ROOT while
# the checkout is owned by 10001 -- and git's dubious-ownership guard exits 128
# with an empty stdout. Every other exec in this repo is uid-agnostic, which is
# why only this one broke. Overriding the guard beats passing `-u 10001`, which
# would itself break the `user: "1000:1000"` opt-out the Dockerfile documents:
# this way the call works whoever owns the checkout and whoever we land as.
#
# stderr goes to a file rather than /dev/null: swallowing it turned every real
# failure into "container not running", which sent people to restart a container
# that was already up. Ask git for nothing but the revision, and show whatever it
# says when that comes back empty.
local_rev="$(docker compose exec -T "$SERVICE" \
                 git -c safe.directory='*' rev-parse HEAD \
                 2>"$tmp/git.err" | tr -d '\r' || true)"
if [ -z "$local_rev" ]; then
    echo "could not read the checked-out revision from container '$SERVICE':" >&2
    sed 's/^/  /' "$tmp/git.err" >&2
    echo "if the container is up, this is not a 'start it first' problem -- the" >&2
    echo "exec itself failed. \`docker compose ps\` and \`logs $SERVICE\` say which." >&2
    exit 2
fi

short() { printf '%.7s' "$1"; }

# The other half of the question, and the half that used to be missing: is the
# container even on the newest published image? Upstream is not the only thing
# that moves -- THIS repo's Dockerfile carries the runtime deps (xvfb, xauth,
# camoufox, the venv), and it can move with upstream sitting perfectly still. A
# missing runtime dep is exactly that shape: the entrypoint git-syncs the source
# to the newest revision, so the comparison below says "up to date", the advice
# says restart, and `docker compose restart` never re-pulls an image. Same broken
# container, forever.
#
# Compares the digest the container's image was pulled at against whatever its
# tag points to now, which is the only signal that survives a tag being moved
# under us (`latest` is rebuilt in place). Prints nothing and returns 1 when the
# answer is unknowable -- a locally-built image, a registry we cannot query --
# because a false "pull" on every cron run is worse than no answer.
#
# ponytail: sh has no locals, and $have/$want/$ref are read by the caller on
# purpose -- they are only ever set on the path that returns 0. Ceiling: another
# function reusing those three names would clobber them. Upgrade path if this
# grows a third caller: print "have want ref" on stdout and read it back.
image_moved() {
    # head -n1: a replicated service prints one id per line, and docker inspect
    # would then be handed several at once. The panel is single-replica, so the
    # first one is the answer.
    cid="$(docker compose ps -q "$SERVICE" 2>/dev/null | head -n1)"
    [ -n "$cid" ] || return 1
    # .Image is the image ID the container actually runs; .Config.Image is the
    # ref as compose asked for it. Both are needed and neither substitutes for
    # the other: after a `pull` with no recreate, the tag already resolves to the
    # NEW image, so reading the digest by ref would compare the registry against
    # itself and always report "up to date".
    ref="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
    img="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
    [ -n "$ref" ] && [ -n "$img" ] || return 1

    have="$(docker inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' \
              "$img" 2>/dev/null || true)"
    # No RepoDigests means the image was never pulled from a registry (built
    # locally, or loaded from a tar). Nothing to compare against.
    case "$have" in *@sha256:*) have="${have##*@}" ;; *) return 1 ;; esac

    parsed="$(parse_ref "$ref")" || return 1
    # Positional split: the fields cannot contain spaces (a ref with one is not a
    # ref), and this needs no subshell, unlike a `read` from a pipe. Clobbering
    # the script's own "$@" is safe here -- the only call site is top level, where
    # $1 is either unset or --self-check, and that already exited above.
    # shellcheck disable=SC2086
    set -- $parsed
    host="$1"; path="$2"; tag="$3"

    # Anonymous pull token; public reads still need one on GHCR.
    curl -fsSL "https://$host/token?service=$host&scope=repository:$path:pull" \
        > "$tmp/tok.json" 2>/dev/null || return 1
    tok="$(field "$tmp/tok.json" token)"
    [ -n "$tok" ] || return 1

    # HEAD, not GET: the digest is a response header, so this downloads no
    # manifest body at all. The Accept list has to name the index types or the
    # registry answers with a single-arch manifest and a different digest than
    # the one `docker pull` recorded.
    want="$(curl -fsSI -H "Authorization: Bearer $tok" \
                 -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
                 "https://$host/v2/$path/manifests/$tag" 2>/dev/null \
             | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
             | tr -d '\r' | head -n1)"
    [ -n "$want" ] || return 1

    [ "$have" != "$want" ]
}

# Checked before upstream: when the image has moved, pulling it also brings the
# source along (the entrypoint syncs on the new container's first start), so the
# answer is "pull" no matter what the revision comparison below would have said.
if image_moved; then
    echo "image moved: $(short "${have#sha256:}") -> $(short "${want#sha256:}") ($ref)"
    echo "the image carries the runtime deps, and restart does not re-pull it:"
    echo "    docker compose pull && docker compose up -d"
    exit 10
fi

if [ "$remote_rev" = "$local_rev" ]; then
    echo "up to date at $(short "$local_rev")"
    exit 0
fi

echo "upstream moved: $(short "$local_rev") -> $(short "$remote_rev")"

# The image is current (or unknowable) by here, so the only remaining reason to
# pull is upstream moving requirements.txt: that is the one upstream file baked
# into the image, and CI has to publish a new one before it can be picked up.
api "$API/compare/$local_rev...$remote_rev" > "$tmp/cmp.json"
if grep -q '"filename"[[:space:]]*:[[:space:]]*"requirements.txt"' "$tmp/cmp.json"; then
    echo "requirements.txt changed -> pull a CI-built image:"
    echo "    docker compose pull && docker compose up -d"
    exit 10
fi

echo "source-only change -> restart is enough:"
echo "    docker compose restart $SERVICE"
exit 11
