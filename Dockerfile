FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source
FROM debian:13.4

# Disable Python stdout buffering to ensure logs are printed immediately
ENV PYTHONUNBUFFERED=1

# Store Playwright browsers outside the data directory
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# Install build-time + runtime system dependencies in a single layer.
# Build-only packages (build-essential, gcc, python3-dev, libffi-dev, git)
# are removed after the Node/Python install steps to keep the final layer lean.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        # Runtime dependencies
        nodejs npm ripgrep ffmpeg procps \
        # Build-only dependencies (removed below after use)
        build-essential gcc python3-dev libffi-dev git && \
    rm -rf /var/lib/apt/lists/*

# Non-root user for runtime; UID can be overridden via HERMES_UID at runtime
RUN useradd -u 10000 -m -d /opt/data hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

COPY . /opt/hermes
WORKDIR /opt/hermes

# Install Node dependencies, Playwright, and Python deps; then strip build
# tools and all caches in the same RUN layer so nothing is committed to the
# image that isn't needed at runtime.
RUN \
    # --- Node: root package ---
    npm install --prefer-offline --no-audit --no-fund && \
    # --- Playwright: chromium only, shell-only (no X11/media extras) ---
    npx playwright install --with-deps chromium --only-shell && \
    # --- Node: WhatsApp bridge ---
    cd /opt/hermes/scripts/whatsapp-bridge && \
    npm install --prefer-offline --no-audit --no-fund && \
    cd /opt/hermes && \
    # --- Python virtualenv + package install ---
    uv venv && \
    uv pip install --no-cache-dir -e ".[all]" && \
    # --- Strip build-only apt packages ---
    apt-get purge -y --auto-remove build-essential gcc python3-dev libffi-dev git && \
    rm -rf /var/lib/apt/lists/* && \
    # --- Wipe all package manager caches ---
    npm cache clean --force && \
    uv cache clean && \
    # --- Remove Node dev artefacts (source maps, type declarations, tests) ---
    find /opt/hermes/node_modules -name "*.map" -delete && \
    find /opt/hermes/node_modules -name "*.d.ts" -delete && \
    find /opt/hermes/node_modules -type d -name "test" -exec rm -rf {} + 2>/dev/null || true && \
    find /opt/hermes/node_modules -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true && \
    find /opt/hermes/node_modules -type d -name "__tests__" -exec rm -rf {} + 2>/dev/null || true && \
    find /opt/hermes/scripts/whatsapp-bridge/node_modules -name "*.map" -delete 2>/dev/null || true && \
    # --- Remove Python bytecode and test artefacts from the venv ---
    find /opt/hermes/.venv -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /opt/hermes/.venv -name "*.pyc" -delete 2>/dev/null || true && \
    find /opt/hermes/.venv -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true && \
    find /opt/hermes/.venv -type d -name "test" -exec rm -rf {} + 2>/dev/null || true && \
    # --- Hand ownership to hermes user ---
    chown -R hermes:hermes /opt/hermes && \
    chmod +x /opt/hermes/docker/entrypoint.sh

ENV HERMES_HOME=/opt/data
ENTRYPOINT [ "/opt/hermes/docker/entrypoint.sh" ]
