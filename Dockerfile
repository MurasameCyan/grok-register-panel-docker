# grok-register-panel: deps baked in, source pulled from upstream at runtime.
FROM python:3.12-slim-bookworm

ARG UPSTREAM_REPO=https://github.com/lij768423-svg/grok-register-panel.git
# UPSTREAM_REF: branch the entrypoint tracks at runtime.
# UPSTREAM_REV: exact commit baked in (CI resolves REF -> sha for a reproducible build).
ARG UPSTREAM_REF=main
ARG UPSTREAM_REV=main
# Hash of upstream requirements.txt at UPSTREAM_REV. CI passes it so the value
# lands in an image label; the build fails below if it disagrees with the clone.
ARG REQS_SHA256=

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    VENV_DIR=/opt/venv \
    APP_DIR=/app/src \
    HOME=/home/app \
    UPSTREAM_REPO=${UPSTREAM_REPO} \
    UPSTREAM_REF=${UPSTREAM_REF} \
    PATH=/opt/venv/bin:$PATH

# gosu: the entrypoint starts as root only to chown the bind mounts, then execs
# itself as uid 10001. Docker creates missing bind-mount sources as root:root,
# so without this every fresh `up` needs a manual host-side chown first.
# xauth: xvfb-run builds an X authority cookie via `xauth` and dies with
# "xauth command not found" without it. --no-install-recommends keeps it out of
# the xvfb package's deps, so it has to be named explicitly -- registration runs
# through xvfb-run, so a missing xauth breaks every batch.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates tini xvfb xauth procps curl gosu \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 10001 app

# Upstream checkout. Entrypoint fast-forwards this on every start, so the baked
# revision only decides which requirements.txt the venv below is built from.
RUN git clone --filter=blob:none --no-checkout "$UPSTREAM_REPO" "$APP_DIR" \
    && git -C "$APP_DIR" checkout --detach "$UPSTREAM_REV" \
    && git -C "$APP_DIR" remote set-branches origin "$UPSTREAM_REF"

# venv lives outside the checkout so `git reset --hard` can never touch it;
# entrypoint symlinks $APP_DIR/.venv -> $VENV_DIR because monitor.py and
# run_until_100.py spawn workers via the hardcoded path ROOT/.venv/bin/python.
RUN actual="$(sha256sum "$APP_DIR/requirements.txt" | cut -d' ' -f1)" \
    && if [ -n "$REQS_SHA256" ] && [ "$REQS_SHA256" != "$actual" ]; then \
           echo "REQS_SHA256 mismatch: expected $REQS_SHA256, clone has $actual" >&2; exit 1; \
       fi \
    && python -m venv "$VENV_DIR" \
    && "$VENV_DIR/bin/pip" install --upgrade pip \
    && "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt" \
    && printf '%s\n' "$actual" > "$VENV_DIR/.reqs.sha256"

# Firefox/Camoufox system libraries (gtk, dbus-glib, alsa, x11 ...).
RUN "$VENV_DIR/bin/playwright" install-deps firefox \
    && rm -rf /var/lib/apt/lists/*

# ponytail: venv is app-writable so the entrypoint can pip-install upstream
# dependency bumps without an image rebuild. Ceiling: a compromised panel
# process could patch site-packages. Set AUTO_PIP_INSTALL=0 and
# `chown -R root:root /opt/venv` in a derived image if that matters.
COPY docker/entrypoint.sh docker/smoke.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/smoke.sh \
    && chown -R app:app /app "$VENV_DIR"

WORKDIR /app/src

# Bundled Camoufox browser (~150 MB) into the app user's cache dir. Runs as app
# so the download lands in /home/app/.cache owned by the runtime user.
RUN gosu app camoufox fetch && gosu app camoufox version

# CPA_AUTH_DIR is a path, not a credential; buildkit's SecretsUsedInArgOrEnv
# rule only pattern-matches the "AUTH" substring.
# hadolint ignore=SecretsUsedInArgOrEnv
ENV MONITOR_HOST=0.0.0.0 \
    MONITOR_PORT=8787 \
    PANEL_INCLUDE_TAIL=0 \
    CPA_AUTH_DIR=/app/src/cpa_auth \
    UPSTREAM_AUTO_UPDATE=1 \
    AUTO_PIP_INSTALL=1

EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${MONITOR_PORT}/api/health" >/dev/null

# Read by `check-update.sh` to decide restart (source only) vs pull (deps moved).
LABEL org.opencontainers.image.source="https://github.com/lij768423-svg/grok-register-panel" \
      io.grokpanel.upstream-rev="${UPSTREAM_REV}" \
      io.grokpanel.reqs-sha256="${REQS_SHA256}"

# No `USER app`: the entrypoint needs root to chown the bind mounts Docker
# created as root:root, then execs itself under gosu as uid 10001. The panel
# itself never runs as root -- verify with `docker compose exec panel id`.
# Set PANEL_FIX_OWNERSHIP=0 (or compose `user: "10001:10001"`) to opt out and
# manage host ownership yourself.
#
# -s: compose sets `init: true`, so Docker's own init owns PID 1 and tini runs
# as a child. Without -s tini warns it cannot reap, and orphaned xvfb/firefox
# processes from a killed batch would accumulate as zombies.
ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["python", "-u", "webui/monitor.py"]
