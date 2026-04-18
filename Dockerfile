# ── Source images ────────────────────────────────────────────────────────────
FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source

# ── Builder stage ─────────────────────────────────────────────────────────────
# Contains build-only tools (compilers, headers) that are NOT copied to runtime.
FROM debian:13.4-slim AS builder

# Install build deps + Node.js (needed to run npm/npx for playwright install)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential gcc python3-dev libffi-dev git \
        nodejs npm ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

COPY . /opt/hermes
WORKDIR /opt/hermes

# Install root-level Node deps (agent-browser, camofox-browser, etc.)
RUN npm install --prefer-offline --no-audit --no-fund && \
    cd /opt/hermes/scripts/whatsapp-bridge && \
    npm install --prefer-offline --no-audit --no-fund && \
    npm cache clean --force

# Install Python deps into a virtualenv; uv writes no cache by default
RUN uv venv /opt/hermes/.venv && \
    uv pip install --no-cache-dir -e ".[all]"

# Strip bytecode caches and test artefacts from the venv to save space
RUN find /opt/hermes/.venv -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true && \
    find /opt/hermes/.venv -type d -name "tests"     -exec rm -rf {} + 2>/dev/null || true && \
    find /opt/hermes/.venv -type d -name "test"      -exec rm -rf {} + 2>/dev/null || true && \
    find /opt/hermes/.venv -name "*.pyc" -delete && \
    find /opt/hermes/.venv -name "*.pyo" -delete

# Strip node_modules of markdown docs, test dirs, and source maps to save space
RUN find /opt/hermes/node_modules -type d -name ".cache"    -exec rm -rf {} + 2>/dev/null || true && \
    find /opt/hermes/node_modules -name "*.map"             -delete 2>/dev/null || true && \
    find /opt/hermes/node_modules -name "CHANGELOG*"        -delete 2>/dev/null || true && \
    find /opt/hermes/node_modules -name "README*"           -delete 2>/dev/null || true

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM debian:13.4-slim

# Disable Python stdout buffering to ensure logs are printed immediately
ENV PYTHONUNBUFFERED=1

# Store Playwright browsers outside the data directory
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# Install runtime system dependencies only (no compilers/headers)
# nodejs/npm are needed at runtime for agent-browser, whatsapp-bridge, and npx
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        nodejs npm ripgrep ffmpeg procps ca-certificates \
        passwd && \
    rm -rf /var/lib/apt/lists/*

# Install Playwright's Chromium + its system library dependencies.
# --with-deps runs apt internally so it must happen while apt lists are fresh.
# We re-fetch lists here, run playwright, then purge lists in one layer.
COPY --from=builder /opt/hermes/node_modules /opt/hermes/node_modules
COPY --from=builder /opt/hermes/package.json  /opt/hermes/package.json
WORKDIR /opt/hermes
RUN apt-get update && \
    npx playwright install --with-deps chromium --only-shell && \
    npm cache clean --force && \
    rm -rf /var/lib/apt/lists/*

# Non-root user for runtime; UID can be overridden via HERMES_UID at runtime
RUN useradd -u 10000 -m -d /opt/data hermes

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

# Copy application source and pre-built artefacts from builder
COPY --from=builder /opt/hermes /opt/hermes

RUN chmod +x /opt/hermes/docker/entrypoint.sh && \
    chown -R hermes:hermes /opt/hermes

ENV HERMES_HOME=/opt/data
ENTRYPOINT [ "/opt/hermes/docker/entrypoint.sh" ]
