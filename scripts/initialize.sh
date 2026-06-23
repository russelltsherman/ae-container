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

# Build (or reuse) the local toolchain base image that the devcontainer's
# local.Dockerfile builds FROM. The base carries the slow, rarely-changing layers
# (apt deps, Node, the agent CLIs); the per-container build only re-runs the
# small security/config layers on top. local.Dockerfile starts
# `FROM ae-container-base:local`, and Docker resolves that from the local image
# store (no registry), so the image must exist before `devcontainer up` builds.
#
# The image is tagged with a content hash of base.Dockerfile: if an image for
# the current hash exists we reuse it, otherwise we build it. Editing
# base.Dockerfile changes the hash and triggers an automatic rebuild, so the
# base is never silently stale. The stable `:local` alias is always repointed at
# the current hash, so local.Dockerfile's FROM line never has to change.
#
# AEC_BASE_DOCKERFILE overrides the base Dockerfile path (testing seam only;
# production resolves it relative to this script).
base_image_repo="ae-container-base"
base_dockerfile="${AEC_BASE_DOCKERFILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/base.Dockerfile}"

if [[ ! -f "$base_dockerfile" ]]; then
  echo "error: base image Dockerfile not found at $base_dockerfile" >&2
  exit 1
fi

# Portable SHA-256: sha256sum on Linux, shasum on macOS.
if command -v sha256sum >/dev/null 2>&1; then
  base_hash="$(sha256sum < "$base_dockerfile" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  base_hash="$(shasum -a 256 < "$base_dockerfile" | cut -d' ' -f1)"
else
  echo "error: no sha256 tool (need sha256sum or shasum) to tag the base image" >&2
  exit 1
fi
base_image_hashed="${base_image_repo}:${base_hash:0:12}"
base_image_local="${base_image_repo}:local"

if docker image inspect "$base_image_hashed" >/dev/null 2>&1; then
  echo "base image up to date: $base_image_hashed"
else
  echo "building base image: $base_image_hashed (runs only when base.Dockerfile changes)"
  docker build \
    -f "$base_dockerfile" \
    -t "$base_image_hashed" \
    "$(dirname "$base_dockerfile")"
fi

# Always repoint the stable alias local.Dockerfile's FROM references at the
# current hash, so reverting base.Dockerfile reuses the matching cached image.
docker tag "$base_image_hashed" "$base_image_local"

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

