#!/usr/bin/env bash
set -euo pipefail

# postStartCommand runs every time the container starts, including the
# initial create and every subsequent restart.
# Use it for ephemeral processes that don't survive a restart: starting
# background services (like squid, this repo), applying in-memory state
# (like our protect-paths bind mounts — they live in the mount namespace
# and vanish on stop), waiting for ports to be ready.

# Shadow paths from .devcontainer/protected-paths before anything else so
# there is no window where the agent (or anything it spawns) can read host
# secrets. This runs inside the container because nested bind mounts inside
# the virtioFS workspace are rejected by runc on macOS Docker Desktop.
sudo /usr/local/sbin/protect-paths

# Lock down egress before squid starts so there is no window of unrestricted
# outbound access. Squid runs as the proxy user, which is explicitly permitted
# by the iptables rules, so it can reach the internet once it starts.
sudo /usr/local/sbin/protect-egress

# start squid proxy via the pinned launcher (sudoers allows this exact path
# with no argument control; running `sudo squid` directly would let the agent
# start a permissive config and bypass the allowlist).
sudo /usr/local/sbin/start-squid &
SQUID_PID=$!

# Give it a moment to fail if config is bad
sleep 1

# Check if process is still running
if ! kill -0 $SQUID_PID 2>/dev/null; then
  echo "error: squid failed to start (check logs)" >&2
  exit 1
fi

# Authenticate the gh/gt CLIs only after the proxy is up. Both validate their
# tokens over the network, and egress is dropped until squid is running — doing
# this earlier fails with "connection refused" to 127.0.0.1:3128 and, under
# `set -e`, aborts container start. Auth is a convenience: a missing/expired
# token must not brick the container, so failures warn instead of aborting.

# authenticate gh cli
GITHUB_TOKEN_FILE="/home/vscode/.config/gh/token"
if [[ -f "$GITHUB_TOKEN_FILE" ]]; then
  GH_TOKEN="$(head -n 1 "$GITHUB_TOKEN_FILE")"
  echo "$GH_TOKEN" | gh auth login --with-token \
    || echo "warning: gh auth failed (check token / proxy)" >&2
fi

# authenticate gt cli
GRAPHITE_TOKEN_FILE="/home/vscode/.config/graphite/token"
if [[ -f "$GRAPHITE_TOKEN_FILE" ]]; then
  GT_TOKEN="$(head -n 1 "$GRAPHITE_TOKEN_FILE")"
  gt auth --token "$GT_TOKEN" \
    || echo "warning: gt auth failed (check token / proxy)" >&2
fi
