#!/bin/sh
# One runnable check for the two things the image gets wrong if entrypoint breaks:
# workers resolve ROOT/.venv/bin/python, and an upstream reset keeps runtime data.
set -eu
APP_DIR="${APP_DIR:-/app/src}"
cd "$APP_DIR"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$APP_DIR/.venv/bin/python" ] || fail ".venv/bin/python not executable (worker spawn would die)"
"$APP_DIR/.venv/bin/python" -c 'import camoufox, playwright, DrissionPage, curl_cffi' \
    || fail "runtime deps missing from venv"
camoufox version >/dev/null || fail "camoufox browser not fetched"
command -v xvfb-run >/dev/null || fail "xvfb-run missing (run_batch_headless would die)"
[ -r /proc/1/cmdline ] || fail "/proc unreadable (process_utils cannot find workers)"

for d in log accounts cpa_auth grok2api_auth; do
    [ -w "$d" ] || fail "$d not writable (auth files would be lost after a register run)"
done

# The entrypoint creates these in panel-data/ and symlinks them here, so a fresh
# `up` needs no manual touch/cp. -f follows the symlink: a link to a real file
# passes, a directory (the old missing-single-file-mount bug) does not.
for f in config.json proxies.txt; do
    [ -f "$f" ] || fail "$f is not a regular file (entrypoint did not create/link it)"
done

# The entrypoint starts as root to chown the mounts, then gosu-execs itself as
# 10001. If that drop ever regressed, the panel would spawn browsers as root.
[ "$(id -u)" != 0 ] || fail "still running as root (entrypoint did not drop to uid 10001)"

git rev-parse HEAD >/dev/null 2>&1 || fail "not a git checkout (upstream sync impossible)"

# Reset to the revision already checked out: exercises the real code path the
# entrypoint takes without depending on network access or moving the source.
marker="log/.smoke_$$"
: > "$marker"
git reset --hard HEAD >/dev/null || fail "git reset --hard failed"
[ -f "$marker" ] || fail "upstream reset wiped runtime data under log/"
rm -f "$marker"

echo "OK: $(git rev-parse --short HEAD) venv+camoufox+xvfb+proc ready, auth dirs writable, runtime data preserved"
