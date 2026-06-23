#!/usr/bin/env bash
set -euo pipefail

# postCreateCommand - runs once inside the container as the container user (vscode),
# right after the container is first created. Its result is cached in the container
# — if you stop and restart the same container, it does not run again.
# Use it for one-time setup: installing workspace dependencies,
# yarn install, git config, seeding local databases, building artifacts that persist
# in the container's writable layer.

# $HOME here is /home/vscode inside the container.

# Seed a container-LOCAL ~/.claude.json from a read-only snapshot of the host
# file (mounted at ~/.claude.json.seed; see devcontainer.json). The host file is
# Claude Code's mutable per-machine state, rewritten in full on many operations;
# bind-mounting it read-write into every container made them share one inode, so
# concurrent rewrites interleaved and corrupted it ("invalid JSON" on launch).
# Copying once here gives each container its own writable copy — writes stay
# local and can never corrupt the host file. The snapshot carries over the
# migration/onboarding flags so launches don't re-prompt; if it is missing or
# itself invalid, fall back to an empty object so launch still succeeds.
claude_seed="$HOME/.claude.json.seed"
claude_state="$HOME/.claude.json"
cp "$claude_seed" "$claude_state"

# Mark the workspace as safe.directory so git tolerates the uid mismatch
# between the container user (vscode, uid 1000) and the host owner seen
# through virtioFS. Uses XDG git config (~/.config/git/config) rather than
# --system (needs root) or --global (~/.gitconfig is a bind mount that
# fails atomic-rename writes with EBUSY).
mkdir -p ~/.config/git
git config --file ~/.config/git/config --add safe.directory "$(pwd)"
