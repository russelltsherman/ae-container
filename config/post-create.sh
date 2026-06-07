#!/usr/bin/env bash
set -euo pipefail

# postCreateCommand - runs once inside the container as the container user (vscode),
# right after the container is first created. Its result is cached in the container
# — if you stop and restart the same container, it does not run again.
# Use it for one-time setup: installing workspace dependencies,
# yarn install, git config, seeding local databases, building artifacts that persist
# in the container's writable layer.

# $HOME here is /home/vscode inside the container.

# Mark the workspace as safe.directory so git tolerates the uid mismatch
# between the container user (vscode, uid 1000) and the host owner seen
# through virtioFS. Uses XDG git config (~/.config/git/config) rather than
# --system (needs root) or --global (~/.gitconfig is a bind mount that
# fails atomic-rename writes with EBUSY).
mkdir -p ~/.config/git
git config --file ~/.config/git/config --add safe.directory "$(pwd)"

# Purpose: configure the shell environment for Claude Code.
# Runs once per container creation, not on every attach.

# Add the claude function to .bashrc, which wraps the claude command and ensures it works in interactive shells.
echo 'claude() { clear; command claude "$@"; printf '"'"'\x1b[>0u'"'"'; }' >> ~/.bashrc
echo 'yolo() { clear; command claude --dangerously-skip-permissions "$@"; printf '"'"'\x1b[>0u'"'"'; }' >> ~/.bashrc

# OMLX variants: mirror the env vars that `omlx launch claude` sets.
# Key differences from direct Anthropic API usage:
#   - ANTHROPIC_API_KEY is unset (not blank — blank still triggers conflict)
#   - Auth goes via ANTHROPIC_AUTH_TOKEN as a Bearer token
#   - Large API_TIMEOUT_MS for local inference (model loading + generation)
#   - Disable attribution header and non-essential traffic
#   - Override all model slots so Claude Code doesn't request unavailable models
# Set OMLX_MODEL on the host to the model id you want (e.g. "qwen3-32b-4bit").
cat >> ~/.bashrc << 'BASHRC'
omlx() {
  clear
  local -a _env=(
    -u ANTHROPIC_API_KEY
    ANTHROPIC_BASE_URL="http://host.docker.internal:${OMLX_PORT:-8000}"
    ANTHROPIC_AUTH_TOKEN="${OMLX_API_KEY:-omlx}"
    CLAUDE_CODE_ATTRIBUTION_HEADER=0
    API_TIMEOUT_MS=3000000
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  )
  if [[ -n "${OMLX_MODEL:-}" ]]; then
    _env+=(
      ANTHROPIC_DEFAULT_OPUS_MODEL="$OMLX_MODEL"
      ANTHROPIC_DEFAULT_SONNET_MODEL="$OMLX_MODEL"
      ANTHROPIC_DEFAULT_HAIKU_MODEL="$OMLX_MODEL"
      CLAUDE_CODE_SUBAGENT_MODEL="$OMLX_MODEL"
    )
    if [[ -n "${OMLX_CONTEXT_WINDOW:-}" ]]; then
      _env+=(CLAUDE_CODE_AUTO_COMPACT_WINDOW="$OMLX_CONTEXT_WINDOW")
    fi
  fi
  env "${_env[@]}" claude "$@"
  printf '\x1b[>0u'
}
omlx-yolo() {
  omlx --dangerously-skip-permissions "$@"
}
BASHRC

# Ollama variants: Ollama 0.24+ natively serves the Anthropic Messages API at
# /v1/messages, so Claude Code talks to it directly — no proxy, no omlx.
# Determined empirically against claude 2.1.160 + ollama 0.24.0:
#   - Only two vars are actually required: ANTHROPIC_BASE_URL and ANTHROPIC_MODEL.
#     Without a model override Claude requests claude-* model IDs that Ollama
#     doesn't have and every call 404s. ANTHROPIC_MODEL is a global override —
#     it covers the main loop AND subagents, so the per-tier DEFAULT_*_MODEL and
#     CLAUDE_CODE_SUBAGENT_MODEL vars the omlx function uses are unnecessary here.
#   - OLLAMA_MODEL is required (:?) because not setting it is a guaranteed 404;
#     fail loudly instead of launching into a broken session.
#   - Auth is NOT required (Ollama ignores credentials); ANTHROPIC_AUTH_TOKEN is
#     set only as defense for a host that isn't logged into claude.ai.
#   - Reaching the host (outside this launcher): on Docker Desktop (macOS/Windows)
#     host.docker.internal proxies to the host loopback, so a default
#     127.0.0.1-bound `ollama serve` is reachable as-is (verified end-to-end).
#     On native Linux Docker you'd instead need ollama bound to all interfaces
#     (OLLAMA_HOST=0.0.0.0:11434).
#   - If Claude Code's large prompts (30k+ tokens) get truncated, raise the
#     server-side OLLAMA_CONTEXT_LENGTH to fit the model's context window.
cat >> ~/.bashrc << 'BASHRC'
ollama() {
  clear
  local -a _env=(
    -u ANTHROPIC_API_KEY                              # defensive: avoid real-key conflict
    ANTHROPIC_BASE_URL="http://host.docker.internal:${OLLAMA_PORT:-11434}"
    ANTHROPIC_MODEL="${OLLAMA_MODEL:?set OLLAMA_MODEL to an installed Ollama model, e.g. qwen3.6:35b-mlx}"
    ANTHROPIC_SMALL_FAST_MODEL="${OLLAMA_MODEL}"      # defensive: background/classifier calls
    ANTHROPIC_AUTH_TOKEN="${OLLAMA_API_KEY:-ollama}"  # optional: Ollama ignores the value
    API_TIMEOUT_MS=3000000                            # local inference is slow
    CLAUDE_CODE_ATTRIBUTION_HEADER=0
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  )
  env "${_env[@]}" claude "$@"
  printf '\x1b[>0u'
}
ollama-yolo() {
  ollama --dangerously-skip-permissions "$@"
}
BASHRC
