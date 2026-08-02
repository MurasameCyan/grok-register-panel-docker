#!/bin/sh
# Sync upstream source, then exec the panel. Deps come from the image.
set -eu
umask 0077

APP_DIR="${APP_DIR:-/app/src}"
VENV_DIR="${VENV_DIR:-/opt/venv}"
PANEL_UID="${PANEL_UID:-10001}"
PANEL_GID="${PANEL_GID:-10001}"
DATA_DIR="${PANEL_DATA_DIR:-$APP_DIR/panel-data}"
cd "$APP_DIR"

# Docker creates a bind mount's host directory as root:root when it does not
# exist yet, so a first `up` hands the container four or five unwritable mounts
# no matter what the docs say to chown beforehand. Fix it here instead of
# demanding the host get it right: take ownership while we still have root,
# then drop to $PANEL_UID for everything below -- the upstream git sync must
# NOT run as root or it leaves root-owned objects in $APP_DIR/.git.
if [ "$(id -u)" = 0 ]; then
    if [ "${PANEL_FIX_OWNERSHIP:-1}" = "1" ]; then
        for d in log accounts cpa_auth grok2api_auth "$DATA_DIR"; do
            mkdir -p "$d"
            # -R is the expensive part, so only recurse when the directory
            # itself is wrong; that is exactly the freshly-created-by-Docker
            # case. An already-correct mount costs one stat.
            [ "$(stat -c '%u:%g' "$d")" = "$PANEL_UID:$PANEL_GID" ] && continue
            chown -R "$PANEL_UID:$PANEL_GID" "$d"
        done
    fi
    # Outside the PANEL_FIX_OWNERSHIP guard on purpose: opting out of the chown
    # must not also opt out of dropping privileges, or the git sync below would
    # run as root and leave root-owned objects in .git.
    # gosu, not su/setpriv: it drops the whole supplementary-group set and
    # execs without an intervening shell, so signals from tini reach the panel.
    exec gosu "$PANEL_UID:$PANEL_GID" "$0" "$@"
fi

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

# config.json and proxies.txt are single files, but a single-file bind mount
# becomes a directory when the host path is missing. Mount a directory
# ($PANEL_DATA_DIR, default panel-data/) instead and symlink the two files the
# app reads into it. This is also why a fresh `up` needs no manual touch/cp:
# the files below are created on first start. config.json and proxies*.txt are
# gitignored upstream and panel-data/ is untracked, so the `git reset --hard`
# above touches none of them. DATA_DIR is set at the top, before the root block.
mkdir -p "$DATA_DIR"

# Fallback path only: the root block above normally fixes ownership before we
# get here. Reachable when the container starts as non-root (`user:` in compose)
# or with PANEL_FIX_OWNERSHIP=0. Fail now rather than after a register run has
# already spent an email address and cannot write the auth file. Report every
# bad dir in one pass, so restart:unless-stopped does not make the user restart
# once per directory to discover the next name.
bad=''
# "container-path host-path" pairs; the loop splits on the space. $DATA_DIR is
# absolute, the others are relative to $APP_DIR (we cd'd there above).
for pair in "log data/log" "accounts data/accounts" "cpa_auth data/cpa_auth" \
            "grok2api_auth data/grok2api_auth" "$DATA_DIR data/panel"; do
    d="${pair% *}"
    host="${pair#* }"
    [ -w "$d" ] && continue
    bad="$bad  $d (host $host) is owned by $(stat -c '%u:%g' "$d")
"
done
if [ -n "$bad" ]; then
    echo "These bind mounts are not writable by uid $(id -u):" >&2
    printf '%s' "$bad" >&2
    echo "Docker creates a missing bind-mount source as root:root. This image" >&2
    echo "normally starts as root, chowns them to $PANEL_UID:$PANEL_GID and then drops" >&2
    echo "privileges -- but that was skipped, either by PANEL_FIX_OWNERSHIP=0 or" >&2
    echo "by a compose \`user:\` override that started us as uid $(id -u) already." >&2
    echo "Drop whichever one you set, or fix ownership on the host yourself --" >&2
    echo "the whole tree, not just the dirs named above:" >&2
    echo "  sudo chown -R $PANEL_UID:$PANEL_GID data && docker compose restart panel" >&2
    exit 1
fi

if [ ! -f "$DATA_DIR/config.json" ]; then
    # Not `[ -f x ] && cp` inside a `||` group: that group is the last element of
    # the || list, so a missing example would make set -e kill the container with
    # no message at all.
    [ -f config.example.json ] || {
        echo "config.example.json is missing from the upstream checkout;" >&2
        echo "write $DATA_DIR/config.json on the host by hand and restart" >&2
        exit 1
    }
    cp config.example.json "$DATA_DIR/config.json"
fi
[ -f "$DATA_DIR/proxies.txt" ] || : > "$DATA_DIR/proxies.txt"
ln -sfn "$DATA_DIR/config.json" config.json
ln -sfn "$DATA_DIR/proxies.txt" proxies.txt

case "${MONITOR_HOST:-}" in
    127.*|localhost|::1) ;;
    *) [ -n "${MONITOR_TOKEN:-}" ] || {
           echo "MONITOR_TOKEN is required when MONITOR_HOST=${MONITOR_HOST:-} is not loopback" >&2
           exit 1
       } ;;
esac

exec "$@"
