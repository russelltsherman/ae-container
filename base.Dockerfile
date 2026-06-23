# Toolchain base image for the devcontainer.
#
# This carries the slow, rarely-changing layers (apt deps, Node, the agent CLIs)
# so the per-container build in ./local.Dockerfile only re-runs the small
# security/config layers on top. scripts/initialize.sh (the host-side
# initializeCommand) builds this image on demand before `devcontainer up`,
# tagging it with a content hash of THIS file so it rebuilds only when this file
# changes. local.Dockerfile then starts `FROM ae-container-base:local`.
#
# NOTE: the Claude CLI below pins to the published "latest" at build time. Because
# this image is content-hash cached, that pin only refreshes when this file
# changes. To force a fresh Claude (or any re-pull) without editing this file,
# remove the cached base image on the host: `docker rmi ae-container-base:local`
# (and the `ae-container-base:<hash>` tag), then rebuild. `aec rebuild --no-cache`
# rebuilds the top image only and does NOT rebuild this base.

FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    bats \
    ca-certificates \
    curl \
    gh \
    git \
    gnupg \
    iptables \
    jq \
    squid \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 26.x
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/nodesource.gpg] \
      https://deb.nodesource.com/node_26.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y \
    nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# install NPM dependencies
RUN npm install -g \
    @mariozechner/pi-coding-agent@0.73.1 \
    @openai/codex@0.137.0 \
    @devcontainers/cli@0.87.0 \
    @withgraphite/graphite-cli@1.8.6 \
    && npm cache clean --force

# Install Claude Code as vscode user (native installer writes to ~/.local/bin)
USER vscode

# Create the Claude project directory so the read-only bind mount in
# devcontainer.json has a valid parent directory to target at container start.
RUN mkdir -p /home/vscode/.claude/projects/-workspaces-agent

# Install Claude Code CLI from the official binary release.
# Downloads the versioned binary, verifies its SHA256 checksum against the
# signed manifest before executing anything, then uses the binary's own
# install subcommand to place it on PATH. No npm, no unverified script execution.
RUN ARCH="$(uname -m)" \
    && case "$ARCH" in \
         x86_64)  PLATFORM="linux-x64"   ;; \
         aarch64) PLATFORM="linux-arm64"  ;; \
         *) echo "error: unsupported architecture: $ARCH" >&2; exit 1 ;; \
       esac \
    && echo "PLATFORM: $PLATFORM" \
    && VERSION="$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest)" \
    && echo "VERSION: $VERSION" \
    && CHECKSUM="$(curl -fsSL "https://downloads.claude.ai/claude-code-releases/${VERSION}/manifest.json" \
         | jq -r ".platforms[\"${PLATFORM}\"].checksum")" \
    && echo "CHECKSUM: $CHECKSUM" \
    && curl -fsSL "https://downloads.claude.ai/claude-code-releases/${VERSION}/${PLATFORM}/claude" \
         -o /tmp/claude \
    && echo "${CHECKSUM}  /tmp/claude" | sha256sum --check \
    && chmod +x /tmp/claude \
    && /tmp/claude install \
    && rm -f /tmp/claude
