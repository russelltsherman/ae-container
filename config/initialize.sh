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

# on macos the claude OAuth is stored in the system keychain
# on linux this is stored in a file ~/.claude/.credentials.json
# on mac we will export credentials from the system keychain and create the file
# so this file can be mounted into the devcontainer and shared
macos_keychain_export() {
  if [[ "$(uname)" != "Darwin" ]]; then
    return 0
  fi

  local service="Claude Code-credentials"
  local account
  account="$(whoami)"
  local credentials_file="${HOME}/.claude/.credentials.json"

  local credentials
  credentials="$(security find-generic-password \
    -s "$service" \
    -a "$account" \
    -w 2>/dev/null)" || {
    echo "error: no Claude Code credentials found in keychain" >&2
    echo "       run 'claude' and log in first" >&2
    exit 1
  }

  mkdir -p "$(dirname "$credentials_file")"
  printf '%s' "$credentials" > "$credentials_file"
  chmod 600 "$credentials_file"
  echo "credentials written to $credentials_file"
}

macos_keychain_export

# ensure bind-mount source paths exist on the host before Docker
# tries to mount them. Docker will fail at container launch if a bind-mount
# source is missing, so we pre-create directories and touch placeholder files.
# This script must only use tools available on the host.

# ensure the container workspace project config exists on the host and is initially populated with
# deny permissions to cover typical env file locations.
mkdir -p "$HOME/.claude/projects/-workspaces-archive/"
project_settings="$HOME/.claude/projects/-workspaces-archive/settings.json"
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
touch "$HOME/.claude/.credentials.json"
touch "$HOME/.gitconfig"
mkdir -p "$HOME/.config/graphite/"
touch "$HOME/.config/graphite/aliases"
touch "$HOME/.config/graphite/user_config"

