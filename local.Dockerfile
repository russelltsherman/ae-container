# Per-container image: the small, frequently-changing security/config layers on
# top of the toolchain base. This is the per-project customization point — edit
# it freely; `aec template` seeds it once and never overwrites it.
#
# The base (apt deps, Node, the agent CLIs incl. Claude) lives in base.Dockerfile
# and is built on demand by scripts/initialize.sh, which tags it
# `ae-container-base:local`. Docker resolves this FROM from the local image store
# (no registry pull), so the base image must already exist when `devcontainer up`
# runs this local.Dockerfile — initialize.sh (the initializeCommand) guarantees that.
FROM ae-container-base:local

# The base image ends as USER vscode (for the Claude CLI install). The layers
# below write to /etc and /usr/local, so switch back to root; the final USER is
# reset to vscode at the end (it is the container's runtime user / remoteUser).
USER root

# Copy squid configuration files into the image. allowlist.conf is the shared,
# reviewed allowlist; local.allowlist.conf holds per-project additions (seeded
# once by `aec template`, never overwritten). squid.conf merges both. Both must
# be present before the `squid -z` below parses the config.
COPY etc/squid/squid.conf /etc/squid/squid.conf
COPY etc/squid/allowlist.conf /etc/squid/allowlist.conf
COPY etc/squid/local.allowlist.conf /etc/squid/local.allowlist.conf

# Copy security init scripts into the image
COPY usr/local/sbin/protect-egress /usr/local/sbin/protect-egress
COPY usr/local/sbin/protect-paths /usr/local/sbin/protect-paths
COPY usr/local/sbin/start-squid /usr/local/sbin/start-squid
RUN chmod 0755 /usr/local/sbin/protect-egress /usr/local/sbin/protect-paths /usr/local/sbin/start-squid

# Initialise the squid on-disk cache structure so it is ready when
# post-start.sh launches squid (as root via sudo) at container start.
RUN squid -z && rm -f /run/squid.pid /var/run/squid.pid

# Welcome banner: static ASCII art baked into the image; allowlist section is
# generated at shell start from the baked allowlist files (shared + local).
COPY etc/motd /etc/motd
COPY usr/local/bin/show-motd /usr/local/bin/show-motd
RUN chmod 0755 /usr/local/bin/show-motd \
    && echo '[ -x /usr/local/bin/show-motd ] && /usr/local/bin/show-motd' >> /etc/bash.bashrc

COPY etc/profile.d/. /etc/profile.d/
RUN chmod 0644 /etc/profile.d/*

# Restrict vscode sudo to security init scripts only.
# The base image ships NOPASSWD:ALL which is too broad —
# the agent runs as vscode and must not be able to
# escalate to root for anything beyond starting the proxy.
# iptables restricts all traffic that is not through the squid proxy
COPY etc/sudoers.d/vscode /etc/sudoers.d/vscode
RUN chmod 0440 /etc/sudoers.d/vscode

# BIN scripts
COPY --chown=vscode:vscode bin /home/vscode/bin

# config
COPY --chown=vscode:vscode config /home/vscode/.config

# The agent runs as vscode (also the devcontainer remoteUser).
USER vscode
