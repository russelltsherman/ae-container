FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
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
    @openai/codex@0.130.0 \
    @devcontainers/cli@0.87.0 \
    @withgraphite/graphite-cli@1.8.6 \
    yarn@1.22.22 \
    && npm cache clean --force

# Copy squid configuration files into the image
COPY etc/squid/squid.conf /etc/squid/squid.conf
COPY etc/squid/allowlist.conf /etc/squid/allowlist.conf

# Copy security init scripts into the image
COPY config/protect-egress /usr/local/sbin/protect-egress
COPY config/protect-paths /usr/local/sbin/protect-paths
COPY config/start-squid /usr/local/sbin/start-squid
RUN chmod 0755 /usr/local/sbin/protect-egress /usr/local/sbin/protect-paths /usr/local/sbin/start-squid

# Initialise the squid on-disk cache structure so it is ready when
# post-start.sh launches squid (as root via sudo) at container start.
RUN squid -z && rm -f /run/squid.pid /var/run/squid.pid

# Welcome banner: static ASCII art baked into the image; allowlist section
# is generated dynamically at shell start from the live allowlist.conf.
COPY etc/motd /etc/motd
COPY config/show-motd /usr/local/bin/show-motd
RUN chmod 0755 /usr/local/bin/show-motd \
    && echo '[ -x /usr/local/bin/show-motd ] && /usr/local/bin/show-motd' >> /etc/bash.bashrc

# Restrict vscode sudo to security init scripts only.
# The base image ships NOPASSWD:ALL which is too broad —
# the agent runs as vscode and must not be able to
# escalate to root for anything beyond starting the proxy.
# iptables restricts all traffic that is not through the squid proxy
COPY etc/sudoers.d/vscode /etc/sudoers.d/vscode
RUN chmod 0440 /etc/sudoers.d/vscode

# Mark the workspace as a safe.directory at the system scope so git tolerates
# the uid mismatch between the container user (vscode, uid 1000) and the host
# owner seen through virtioFS on Docker Desktop. Writing at --system scope
# keeps this out of the bind-mounted ~/.gitconfig, whose atomic-rename write
# path fails with EBUSY against a single-file bind mount.
RUN git config --system --add safe.directory /workspaces/agent

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
