#!/usr/bin/env bash
set -euo pipefail

# initializeCommand — runs on the HOST machine before the container is built or started.
# $HOME here is the host user's home directory (e.g. /Users/you on macOS).

# Fail fast if Docker Desktop is not running, rather than waiting for
# `devcontainer up` to produce an inscrutable error much later.
if ! docker info &>/dev/null; then
  echo "error: Docker Desktop is not running. Please start Docker and try again." >&2
  exit 1
fi

# Fail fast if Claude Code Oauth token is not present.
claude_token_file="${HOME}/.bot/claude/oauth-token"
if [[ ! -s "$claude_token_file" ]]; then
  echo "error: no Claude Code OAuth token at $claude_token_file" >&2
  echo "       generate one on the host with: claude setup-token" >&2
  echo "       then save it: mkdir -p ~/.bot/claude && printf '%s' '<token>' > $claude_token_file && chmod 600 $claude_token_file" >&2
  exit 1
fi

# ensure bind-mount source paths exist on the host before Docker
# tries to mount them. Docker will fail at container launch if a bind-mount
# source is missing, so we pre-create directories and touch placeholder files.
# This script must only use tools available on the host.

# ensure the container workspace project config exists on the host and is initially populated with
# deny permissions to cover typical env file locations.
ws_name="$(basename "$(pwd)")"
mkdir -p "$HOME/.claude/projects/-workspaces-${ws_name}/"
project_settings="$HOME/.claude/projects/-workspaces-${ws_name}/settings.json"
if [[ ! -e "$project_settings" ]]; then
  cat > "$project_settings" <<'JSON'
{
  "permissions": {
    "deny": ["Read(path:**/.env)", "Read(path:**/.env.local)", "Read(path:**/.env.*.local)"]
  }
}
JSON
fi
touch "$HOME/.claude.json"
touch "$HOME/.gitconfig"
mkdir -p "$HOME/.config/graphite/"
touch "$HOME/.config/graphite/aliases"
touch "$HOME/.config/graphite/user_config"

