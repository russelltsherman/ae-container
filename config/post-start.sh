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

# uncomment this like to bypass egress restriction
# exit 0

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
