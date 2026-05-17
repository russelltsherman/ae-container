#!/usr/bin/env bash
set -euo pipefail

# postCreateCommand - runs once inside the container as the container user (vscode),
# right after the container is first created. Its result is cached in the container
# — if you stop and restart the same container, it does not run again.
# Use it for one-time setup: installing workspace dependencies,
# yarn install, git config, seeding local databases, building artifacts that persist
# in the container's writable layer.

# $HOME here is /home/vscode inside the container.

# Purpose: configure the shell environment for Claude Code.
# Runs once per container creation, not on every attach.

# Add the claude function to .bashrc, which wraps the claude command and ensures it works in interactive shells.
echo 'claude() { clear; command claude "$@"; printf '"'"'\x1b[>0u'"'"'; }' >> ~/.bashrc
echo 'yolo() { clear; command claude --dangerously-skip-permissions "$@"; printf '"'"'\x1b[>0u'"'"'; }' >> ~/.bashrc
