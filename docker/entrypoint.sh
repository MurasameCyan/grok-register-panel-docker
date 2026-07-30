#!/bin/sh
# Sync upstream source, then exec the panel. Deps come from the image.
set -eu
umask 0077

APP_DIR="${APP_DIR:-/app/src}"
VENV_DIR="${VENV_DIR:-/opt/venv}"
cd "$APP_DIR"

# monitor.py / run_until_100.py spawn workers via the literal path
# ROOT/.venv/bin/python, so the venv must be reachable there.
[ -e .venv ] || ln -s "$VENV_DIR" .venv

ref="${UPSTREAM_REF:-main}"
if [ "${UPSTREAM_AUTO_UPDATE:-1}" = "1" ]; then
    # No separate hash file: git already tracks the checked-out revision, and a
    # second copy can disagree with the working tree if a reset half-fails.
    # ls-remote is one round trip and downloads no objects, so an unchanged
    # upstream means the working tree is never touched at all.
    local_rev="$(git rev-parse HEAD 2>/dev/null || true)"
    # `|| true` on the assignment, not inside the pipe: with a pipe, cut's exit
    # status masks a failed ls-remote and set -e would not fire anyway.
    remote_rev="$(git ls-remote origin "refs/heads/$ref" 2>/dev/null || true)"
    remote_rev="$(printf '%s' "$remote_rev" | cut -f1)"

    if [ -z "$local_rev" ]; then
        echo "[upstream] checkout at $APP_DIR is not a usable git repo" >&2
        exit 1
    elif [ -z "$remote_rev" ]; then
        echo "[upstream] unreachable, running pinned $(git rev-parse --short HEAD)" >&2
    elif [ "$remote_rev" = "$local_rev" ]; then
        echo "[upstream] up to date at $(git rev-parse --short HEAD)"
    elif git fetch --depth 1 origin "$ref" 2>/dev/null; then
        # Tracked files only; config.json, log/, accounts/, cpa_auth/ and
        # proxies*.txt are gitignored upstream, so runtime data survives.
        git reset --hard FETCH_HEAD >/dev/null
        echo "[upstream] $(printf '%.7s' "$local_rev") -> $(git rev-parse --short HEAD)"
    else
        echo "[upstream] fetch failed, running pinned $(git rev-parse --short HEAD)" >&2
    fi
fi

# Reinstall only when upstream moved requirements.txt.
want="$(sha256sum requirements.txt | cut -d' ' -f1)"
have="$(cat "$VENV_DIR/.reqs.sha256" 2>/dev/null || true)"
if [ "$want" != "$have" ]; then
    if [ "${AUTO_PIP_INSTALL:-1}" = "1" ] && [ -w "$VENV_DIR" ]; then
        echo "[deps] requirements.txt changed, installing"
        "$VENV_DIR/bin/pip" install --no-cache-dir -r requirements.txt
        printf '%s\n' "$want" > "$VENV_DIR/.reqs.sha256"
    else
        echo "[deps] requirements.txt differs from image, rebuild recommended" >&2
    fi
fi

mkdir -p log accounts cpa_auth grok2api_auth
[ -f config.json ] || { [ -f config.example.json ] && cp config.example.json config.json; }

# Bind-mounted dirs keep host ownership. Fail now rather than after a register
# run has already spent an email address and cannot write the auth file.
for d in log accounts cpa_auth grok2api_auth; do
    [ -w "$d" ] || { echo "$APP_DIR/$d is not writable by uid $(id -u); chown -R 10001:10001 the host dir" >&2; exit 1; }
done

case "${MONITOR_HOST:-}" in
    127.*|localhost|::1) ;;
    *) [ -n "${MONITOR_TOKEN:-}" ] || {
           echo "MONITOR_TOKEN is required when MONITOR_HOST=${MONITOR_HOST:-} is not loopback" >&2
           exit 1
       } ;;
esac

exec "$@"
