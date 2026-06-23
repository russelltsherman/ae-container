#!/bin/bash
set -euo pipefail

# Claude Code Devcontainer CLI Helper
# Provides the `aec` command for managing devcontainers

# Resolve symlinks to get actual script location
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
  cat <<EOF
    Usage: aec <command> [options]

    Commands:
        .                   Install devcontainer template to current directory and start
        up                  Start the devcontainer in current directory
        rebuild [--no-cache]  Rebuild the devcontainer (preserves auth volumes)
        down                Stop the devcontainer
        shell               Open a shell in the running container
        self-install        Install 'aec' command to ~/.local/bin
        update              Update aec to the latest version
        template [dir]      Copy devcontainer template to directory (default: current)
        exec <cmd>          Execute a command in the running container
        upgrade             Upgrade Claude Code to latest version
        mount <host> <cont> Add a mount to the devcontainer (recreates container)
        sync [project] [--trusted]  Sync sessions from devcontainers to host
        cp <cont> <host>    Copy files/directories from container to host
        destroy [-f]        Remove container, volumes, and image for current project
        help                Show this help message

    Examples:
        aec .                      # Install template and start container
        aec up                     # Start container in current directory
        aec rebuild                # Clean rebuild
        aec rebuild --no-cache     # Rebuild image from scratch (no build cache)
        aec shell                  # Open interactive shell
        aec self-install           # Install aec to PATH
        aec update                 # Update to latest version
        aec exec ls -la            # Run command in container
        aec upgrade                # Upgrade Claude Code to latest
        aec mount ~/data /data     # Add mount to container
        aec sync                   # Sync sessions from all devcontainers
        aec sync crypto            # Sync only matching devcontainer
        aec cp /some/file ./out    # Copy a path from container to host
        aec destroy                # Remove all project Docker resources
        aec destroy -f             # Skip confirmation prompt
EOF
}

log_info() {
  echo -e "${BLUE}[aec]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[aec]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[aec]${NC} $1"
}

log_error() {
  echo -e "${RED}[aec]${NC} $1" >&2
}

check_devcontainer_cli() {
  if ! command -v devcontainer &>/dev/null; then
    log_error "devcontainer CLI not found."
    log_info "Install it with: npm install -g @devcontainers/cli"
    exit 1
  fi
}

check_no_sys_admin() {
  local workspace="${1:-.}"
  local dc_json="$workspace/.agentcontainer/devcontainer.json"
  [[ -f "$dc_json" ]] || return 0
  if jq -e \
    '.runArgs[]? | select(test("SYS_ADMIN"))' \
    "$dc_json" >/dev/null 2>&1; then
    log_error "SYS_ADMIN capability detected in runArgs."
    log_error "This defeats the read-only .agentcontainer mount."
    exit 1
  fi
}

get_workspace_folder() {
  echo "${1:-$(pwd)}"
}

# Path to the devcontainer config. It lives in .agentcontainer/ (so a project
# can keep a separate human .devcontainer/), which is NOT where the devcontainer
# CLI auto-discovers config. Every `devcontainer up`/`exec` must therefore pass
# `--config <this path>`, or the CLI falls back to looking for
# .devcontainer/devcontainer.json and errors "devcontainer.json not found".
get_config_file() {
  local workspace_folder="$1"
  echo "$workspace_folder/.agentcontainer/devcontainer.json"
}

# Extract custom mounts from devcontainer.json to a temp file
# Returns the temp file path, or empty string if no custom mounts
#
# Security: .agentcontainer/ is mounted read-only inside the container to prevent
# a compromised process from injecting malicious mounts or commands into
# devcontainer.json that execute on the host during rebuild. This protection
# requires that SYS_ADMIN is never added to runArgs (it would allow remounting
# read-write).
extract_mounts_to_file() {
  local devcontainer_json="$1"
  local temp_file

  [[ -f "$devcontainer_json" ]] || return 0

  temp_file=$(mktemp)

  # Filter out default mounts by target path (immune to project name changes)
  local custom_mounts
  custom_mounts=$(jq -c '
    .mounts // [] | map(
      select(
        (contains("target=/commandhistory,") | not) and
        (contains("target=/home/vscode/.claude,") | not) and
        (contains("target=/home/vscode/.config/gh,") | not) and
        (contains("target=/home/vscode/.gitconfig,") | not) and
        (contains("target=/workspace/.agentcontainer,") | not)
      )
    ) | if length > 0 then . else empty end
  ' "$devcontainer_json" 2>/dev/null) || true

  if [[ -n "$custom_mounts" ]]; then
    echo "$custom_mounts" >"$temp_file"
    echo "$temp_file"
  else
    rm -f "$temp_file"
  fi
}

# Merge preserved mounts back into devcontainer.json
merge_mounts_from_file() {
  local devcontainer_json="$1"
  local mounts_file="$2"

  [[ -f "$mounts_file" ]] || return 0
  [[ -s "$mounts_file" ]] || return 0

  local custom_mounts
  custom_mounts=$(cat "$mounts_file")

  local updated
  updated=$(jq --argjson custom "$custom_mounts" '
    .mounts = ((.mounts // []) + $custom | unique)
  ' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}

# Add or update a mount in devcontainer.json
update_devcontainer_mounts() {
  local devcontainer_json="$1"
  local host_path="$2"
  local container_path="$3"
  local readonly="${4:-false}"

  local mount_str="source=${host_path},target=${container_path},type=bind"
  [[ "$readonly" == "true" ]] && mount_str="${mount_str},readonly"

  local updated
  updated=$(jq --arg target "$container_path" --arg mount "$mount_str" '
    .mounts = (
      ((.mounts // []) | map(select(contains("target=" + $target + ",") or endswith("target=" + $target) | not)))
      + [$mount]
    )
  ' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}

cmd_template() {
  local target_dir="${1:-.}"
  target_dir="$(cd "$target_dir" 2>/dev/null && pwd)" || {
    log_error "Directory does not exist: $1"
    exit 1
  }

  local devcontainer_dir="$target_dir/.agentcontainer"
  local devcontainer_json="$devcontainer_dir/devcontainer.json"
  local preserved_mounts=""

  if [[ -d "$devcontainer_dir" ]]; then
    log_warn "Devcontainer already exists at $devcontainer_dir"
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      exit 0
    fi

    # Preserve custom mounts before overwriting
    preserved_mounts=$(extract_mounts_to_file "$devcontainer_json")
    if [[ -n "$preserved_mounts" ]]; then
      log_info "Preserving custom mounts..."
    fi
  fi

  mkdir -p "$devcontainer_dir"

  # Copy template files
  cp -r "$SCRIPT_DIR/bin" "$devcontainer_dir/"
  cp -r "$SCRIPT_DIR/config" "$devcontainer_dir/"
  cp -r "$SCRIPT_DIR/etc" "$devcontainer_dir/"
  cp -r "$SCRIPT_DIR/scripts" "$devcontainer_dir/"
  cp -r "$SCRIPT_DIR/usr" "$devcontainer_dir/"
  # base.Dockerfile is the shared toolchain layer — always refresh it so projects
  # pick up base image updates.
  cp "$SCRIPT_DIR/base.Dockerfile" "$devcontainer_dir/"
  # local.Dockerfile is the per-project customization point. Seed it once, then
  # never overwrite, so edits a project makes survive re-running `aec template`.
  if [[ -f "$devcontainer_dir/local.Dockerfile" ]]; then
    log_info "Preserving existing local.Dockerfile"
  else
    cp "$SCRIPT_DIR/local.Dockerfile" "$devcontainer_dir/"
  fi
  cp "$SCRIPT_DIR/devcontainer.json" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/protected-paths" "$devcontainer_dir/"

  # Restore preserved mounts
  if [[ -n "$preserved_mounts" ]]; then
    merge_mounts_from_file "$devcontainer_json" "$preserved_mounts"
    rm -f "$preserved_mounts"
    log_info "Custom mounts restored"
  fi

  log_success "Template installed to $devcontainer_dir"
}

cmd_up() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  check_no_sys_admin "$workspace_folder"
  log_info "Starting devcontainer in $workspace_folder..."

  devcontainer up --workspace-folder "$workspace_folder" \
    --config "$(get_config_file "$workspace_folder")"
  log_success "Devcontainer started"
}

cmd_rebuild() {
  local no_cache=false
  local positional=""

  # Parse flags; remaining positional arg is the optional workspace folder.
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --no-cache)
      no_cache=true
      shift
      ;;
    *)
      positional="$1"
      shift
      ;;
    esac
  done

  local workspace_folder
  workspace_folder="$(get_workspace_folder "$positional")"

  check_devcontainer_cli
  check_no_sys_admin "$workspace_folder"

  local -a build_args=(--remove-existing-container)
  if [[ "$no_cache" == true ]]; then
    log_info "Rebuilding devcontainer (no cache) in $workspace_folder..."
    build_args+=(--build-no-cache)
  else
    log_info "Rebuilding devcontainer in $workspace_folder..."
  fi

  devcontainer up --workspace-folder "$workspace_folder" \
    --config "$(get_config_file "$workspace_folder")" "${build_args[@]}"
  log_success "Devcontainer rebuilt"
}

cmd_down() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  log_info "Stopping devcontainer..."

  # Get container ID and stop it
  local label="devcontainer.local_folder=$workspace_folder"
  local container_id
  container_id=$(docker ps -q --filter "label=$label" 2>/dev/null || true)

  if [[ -n "$container_id" ]]; then
    docker stop "$container_id"
    log_success "Devcontainer stopped"
  else
    log_warn "No running devcontainer found for $workspace_folder"
  fi
}

cmd_shell() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  log_info "Opening shell in devcontainer..."

  # Clear inside the container, not on the host: `devcontainer exec`
  # prints connection/image-up-to-date noise *after* a host-side clear,
  # which would re-dirty the screen before the motd appears.

  # printf '\033[2J\033[3J\033[H'
  # - Three ANSI escape sequences sent to the terminal:
  #   - \033[2J — clear the entire visible screen
  #   - \033[3J — clear the scrollback buffer (so you can't scroll up to see prior output)
  #   - \033[H — move the cursor to the top-left (home) position
  # - Net effect: a hard "fresh terminal" wipe, more thorough than plain clear.
  devcontainer exec --workspace-folder "$workspace_folder" \
    --config "$(get_config_file "$workspace_folder")" \
    bash -c "printf '\033[2J\033[3J\033[H'; exec bash -l"
}

cmd_exec() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  devcontainer exec --workspace-folder "$workspace_folder" \
    --config "$(get_config_file "$workspace_folder")" "$@"
}

cmd_mount() {
  local host_path="${1:-}"
  local container_path="${2:-}"
  local readonly="false"

  if [[ -z "$host_path" ]] || [[ -z "$container_path" ]]; then
    log_error "Usage: aec mount <host_path> <container_path> [--readonly]"
    exit 1
  fi

  [[ "${3:-}" == "--readonly" ]] && readonly="true"

  # Expand and validate host path
  host_path="$(cd "$host_path" 2>/dev/null && pwd)" || {
    log_error "Host path does not exist: $1"
    exit 1
  }

  local workspace_folder
  workspace_folder="$(get_workspace_folder)"
  local devcontainer_json="$workspace_folder/.agentcontainer/devcontainer.json"

  if [[ ! -f "$devcontainer_json" ]]; then
    log_error "No devcontainer.json found. Run 'aec template' first."
    exit 1
  fi

  check_devcontainer_cli

  log_info "Adding mount: $host_path → $container_path"
  update_devcontainer_mounts "$devcontainer_json" "$host_path" "$container_path" "$readonly"

  log_info "Recreating container with new mount..."
  devcontainer up --workspace-folder "$workspace_folder" \
    --config "$devcontainer_json" --remove-existing-container

  log_success "Mount added: $host_path → $container_path"
}

cmd_sync() {
  local filter=""
  local trusted=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --trusted)
      trusted=true
      shift
      ;;
    *)
      filter="$1"
      shift
      ;;
    esac
  done

  local host_projects="${HOME}/.claude/projects"

  if [[ "$trusted" == false ]]; then
    log_warn "This copies files from devcontainers to your host filesystem."
    log_warn "Only proceed if you trust the container contents."
    log_info "Use --trusted to skip this prompt."
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      exit 0
    fi
  fi

  # Discover all devcontainers (running + stopped) by label.
  local container_ids
  container_ids=$(docker ps -a -q \
    --filter "label=devcontainer.local_folder" 2>/dev/null || true)

  if [[ -z "$container_ids" ]]; then
    log_error "No devcontainers found (running or stopped)."
    exit 1
  fi

  # List discovered devcontainers.
  log_info "Discovered devcontainers:"
  local matched_any=false
  while IFS= read -r cid; do
    local name folder status
    name=$(sync_get_project_name "$cid")
    folder=$(docker inspect --format \
      '{{index .Config.Labels "devcontainer.local_folder"}}' "$cid")
    status=$(docker inspect --format '{{.State.Status}}' "$cid")

    if [[ -n "$filter" ]]; then
      if ! echo "$name" | grep -qi "$filter"; then
        continue
      fi
    fi

    matched_any=true
    echo "  - ${name} (${status}) ${folder}"
  done <<< "$container_ids"

  if [[ "$matched_any" == false ]]; then
    log_error "No devcontainers matching '${filter}'."
    echo ""
    echo "Available:"
    while IFS= read -r cid; do
      local name status
      name=$(sync_get_project_name "$cid")
      status=$(docker inspect --format '{{.State.Status}}' "$cid")
      echo "  - ${name} (${status})"
    done <<< "$container_ids"
    exit 1
  fi

  echo ""

  # Sync matching containers.
  while IFS= read -r cid; do
    local name
    name=$(sync_get_project_name "$cid")

    if [[ -n "$filter" ]]; then
      if ! echo "$name" | grep -qi "$filter"; then
        continue
      fi
    fi

    sync_one_container "$cid" "$host_projects"
    echo ""
  done <<< "$container_ids"

  log_success "Run '/insights' in Claude Code to include these sessions."
}

# Extract project name from devcontainer.local_folder label.
sync_get_project_name() {
  local folder
  folder=$(docker inspect --format \
    '{{index .Config.Labels "devcontainer.local_folder"}}' "$1")
  basename "$folder"
}

# Resolve the Claude projects dir inside a container without
# docker exec (works on stopped containers too).
# Reads CLAUDE_CONFIG_DIR from container env, falls back to
# /home/<user>/.claude.
sync_get_claude_projects_dir() {
  local cid="$1"
  local claude_dir

  claude_dir=$(docker inspect --format '{{json .Config.Env}}' "$cid" \
    | tr ',' '\n' | tr -d '[]"' \
    | grep '^CLAUDE_CONFIG_DIR=' \
    | cut -d= -f2- || true)

  if [[ -n "$claude_dir" ]]; then
    echo "${claude_dir}/projects"
    return
  fi

  local user
  user=$(docker inspect --format '{{.Config.User}}' "$cid")
  if [[ -z "$user" || "$user" == "root" ]]; then
    echo "/root/.claude/projects"
  else
    echo "/home/${user}/.claude/projects"
  fi
}

sync_one_container() {
  local cid="$1"
  local host_projects="$2"
  local project_name status claude_dir folder

  project_name=$(sync_get_project_name "$cid")
  folder=$(docker inspect --format \
    '{{index .Config.Labels "devcontainer.local_folder"}}' "$cid")
  status=$(docker inspect --format '{{.State.Status}}' "$cid")
  claude_dir=$(sync_get_claude_projects_dir "$cid")

  log_info "=== ${project_name} (${status}) ==="
  echo "  Host path:  ${folder}"
  echo "  Container:  ${cid:0:12}"

  # docker cp works on both running and stopped containers.
  local tmpdir
  tmpdir=$(mktemp -d)

  if ! docker cp "${cid}:${claude_dir}/." "$tmpdir/" 2>/dev/null; then
    echo "  No sessions found, skipping."
    rm -rf "$tmpdir"
    return 0
  fi

  local session_count
  session_count=$(find "$tmpdir" -name '*.jsonl' | wc -l | tr -d ' ')

  if [[ "$session_count" -eq 0 ]]; then
    echo "  No sessions found, skipping."
    rm -rf "$tmpdir"
    return 0
  fi

  echo "  Sessions:   ${session_count}"

  local total_copied=0

  # Sync each project key subdirectory.
  for key_path in "$tmpdir"/*/; do
    [[ ! -d "$key_path" ]] && continue
    local key dest_key
    key=$(basename "$key_path")

    if [[ "$key" == "-workspace" ]]; then
      dest_key="-devcontainer-${project_name}"
    else
      dest_key="${key}"
    fi

    local dest_dir="${host_projects}/${dest_key}"
    mkdir -p "$dest_dir"

    local copied=0
    while IFS= read -r -d '' file; do
      local rel="${file#"$key_path"}"
      local dest_file="${dest_dir}/${rel}"
      mkdir -p "$(dirname "$dest_file")"

      if [[ ! -e "$dest_file" ]] \
          || [[ "$file" -nt "$dest_file" ]]; then
        cp -p "$file" "$dest_file"
        copied=$((copied + 1))
      fi
    done < <(find "$key_path" -type f -print0)

    if [[ "$copied" -gt 0 ]]; then
      echo "  Synced ${copied} file(s) -> ${dest_key}"
    fi
    total_copied=$((total_copied + copied))
  done

  # Handle .jsonl files directly in projects/ (no subdirectory).
  local orphan_copied=0
  local dest_dir="${host_projects}/-devcontainer-${project_name}"
  mkdir -p "$dest_dir"

  while IFS= read -r -d '' file; do
    local name
    name=$(basename "$file")
    local dest_file="${dest_dir}/${name}"

    if [[ ! -e "$dest_file" ]] \
        || [[ "$file" -nt "$dest_file" ]]; then
      cp -p "$file" "$dest_file"
      orphan_copied=$((orphan_copied + 1))
    fi
  done < <(find "$tmpdir" -maxdepth 1 -name '*.jsonl' -print0)

  if [[ "$orphan_copied" -gt 0 ]]; then
    echo "  Synced ${orphan_copied} file(s) -> -devcontainer-${project_name}"
    total_copied=$((total_copied + orphan_copied))
  fi

  rm -rf "$tmpdir"

  echo "  Total: ${total_copied} file(s) synced."
}

cmd_cp() {
  local container_path="${1:-}"
  local host_path="${2:-}"

  if [[ -z "$container_path" ]] || [[ -z "$host_path" ]]; then
    log_error "Usage: aec cp <container_path> <host_path>"
    exit 1
  fi

  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  # Find the running container
  local label="devcontainer.local_folder=$workspace_folder"
  local container_id
  container_id=$(docker ps -q --filter "label=$label" 2>/dev/null || true)

  if [[ -z "$container_id" ]]; then
    log_error "No running devcontainer found for $workspace_folder"
    exit 1
  fi

  log_info "Copying $container_path → $host_path"
  docker cp "$container_id:$container_path" "$host_path"
  log_success "Copied $container_path → $host_path"
}

cmd_self_install() {
  local install_dir="$HOME/.local/bin"
  local install_path="$install_dir/aec"

  mkdir -p "$install_dir"

  # Create a symlink to the original script
  ln -sf "$SCRIPT_DIR/$SCRIPT_NAME" "$install_path"

  log_success "Installed 'aec' to $install_path"

  # Check if in PATH
  if [[ ":$PATH:" != *":$install_dir:"* ]]; then
    log_warn "$install_dir is not in your PATH"
    log_info "Add this to your shell profile:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

cmd_update() {
  log_info "Updating aec..."

  if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    log_error "Not a git repository: $SCRIPT_DIR"
    log_info "Re-clone with: rm -rf ~/.agentcontainer && git clone https://github.com/russelltsherman/ae-container ~/.agentcontainer"
    exit 1
  fi

  local before_sha after_sha
  before_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

  if ! git -C "$SCRIPT_DIR" pull --ff-only; then
    log_error "Update failed. Try: cd $SCRIPT_DIR && git pull"
    exit 1
  fi

  after_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

  if [[ "$before_sha" == "$after_sha" ]]; then
    log_success "Already up to date"
  else
    log_success "Updated from ${before_sha:0:7} to ${after_sha:0:7}"
  fi
}

cmd_dot() {
  # Install template and start container in one command
  cmd_template "."
  cmd_up "."
}

# Discovers all Docker resources associated with the current workspace.
# Sets global variables: CONTAINER_ID, CONTAINER_STATUS, VOLUMES (array), IMAGE, IMAGE_UID
discover_resources() {
  local workspace_folder="$1"
  local label="devcontainer.local_folder=$workspace_folder"

  CONTAINER_ID=""
  CONTAINER_STATUS=""
  VOLUMES=()
  IMAGE=""
  IMAGE_UID=""

  # Find container (any state: running, stopped, created, etc.)
  CONTAINER_ID=$(docker ps -aq --filter "label=$label" 2>/dev/null | head -1)

  if [[ -z "$CONTAINER_ID" ]]; then
    return 0
  fi

  # Get container status
  CONTAINER_STATUS=$(docker inspect "$CONTAINER_ID" --format '{{.State.Status}}' 2>/dev/null || true)

  # Get volumes (docker volumes only, not bind mounts)
  while IFS= read -r vol; do
    [[ -n "$vol" ]] && VOLUMES+=("$vol")
  done < <(docker inspect "$CONTAINER_ID" --format '{{json .Mounts}}' 2>/dev/null \
    | jq -r '.[] | select(.Type == "volume") | .Name' 2>/dev/null)

  # Get image and its -uid variant
  IMAGE=$(docker inspect "$CONTAINER_ID" --format '{{.Config.Image}}' 2>/dev/null || true)
  if [[ -n "$IMAGE" ]]; then
    if [[ "$IMAGE" == *-uid ]]; then
      IMAGE_UID="$IMAGE"
      IMAGE="${IMAGE%-uid}"
    else
      IMAGE_UID="${IMAGE}-uid"
    fi
  fi
}

print_destroy_summary() {
  echo ""
  log_warn "The following resources will be permanently removed:"
  echo ""

  if [[ -n "$CONTAINER_ID" ]]; then
    local container_name
    container_name=$(docker inspect "$CONTAINER_ID" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')
    echo "  Container:  ${container_name:-$CONTAINER_ID}"
    if [[ "$CONTAINER_STATUS" == "running" ]]; then
      echo "              (currently running -- will be force-stopped)"
    fi
  fi

  if [[ ${#VOLUMES[@]} -gt 0 ]]; then
    echo "  Volumes:"
    for vol in "${VOLUMES[@]}"; do
      echo "              $vol"
    done
  fi

  if [[ -n "$IMAGE" ]]; then
    echo "  Image:      $IMAGE"
    if docker image inspect "$IMAGE_UID" &>/dev/null; then
      echo "              $IMAGE_UID"
    fi
  fi

  echo ""
}

cmd_destroy() {
  local force=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        force=true
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  discover_resources "$workspace_folder"

  # No resources found (idempotent behavior)
  if [[ -z "$CONTAINER_ID" ]]; then
    log_info "No devcontainer found for $workspace_folder"
    return 0
  fi

  print_destroy_summary

  # Running container warning
  if [[ "$CONTAINER_STATUS" == "running" && "$force" != true ]]; then
    log_warn "Container is currently running!"
    read -p "Force-stop the running container? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      return 0
    fi
  fi

  # Main confirmation prompt
  if [[ "$force" != true ]]; then
    read -p "Destroy these resources? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      return 0
    fi
  fi

  # Deletion, in order: stop, remove container, volumes, images
  if [[ -n "$CONTAINER_ID" && "$CONTAINER_STATUS" == "running" ]]; then
    log_info "Stopping container..."
    docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$CONTAINER_ID" ]]; then
    log_info "Removing container..."
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  for vol in "${VOLUMES[@]}"; do
    log_info "Removing volume: $vol"
    docker volume rm -f "$vol" >/dev/null 2>&1 || true
  done

  if [[ -n "$IMAGE" ]]; then
    log_info "Removing image: $IMAGE"
    docker rmi -f "$IMAGE" >/dev/null 2>&1 || true
    if docker image inspect "$IMAGE_UID" &>/dev/null 2>&1; then
      log_info "Removing image: $IMAGE_UID"
      docker rmi -f "$IMAGE_UID" >/dev/null 2>&1 || true
    fi
  fi

  log_success "All resources destroyed for $workspace_folder"
}

# Main command dispatcher
main() {
  if [[ $# -eq 0 ]]; then
    print_usage
    exit 1
  fi

  local command="$1"
  shift

  case "$command" in
  .)
    cmd_dot
    ;;
  up)
    cmd_up "$@"
    ;;
  rebuild)
    cmd_rebuild "$@"
    ;;
  down)
    cmd_down "$@"
    ;;
  destroy)
    cmd_destroy "$@"
    ;;
  shell)
    cmd_shell
    ;;
  exec)
    [[ "${1:-}" == "--" ]] && shift
    cmd_exec "$@"
    ;;
  mount)
    cmd_mount "$@"
    ;;
  sync)
    cmd_sync "$@"
    ;;
  cp)
    cmd_cp "$@"
    ;;
  self-install)
    cmd_self_install
    ;;
  update)
    cmd_update
    ;;
  template)
    cmd_template "$@"
    ;;
  help | --help | -h)
    print_usage
    ;;
  *)
    log_error "Unknown command: $command"
    print_usage
    exit 1
    ;;
  esac
}

main "$@"