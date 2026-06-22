#!/usr/bin/env bats
# test/devc.bats — consolidated devcontainer test suite.
#
# The repository is a devcontainer *template*: the canonical sources live at
# the repo root (config/, scripts/, usr/, etc/, bin/, Dockerfile,
# devcontainer.json, protected-paths) and install.sh's `devc template` copies
# them into a target project's .devcontainer/ (which is gitignored / generated).
#
# Layers (mirrors the host-side / in-container split):
#
#   UNIT (no container, stubbed) — target the repo-root sources:
#     - install.sh            the `devc` host CLI (up/rebuild/down/template/...)
#     - scripts/initialize.sh host-side initializeCommand: docker probe, Claude
#                             OAuth token presence check, project settings
#                             seeding, mount-source placeholder creation
#     - usr/local/sbin/protect-paths  protected-paths pattern parser / exclusions
#
#   INTEGRATION (live container) — runtime invariants via docker inspect/exec:
#     Privilege Containment (PC-*), Credential Scoping (CS-*), Network
#     Isolation (NI-*), seccomp hardening (PC-05), required CLIs.
#
# Usage:
#   # Fast path — adopt an existing running devcontainer:
#   CONTAINER=<name-or-id> bats test/devc.bats
#
#   # Full lifecycle — setup_file regenerates .devcontainer/ from the repo-root
#   # template (install.sh template), runs `devc up`, teardown removes it:
#   bats test/devc.bats
#
#   # Unit layer only (skip the build) — point CONTAINER at nothing:
#   CONTAINER=__none__ bats test/devc.bats
#
# Requires: bash, docker, jq, bats-core, the devcontainer CLI. Full lifecycle
# additionally needs the bot identity under ~/.bot (claude/oauth-token,
# gitconfig, gh, graphite, ssh). Generate the Claude token with `claude
# setup-token` and save it to ~/.bot/claude/oauth-token.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
INITIALIZE="$REPO_ROOT/scripts/initialize.sh"
PROTECT_PATHS="$REPO_ROOT/usr/local/sbin/protect-paths"
PROTECT_EGRESS="$REPO_ROOT/usr/local/sbin/protect-egress"

# Save real PATH/HOME before per-test setup() swaps them for stubs.
REAL_PATH="$PATH"
REAL_HOME="$HOME"

# install.sh shells out to jq, which on this host lives outside /usr/bin
# (mise/homebrew). Keep its directory reachable from the stubbed PATH.
JQ_DIR="$(cd "$(dirname "$(command -v jq)")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

create_stub() {
  local name="$1" exit_code="${2:-0}" stdout="${3:-}"
  cat > "$BATS_TEST_TMPDIR/stubs/$name" <<STUB
#!/bin/sh
echo "\$@" >> "$BATS_TEST_TMPDIR/calls/$name"
${stdout:+echo "$stdout"}
exit $exit_code
STUB
  chmod +x "$BATS_TEST_TMPDIR/stubs/$name"
}

stub_calls() {
  cat "$BATS_TEST_TMPDIR/calls/$1" 2>/dev/null || true
}

# Per-test setup: rebuild stub dir and point PATH/HOME at it. Integration
# tests call _integration_restore_env to swap back to real PATH/HOME.
setup() {
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BATS_TEST_TMPDIR/home/.claude"
  create_stub devcontainer 0 ""
  create_stub docker       0 ""
  export PATH="$BATS_TEST_TMPDIR/stubs:$JQ_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
  export HOME="$BATS_TEST_TMPDIR/home"
  # Seed the Claude OAuth token initialize.sh now gates on, so the happy-path
  # initialize.sh tests pass. The missing/empty token tests override it.
  mkdir -p "$HOME/.bot/claude"
  printf 'test-oauth-token' > "$HOME/.bot/claude/oauth-token"
}

# ===========================================================================
# install.sh — the `devc` host CLI (unit, stubbed; no container required)
# ===========================================================================

@test "devc up: runs 'devcontainer up --workspace-folder <ws>'" {
  local ws="$BATS_TEST_TMPDIR/ws"; mkdir -p "$ws"
  run bash "$INSTALL" up "$ws"
  [ "$status" -eq 0 ]
  [[ "$(stub_calls devcontainer)" == *"up --workspace-folder $ws"* ]]
}

@test "devc up: refuses when devcontainer.json adds SYS_ADMIN to runArgs" {
  local ws="$BATS_TEST_TMPDIR/ws"; mkdir -p "$ws/.devcontainer"
  cat > "$ws/.devcontainer/devcontainer.json" <<'JSON'
{ "runArgs": ["--cap-add", "SYS_ADMIN"] }
JSON
  run bash "$INSTALL" up "$ws"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SYS_ADMIN"* ]]
}

@test "devc up: proceeds when devcontainer.json has no SYS_ADMIN in runArgs" {
  local ws="$BATS_TEST_TMPDIR/ws"; mkdir -p "$ws/.devcontainer"
  cat > "$ws/.devcontainer/devcontainer.json" <<'JSON'
{ "runArgs": ["--add-host=host.docker.internal:host-gateway"] }
JSON
  run bash "$INSTALL" up "$ws"
  [ "$status" -eq 0 ]
  [[ "$(stub_calls devcontainer)" == *"up --workspace-folder $ws"* ]]
}

@test "devcontainer.json: bind-mounts the Claude OAuth token read-only" {
  grep -Eq '"source=\$\{localEnv:HOME\}/\.bot/claude/,target=/home/vscode/\.bot/claude/,type=bind,readonly"' \
    "$REPO_ROOT/devcontainer.json"
}

@test "Dockerfile: a /etc/profile.d snippet exports CLAUDE_CODE_OAUTH_TOKEN from the mounted token" {
  # The token reaches login shells / userEnvProbe (and thus `devc exec claude -p`)
  # via /etc/profile.d, not a ~/.bashrc export and not /etc/environment.
  grep -q '/etc/profile.d/claude-code-token.sh' "$REPO_ROOT/Dockerfile"
  grep -q 'CLAUDE_CODE_OAUTH_TOKEN' "$REPO_ROOT/Dockerfile"
  grep -q '\.bot/claude/oauth-token' "$REPO_ROOT/Dockerfile"
  # Guard against regressing to the interactive-only ~/.bashrc export.
  ! grep -q 'export CLAUDE_CODE_OAUTH_TOKEN' "$REPO_ROOT/scripts/post-create.sh"
}

@test "devc rebuild: adds --remove-existing-container, not --build-no-cache" {
  local ws="$BATS_TEST_TMPDIR/ws"; mkdir -p "$ws"
  run bash "$INSTALL" rebuild "$ws"
  [ "$status" -eq 0 ]
  local calls; calls="$(stub_calls devcontainer)"
  [[ "$calls" == *"up --workspace-folder $ws"* ]]
  [[ "$calls" == *"--remove-existing-container"* ]]
  [[ "$calls" != *"--build-no-cache"* ]]
}

@test "devc rebuild --no-cache: adds --build-no-cache" {
  local ws="$BATS_TEST_TMPDIR/ws"; mkdir -p "$ws"
  run bash "$INSTALL" rebuild --no-cache "$ws"
  [ "$status" -eq 0 ]
  local calls; calls="$(stub_calls devcontainer)"
  [[ "$calls" == *"--remove-existing-container"* ]]
  [[ "$calls" == *"--build-no-cache"* ]]
}

@test "devc down: warns when no container is running" {
  local ws="$BATS_TEST_TMPDIR/ws"; mkdir -p "$ws"
  run bash "$INSTALL" down "$ws"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No running devcontainer"* ]]
}

@test "devc down: stops the running container found by label" {
  local ws="$BATS_TEST_TMPDIR/ws"; mkdir -p "$ws"
  # Custom docker stub: report a container id for `ps`, log every call.
  cat > "$BATS_TEST_TMPDIR/stubs/docker" <<STUB
#!/bin/sh
echo "\$@" >> "$BATS_TEST_TMPDIR/calls/docker"
if [ "\$1" = "ps" ]; then echo deadbeef; fi
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/stubs/docker"
  run bash "$INSTALL" down "$ws"
  [ "$status" -eq 0 ]
  [[ "$(stub_calls docker)" == *"stop deadbeef"* ]]
}

@test "devc template: installs the repo-root template into <dir>/.devcontainer" {
  local dest="$BATS_TEST_TMPDIR/proj"; mkdir -p "$dest"
  run bash "$INSTALL" template "$dest"
  [ "$status" -eq 0 ]
  [ -f "$dest/.devcontainer/devcontainer.json" ]
  [ -f "$dest/.devcontainer/Dockerfile" ]
  [ -f "$dest/.devcontainer/protected-paths" ]
  [ -d "$dest/.devcontainer/config" ]
  [ -d "$dest/.devcontainer/etc" ]
  [ -d "$dest/.devcontainer/bin" ]
  [ -d "$dest/.devcontainer/scripts" ]
  [ -d "$dest/.devcontainer/usr" ]
  [ -f "$dest/.devcontainer/usr/local/sbin/protect-paths" ]
  [ -f "$dest/.devcontainer/etc/seccomp/hardened.json" ]
}

@test "devc exec: forwards the command to 'devcontainer exec'" {
  local ws="$BATS_TEST_TMPDIR/ws"; mkdir -p "$ws"; cd "$ws"
  run bash "$INSTALL" exec ls -la
  [ "$status" -eq 0 ]
  local calls; calls="$(stub_calls devcontainer)"
  [[ "$calls" == *"exec --workspace-folder"* ]]
  [[ "$calls" == *"ls -la"* ]]
}

@test "devc: unknown command exits non-zero and prints usage" {
  run bash "$INSTALL" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command"* ]]
  [[ "$output" == *"Usage:"* ]]
}

@test "devc: no arguments prints usage and exits non-zero" {
  run bash "$INSTALL"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

# ===========================================================================
# scripts/initialize.sh — host-side initializeCommand (unit, no container)
# ===========================================================================

@test "initialize.sh: exits non-zero when docker info fails" {
  cat > "$BATS_TEST_TMPDIR/stubs/docker" <<'STUB'
#!/bin/sh
[ "$1" = "info" ] && exit 1
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/stubs/docker"
  run bash "$INITIALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Docker"* ]] || [[ "$output" == *"docker"* ]]
}

@test "initialize.sh: succeeds and seeds host placeholders when docker info passes" {
  local ws="$BATS_TEST_TMPDIR/myproj"; mkdir -p "$ws"; cd "$ws"
  run bash "$INITIALIZE"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude.json" ]
  [ -f "$HOME/.config/graphite/aliases" ]
  [ -f "$HOME/.config/graphite/user_config" ]
}

@test "initialize.sh: seeds project settings.json with non-empty deny rules" {
  local ws="$BATS_TEST_TMPDIR/myproj"; mkdir -p "$ws"; cd "$ws"
  run bash "$INITIALIZE"
  [ "$status" -eq 0 ]
  local settings="$HOME/.claude/projects/-workspaces-myproj/settings.json"
  [ -f "$settings" ]
  run jq -e '.permissions.deny | length > 0' "$settings"
  [ "$status" -eq 0 ]
}

@test "initialize.sh: does NOT export keychain credentials into a .credentials.json file" {
  # The keychain-export path was removed; container auth now uses a long-lived
  # CLAUDE_CODE_OAUTH_TOKEN instead of the shared, rotating .credentials.json.
  local ws="$BATS_TEST_TMPDIR/myproj"; mkdir -p "$ws"; cd "$ws"
  run bash "$INITIALIZE"
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.claude/.credentials.json" ]
}

@test "initialize.sh: exits non-zero with a clear error when the OAuth token is missing" {
  rm -f "$HOME/.bot/claude/oauth-token"
  run bash "$INITIALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"OAuth token"* ]]
  [[ "$output" == *"setup-token"* ]]
}

@test "initialize.sh: exits non-zero when the OAuth token file is empty" {
  : > "$HOME/.bot/claude/oauth-token"
  run bash "$INITIALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"OAuth token"* ]]
}

# ===========================================================================
# usr/local/sbin/protect-paths — pattern parsing & exclusion (unit, no container)
# ===========================================================================
#
# protect-paths normally runs inside the devcontainer with CAP_SYS_ADMIN and
# bind-mounts /dev/null over each matched file. For unit tests we point the
# script at a fake workspace via PROTECT_PATHS_WORKSPACE and replace the mount
# call with a recorder via PROTECT_PATHS_MASK_HOOK. Both env vars are honored
# only by the script's testing seam — production behavior is unchanged.

# Build a fake workspace at $1, write its .devcontainer/protected-paths from
# $2, run the script, and record masked targets (relative to workspace root)
# into $BATS_TEST_TMPDIR/masked.
_pp_run() {
  local ws="$1" config="$2"
  mkdir -p "$ws/.devcontainer"
  printf '%s\n' "$config" > "$ws/.devcontainer/protected-paths"

  local rec="$BATS_TEST_TMPDIR/masked"
  : > "$rec"
  cat > "$BATS_TEST_TMPDIR/stubs/pp_record" <<HOOK
#!/bin/sh
echo "\${1#$ws/}" >> "$rec"
HOOK
  chmod +x "$BATS_TEST_TMPDIR/stubs/pp_record"

  PROTECT_PATHS_WORKSPACE="$ws" \
    PROTECT_PATHS_MASK_HOOK="$BATS_TEST_TMPDIR/stubs/pp_record" \
    bash "$PROTECT_PATHS"
}

@test "T-PP-01: <dir>/** masks every file under the directory" {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/server/secrets"
  echo real > "$ws/server/secrets/firebase.json"
  echo real > "$ws/server/secrets/brands.json"

  _pp_run "$ws" "server/secrets/**"

  grep -qx "server/secrets/firebase.json" "$BATS_TEST_TMPDIR/masked"
  grep -qx "server/secrets/brands.json"   "$BATS_TEST_TMPDIR/masked"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/masked")" -eq 2 ]
}

@test "T-PP-02: !**/<basename> exempts matching files from <dir>/** masking" {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/server/secrets" "$ws/temporal/secrets"
  echo real     > "$ws/server/secrets/firebase.json"
  echo template > "$ws/server/secrets/firebase.template.json"
  echo template > "$ws/server/secrets/brands.template.yaml"
  echo real     > "$ws/temporal/secrets/firebase.json"
  echo template > "$ws/temporal/secrets/firebase.template.json"

  _pp_run "$ws" "$(cat <<'CFG'
server/secrets/**
temporal/secrets/**
!**/*.template.*
CFG
)"

  grep -qx "server/secrets/firebase.json"   "$BATS_TEST_TMPDIR/masked"
  grep -qx "temporal/secrets/firebase.json" "$BATS_TEST_TMPDIR/masked"
  ! grep -q "\.template\." "$BATS_TEST_TMPDIR/masked"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/masked")" -eq 2 ]
}

@test "T-PP-03: !**/<basename> exempts matching files from **/<basename> masking" {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/apps/a" "$ws/apps/b"
  echo real     > "$ws/apps/a/.env"
  echo real     > "$ws/apps/b/.env"
  echo template > "$ws/apps/a/.env.template"
  # Note: `**/.env` matches the literal basename `.env` only, so .env.template
  # would not be picked up to begin with — but we exercise the negation path
  # with a basename that *would* match.
  echo real > "$ws/apps/a/keep.env"

  _pp_run "$ws" "$(cat <<'CFG'
**/.env
**/keep.env
!**/keep.env
CFG
)"

  grep -qx "apps/a/.env" "$BATS_TEST_TMPDIR/masked"
  grep -qx "apps/b/.env" "$BATS_TEST_TMPDIR/masked"
  ! grep -q "keep.env"   "$BATS_TEST_TMPDIR/masked"
}

@test "T-PP-04: !<dir>/** exempts an entire subtree" {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/server/secrets/sub" "$ws/server/secrets/keep"
  echo a > "$ws/server/secrets/firebase.json"
  echo b > "$ws/server/secrets/sub/inner.pem"
  echo c > "$ws/server/secrets/keep/fixture.json"

  _pp_run "$ws" "$(cat <<'CFG'
server/secrets/**
!server/secrets/keep/**
CFG
)"

  grep -qx "server/secrets/firebase.json"  "$BATS_TEST_TMPDIR/masked"
  grep -qx "server/secrets/sub/inner.pem"  "$BATS_TEST_TMPDIR/masked"
  ! grep -q "server/secrets/keep/" "$BATS_TEST_TMPDIR/masked"
}

@test "T-PP-05: !<exact-path> exempts exactly that file" {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/server/secrets"
  echo a > "$ws/server/secrets/a.json"
  echo b > "$ws/server/secrets/keep.json"

  _pp_run "$ws" "$(cat <<'CFG'
server/secrets/**
!server/secrets/keep.json
CFG
)"

  grep -qx "server/secrets/a.json"   "$BATS_TEST_TMPDIR/masked"
  ! grep -q "server/secrets/keep.json" "$BATS_TEST_TMPDIR/masked"
}

@test "T-PP-06: absolute or '..' exclusion patterns are refused" {
  # No include patterns ⇒ no mask attempts ⇒ no need for a mask hook; the
  # script's only job here is to emit refusal lines for the bad exclusions.
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$ws/.devcontainer"
  cat > "$ws/.devcontainer/protected-paths" <<'CFG'
!/etc/passwd
!../escape
CFG

  PROTECT_PATHS_WORKSPACE="$ws" run bash "$PROTECT_PATHS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing exclusion '/etc/passwd'"* ]]
  [[ "$output" == *"refusing exclusion '../escape'"* ]]
}

# ===========================================================================
# usr/local/sbin/protect-egress — host-gateway egress rules (unit, no container)
# ===========================================================================
#
# protect-egress normally runs inside the devcontainer with CAP_NET_ADMIN and
# programs iptables/ip6tables. For unit tests we stub both binaries (PATH-first
# from the stubs dir) to record their arguments, and feed a fixture /etc/hosts
# via PROTECT_EGRESS_HOSTS_FILE — a testing seam honored only here; production
# reads the real /etc/hosts.
#
# Regression guard: the host.docker.internal gateway is dual-stack in
# /etc/hosts (Docker's --add-host writes an IPv4 *and* an IPv6 entry). The old
# code resolved it with `getent hosts`, which returns only one family — when
# that was IPv6-only, no IPv4 ACCEPT rule was created, the app's IPv4 connection
# hit the terminal DROP, and the omlx/ollama API silently timed out.

# Run protect-egress against a fixture hosts file with iptables/ip6tables stubbed
# to record their invocations into $BATS_TEST_TMPDIR/calls/{iptables,ip6tables}.
_pe_run() {
  local hosts="$1"
  create_stub iptables  0 ""
  create_stub ip6tables 0 ""
  PROTECT_EGRESS_HOSTS_FILE="$hosts" bash "$PROTECT_EGRESS"
}

@test "T-PE-01: dual-stack gateway is allowed for BOTH IPv4 and IPv6" {
  local hosts="$BATS_TEST_TMPDIR/hosts"
  cat > "$hosts" <<'HOSTS'
127.0.0.1	localhost
192.168.65.254	host.docker.internal
fdc4:f303:9324::254	host.docker.internal
172.17.0.5	4c3a805811b0
HOSTS
  _pe_run "$hosts"
  # The IPv4 rule is the one the old getent-hosts code intermittently dropped.
  [[ "$(stub_calls iptables)"  == *"-A OUTPUT -d 192.168.65.254 -j ACCEPT"* ]]
  [[ "$(stub_calls ip6tables)" == *"-A OUTPUT -d fdc4:f303:9324::254 -j ACCEPT"* ]]
}

@test "T-PE-02: an IPv4-only gateway entry still yields an IPv4 ACCEPT" {
  # The exact failing scenario inverted: whatever family /etc/hosts advertises
  # for the gateway must get a rule — resolution must not be able to drop it.
  local hosts="$BATS_TEST_TMPDIR/hosts"
  printf '192.168.65.254\thost.docker.internal\n' > "$hosts"
  _pe_run "$hosts"
  [[ "$(stub_calls iptables)" == *"-A OUTPUT -d 192.168.65.254 -j ACCEPT"* ]]
}

@test "T-PE-03: gateway ACCEPT precedes the terminal DROP (not shadowed)" {
  local hosts="$BATS_TEST_TMPDIR/hosts"
  printf '192.168.65.254\thost.docker.internal\n' > "$hosts"
  _pe_run "$hosts"
  local calls accept_line drop_line
  calls="$(stub_calls iptables)"
  accept_line="$(grep -n -- "-A OUTPUT -d 192.168.65.254 -j ACCEPT" <<<"$calls" | head -1 | cut -d: -f1)"
  drop_line="$(grep -n -- "-A OUTPUT -j DROP" <<<"$calls" | head -1 | cut -d: -f1)"
  [ -n "$accept_line" ]
  [ -n "$drop_line" ]
  [ "$accept_line" -lt "$drop_line" ]
}

# ===========================================================================
# Integration lifecycle: adopt CONTAINER=... or regenerate template + devc up
# ===========================================================================

# Derive the in-container workspace path from the live container rather than
# hardcoding /workspaces/<basename>. devcontainer.json owns workspaceFolder and
# may point it at the absolute host path (${localWorkspaceFolder}), so the only
# reliable source of truth is the bind mount that targets the host workspace
# folder named by the devcontainer.local_folder label. On macOS the source can
# carry a /host_mnt prefix. Leaves the caller's preset DC_WORKSPACE untouched
# if anything can't be resolved.
_derive_dc_workspace() {
  [[ -z "$DC_CONTAINER_ID" ]] && return 0
  local host_folder dest
  host_folder=$(docker inspect "$DC_CONTAINER_ID" \
                  --format '{{ index .Config.Labels "devcontainer.local_folder" }}' \
                2>/dev/null)
  [[ -z "$host_folder" ]] && return 0
  dest=$(docker inspect "$DC_CONTAINER_ID" --format '{{json .Mounts}}' 2>/dev/null \
         | jq -r --arg h "$host_folder" \
             '.[] | select(.Source == $h or .Source == "/host_mnt" + $h) | .Destination' \
         | head -1)
  [[ -n "$dest" ]] && export DC_WORKSPACE="$dest"
  return 0
}

setup_file() {
  export INTEGRATION_SKIP_REASON=""
  export DC_CONTAINER_ID=""
  export DC_ENV_FIXTURE_CREATED=0
  export OWN_CONTAINER=0
  export DC_WORKSPACE="/workspaces/$(basename "$REPO_ROOT")"

  local install="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/install.sh"
  local repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  if ! docker info &>/dev/null; then
    INTEGRATION_SKIP_REASON="Docker is not running"
    return 0
  fi

  # Fast path: adopt an existing container named or id'd by $CONTAINER.
  if [[ -n "${CONTAINER:-}" ]]; then
    local id
    id=$(docker ps --filter "name=^${CONTAINER}$" --format '{{.ID}}' | head -1)
    [[ -z "$id" ]] && id=$(docker ps --filter "id=${CONTAINER}" --format '{{.ID}}' | head -1)
    if [[ -z "$id" ]]; then
      INTEGRATION_SKIP_REASON="CONTAINER='$CONTAINER' not found in running containers"
      return 0
    fi
    DC_CONTAINER_ID="$id"
    _derive_dc_workspace
    return 0
  fi

  # Full lifecycle needs the devcontainer CLI and the bot-identity Claude token.
  if ! command -v devcontainer &>/dev/null; then
    INTEGRATION_SKIP_REASON="devcontainer CLI not installed on host"
    return 0
  fi
  if [[ ! -s "$REAL_HOME/.bot/claude/oauth-token" ]]; then
    INTEGRATION_SKIP_REASON="Claude OAuth token missing at ~/.bot/claude/oauth-token (run: claude setup-token)"
    return 0
  fi

  # Seed a .env fixture so the protected-paths masking tests have a target.
  if [[ ! -f "$repo_root/.env" ]]; then
    echo "SECRET=super-secret-value" > "$repo_root/.env"
    DC_ENV_FIXTURE_CREATED=1
  fi

  # Regenerate .devcontainer/ from the repo-root template. The directory is
  # gitignored / generated; remove any stale copy first so `devc template`
  # does not hit its interactive overwrite prompt (a non-interactive read
  # would abort the copy).
  rm -rf "$repo_root/.devcontainer"
  if ! bash "$install" template "$repo_root" >/dev/null 2>&1; then
    INTEGRATION_SKIP_REASON="install.sh template failed during setup_file"
    return 0
  fi

  if ! bash "$install" up "$repo_root" >/dev/null 2>&1; then
    INTEGRATION_SKIP_REASON="devc up failed during setup_file"
    return 0
  fi

  OWN_CONTAINER=1
  DC_CONTAINER_ID=$(docker ps \
    --filter "label=devcontainer.local_folder=$repo_root" \
    --format '{{.ID}}' | head -1)
  if [[ -z "$DC_CONTAINER_ID" ]]; then
    INTEGRATION_SKIP_REASON="devc up completed but no container matches workspace label"
  else
    _derive_dc_workspace
  fi
  return 0
}

teardown_file() {
  [[ -n "$INTEGRATION_SKIP_REASON" ]] && return 0
  local repo_root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  [[ "${DC_ENV_FIXTURE_CREATED:-0}" -eq 1 ]] && rm -f "$repo_root/.env"
  if [[ "${OWN_CONTAINER:-0}" -eq 1 ]]; then
    while IFS= read -r cid; do
      [[ -n "$cid" ]] && docker rm -f "$cid" &>/dev/null || true
    done < <(docker ps -a --filter "label=devcontainer.local_folder=$repo_root" \
               --format '{{.ID}}')
  fi
}

_integration_restore_env() {
  [[ -n "$INTEGRATION_SKIP_REASON" ]] && skip "$INTEGRATION_SKIP_REASON"
  export PATH="$REAL_PATH"
  export HOME="$REAL_HOME"
}

dc_exec() {
  docker exec "$DC_CONTAINER_ID" "$@"
}

dc_exec_root() {
  docker exec -u 0 "$DC_CONTAINER_ID" "$@"
}

# Extract the inlined seccomp JSON from the running container's HostConfig.
dc_live_seccomp_json() {
  docker inspect "$DC_CONTAINER_ID" \
    --format '{{range .HostConfig.SecurityOpt}}{{println .}}{{end}}' \
    | sed -n 's/^seccomp=//p' | head -1
}

# ===========================================================================
# Container lifecycle
# ===========================================================================

@test "lifecycle: container is running" {
  _integration_restore_env
  [ -n "$DC_CONTAINER_ID" ]
  run docker inspect --format '{{.State.Running}}' "$DC_CONTAINER_ID"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# ===========================================================================
# Privilege Containment (PC-01 .. PC-04)
# ===========================================================================

@test "PC-01: default user inside container is vscode" {
  _integration_restore_env
  run dc_exec whoami
  [ "$status" -eq 0 ]
  [ "$output" = "vscode" ]
}

@test "PC-02: vscode cannot run sudo iptables" {
  _integration_restore_env
  run dc_exec sudo -n iptables -L
  [ "$status" -ne 0 ]
}

@test "PC-03: HostConfig.CapAdd is exactly NET_ADMIN, SYS_ADMIN" {
  _integration_restore_env
  local caps
  caps=$(docker inspect "$DC_CONTAINER_ID" \
          --format '{{json .HostConfig.CapAdd}}' \
         | jq -r 'map(sub("^CAP_"; "")) | sort | join(",")')
  [ "$caps" = "NET_ADMIN,SYS_ADMIN" ]
}

@test "PC-03: sudoers allows exactly the three pinned launchers (no bare squid)" {
  _integration_restore_env
  local out
  out=$(dc_exec sudo -n -l)
  [[ "$out" == *"/usr/local/sbin/start-squid"* ]]
  [[ "$out" == *"/usr/local/sbin/protect-egress"* ]]
  [[ "$out" == *"/usr/local/sbin/protect-paths"* ]]
  [[ "$out" != *"/usr/sbin/squid"* ]]
  [[ "$out" != *"iptables"* ]]
  [[ "$out" != *"/bin/mount"* ]]
}

@test "PC-04: .env in the workspace is masked (empty) inside the container" {
  _integration_restore_env
  run dc_exec bash -c "wc -c < ${DC_WORKSPACE}/.env"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[[:space:]]*0[[:space:]]*$ ]]
}

@test "PC-04: every .env on the host is masked inside the container" {
  _integration_restore_env
  # Enumerate from the host where the files are still regular files (after
  # masking, the targets show up as character-special, which would skip a
  # `find -type f` walk inside the container). Use the same prune list as
  # protect-paths so we only assert masking for files the script targets.
  local -a targets=()
  while IFS= read -r f; do
    targets+=("${f#$REPO_ROOT/}")
  done < <(find "$REPO_ROOT" \
             \( -name node_modules -o -name .git -o -name .tsc-build \
                -o -name dist -o -name build -o -name .next -o -name .yarn \) \
             -prune \
             -o -type f -name .env -print)
  # setup_file ensures at least one .env (root fixture) exists.
  [ "${#targets[@]}" -ge 1 ]
  for rel in "${targets[@]}"; do
    run dc_exec bash -c "wc -c < ${DC_WORKSPACE}/$rel"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[[:space:]]*0[[:space:]]*$ ]] \
      || { echo "expected ${DC_WORKSPACE}/$rel masked, got: '$output'"; return 1; }
  done
}

# ===========================================================================
# Privilege Containment — seccomp hardening (PC-05)
# ===========================================================================

@test "PC-05: seccomp is in filter mode for pid 1 inside the container" {
  _integration_restore_env
  run dc_exec awk '/^Seccomp:/{print $2}' /proc/1/status
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "PC-05: applied profile identifies as our hardened fork (_comment marker)" {
  _integration_restore_env
  local json; json=$(dc_live_seccomp_json)
  [ -n "$json" ]
  run jq -e '[.. | objects | ._comment? // empty | select(contains("HARDENED"))] | length >= 1' <<<"$json"
  [ "$status" -eq 0 ]
}

@test "PC-05: applied CAP_SYS_ADMIN allow-list contains only 'mount'" {
  _integration_restore_env
  local json names
  json=$(dc_live_seccomp_json)
  names=$(jq -r '
    [.syscalls[]
      | select(.action == "SCMP_ACT_ALLOW"
               and (.includes.caps // []) == ["CAP_SYS_ADMIN"])]
    | map(.names) | add | sort | join(",")
  ' <<<"$json")
  [ "$names" = "mount" ]
}

@test "PC-05: applied profile has no SYS_ADMIN allow rule for dangerous syscalls" {
  _integration_restore_env
  local json; json=$(dc_live_seccomp_json)
  local blocked=(unshare setns pivot_root bpf perf_event_open umount umount2 \
                 move_mount open_tree fsopen fsconfig fsmount fspick \
                 keyctl add_key request_key mount_setattr syslog)
  for sc in "${blocked[@]}"; do
    local count
    count=$(jq --arg sc "$sc" '
      [.syscalls[]
        | select(.action == "SCMP_ACT_ALLOW"
                 and (.includes.caps // []) == ["CAP_SYS_ADMIN"]
                 and (.names | index($sc)))]
      | length' <<<"$json")
    [ "$count" -eq 0 ] || { echo "FAIL: $sc is SYS_ADMIN-ALLOWed" >&2; return 1; }
  done
}

@test "PC-05: applied profile returns ENOSYS for clone3 with no SYS_ADMIN carve-out" {
  _integration_restore_env
  local json; json=$(dc_live_seccomp_json)
  run jq -e '
    [.syscalls[]
      | select(.action == "SCMP_ACT_ERRNO"
               and .errnoRet == 38
               and (.names | index("clone3"))
               and (.excludes // {} | has("caps") | not))]
    | length >= 1' <<<"$json"
  [ "$status" -eq 0 ]
}

@test "PC-05: unshare --user is blocked" {
  _integration_restore_env
  run dc_exec unshare --user true
  [ "$status" -ne 0 ]
}

@test "PC-05: unshare --mount is blocked even as root (seccomp inherits)" {
  _integration_restore_env
  # sudoers does not allow arbitrary commands; reach root via docker exec -u 0
  # to confirm seccomp still blocks namespace creation regardless of caps.
  run dc_exec_root unshare --mount true
  [ "$status" -ne 0 ]
}

@test "PC-05: umount2 is blocked (bind a file, try to unmount)" {
  _integration_restore_env
  run dc_exec_root bash -c '
    set -e
    f=$(mktemp) && mount --bind /dev/null "$f"
    if umount "$f" 2>/dev/null; then echo UMOUNT_ALLOWED; exit 0; fi
    echo UMOUNT_BLOCKED'
  [ "$status" -eq 0 ]
  [[ "$output" == *"UMOUNT_BLOCKED"* ]]
}

@test "PC-05: mount --bind is still allowed (the one SYS_ADMIN unlock we keep)" {
  _integration_restore_env
  run dc_exec_root bash -c '
    set -e
    f=$(mktemp) && echo hello > "$f"
    mount --bind /dev/null "$f"
    contents=$(cat "$f")
    [ -z "$contents" ] && echo MOUNT_WORKS'
  [ "$status" -eq 0 ]
  [[ "$output" == *"MOUNT_WORKS"* ]]
}

@test "PC-05: fork/clone still works (CLONE_NEW* masked, plain fork permitted)" {
  _integration_restore_env
  run dc_exec bash -c "echo hello | cat | (read x; echo \$x)"
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

# ===========================================================================
# Credential Scoping (CS-01 .. CS-06)
# ===========================================================================

@test "CS-01: the OAuth token is bind-mounted read-only into the container" {
  _integration_restore_env
  run dc_exec test -f /home/vscode/.bot/claude/oauth-token
  [ "$status" -eq 0 ]
  run dc_exec bash -c "mount | grep ' on /home/vscode/.bot/claude ' | grep -qE '[(,]ro[,)]'"
  [ "$status" -eq 0 ]
}

@test "CS-01: the /etc/profile.d token snippet exists in the container" {
  _integration_restore_env
  run dc_exec test -f /etc/profile.d/claude-code-token.sh
  [ "$status" -eq 0 ]
}

@test "CS-01: a login shell exports CLAUDE_CODE_OAUTH_TOKEN matching the mounted token" {
  # A login shell (as `devc shell` uses, and as userEnvProbe captures) sources
  # /etc/profile.d. A raw non-interactive `docker exec` would NOT — that path is
  # intentionally not covered by this file-based mechanism.
  _integration_restore_env
  local from_env from_file
  from_env="$(dc_exec bash -lc 'printf "%s" "$CLAUDE_CODE_OAUTH_TOKEN"' 2>/dev/null)"
  from_file="$(dc_exec cat /home/vscode/.bot/claude/oauth-token)"
  [ -n "$from_env" ]
  [ "$from_env" = "$from_file" ]
}

@test "CS-01: the OAuth token is NOT exported via ~/.bashrc (system profile.d, not per-user rc)" {
  _integration_restore_env
  run dc_exec bash -c 'grep -q "export CLAUDE_CODE_OAUTH_TOKEN" ~/.bashrc'
  [ "$status" -ne 0 ]
}

@test "CS-04: the shared agents config is bind-mounted into the container" {
  _integration_restore_env
  run dc_exec test -d /home/vscode/.agents
  [ "$status" -eq 0 ]
}

@test "CS-04: the Codex config is bind-mounted into the container" {
  _integration_restore_env
  run dc_exec test -d /home/vscode/.codex
  [ "$status" -eq 0 ]
}

@test "CS-04: .gitconfig (bot identity) is bind-mounted into the container" {
  _integration_restore_env
  run dc_exec test -f /home/vscode/.gitconfig
  [ "$status" -eq 0 ]
  run dc_exec bash -c 'mount | grep -c " on /home/vscode/.gitconfig "'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "CS-04: SSH config (bot identity) is bind-mounted into the container" {
  _integration_restore_env
  run dc_exec test -d /home/vscode/.ssh
  [ "$status" -eq 0 ]
}

@test "CS-04: gh config (bot identity) is bind-mounted into the container" {
  _integration_restore_env
  run dc_exec test -d /home/vscode/.config/gh
  [ "$status" -eq 0 ]
}

@test "CS-04: Graphite config files are readable inside the container" {
  _integration_restore_env
  if dc_exec test -f /home/vscode/.config/graphite/aliases; then
    run dc_exec test -r /home/vscode/.config/graphite/aliases
    [ "$status" -eq 0 ]
  fi
  if dc_exec test -f /home/vscode/.config/graphite/user_config; then
    run dc_exec test -r /home/vscode/.config/graphite/user_config
    [ "$status" -eq 0 ]
  fi
}

@test "CS-05: host paths outside repo/mounts are inaccessible from container" {
  _integration_restore_env
  # When the workspace mounts at its absolute host path (${localWorkspaceFolder}),
  # the container auto-creates the *empty* ancestor dirs of the mount point
  # (/Users, /Users/<user>, ...). Their mere existence is not a leak — only real
  # host *content* would be. Assert each ancestor between / and the workspace
  # holds nothing but the single child on the path to the workspace, so no
  # sibling host entries (other users, other repos) are visible inside.
  local -a parts
  IFS='/' read -r -a parts <<<"${DC_WORKSPACE#/}"
  local n=${#parts[@]} k dir expected
  [ "$n" -ge 2 ]
  for (( k=0; k<n-1; k++ )); do
    dir="/$(IFS=/; echo "${parts[*]:0:k+1}")"
    expected="${parts[k+1]}"
    run dc_exec ls -A "$dir"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ] \
      || { echo "ancestor $dir leaked host entries: '$output' (expected only '$expected')"; return 1; }
  done
}

@test "CS-03: docker socket is not present inside the container" {
  _integration_restore_env
  run dc_exec test -e /var/run/docker.sock
  [ "$status" -ne 0 ]
}

@test "CS-06: Claude project settings file contains non-empty deny rules" {
  _integration_restore_env
  run dc_exec bash -c "
    s=/home/vscode/.claude/projects/-workspaces-$(basename ${DC_WORKSPACE})/settings.json
    [ -f \"\$s\" ] && jq -e '.permissions.deny | length > 0' \"\$s\""
  [ "$status" -eq 0 ]
}

# ===========================================================================
# Network Isolation (NI-01 .. NI-04)
# ===========================================================================

@test "NI-01: curl to a non-allowlisted domain is blocked" {
  _integration_restore_env
  run dc_exec curl --max-time 10 --silent --fail https://example.com
  [ "$status" -ne 0 ]
}

@test "NI-02: HTTPS to allowlisted api.anthropic.com via proxy completes a TLS round-trip" {
  _integration_restore_env
  run dc_exec curl --max-time 15 --silent -o /dev/null -w "%{http_code}" https://api.anthropic.com
  [ "$status" -eq 0 ]
  [[ "$output" != "000" ]]
}

@test "NI-02: HTTPS to allowlisted chatgpt.com via proxy completes a TLS round-trip" {
  # codex's built-in codex_apps MCP handshakes with chatgpt.com on startup;
  # .chatgpt.com is allowlisted so the proxy permits it. A real HTTP status
  # (not 000) proves squid completed the CONNECT and TLS round-trip — the
  # status itself may be 403/405 from ChatGPT, which is fine here.
  _integration_restore_env
  run dc_exec curl --max-time 15 --silent -o /dev/null -w "%{http_code}" https://chatgpt.com
  [ "$status" -eq 0 ]
  [[ "$output" != "000" ]]
}

@test "NI-03: direct curl bypassing the proxy is blocked by iptables" {
  _integration_restore_env
  run dc_exec curl --noproxy "*" --max-time 5 --silent --fail https://example.com
  [ "$status" -ne 0 ]
}

@test "NI-04: squid resolves DNS for proxied hostnames" {
  # Egress is UID-gated: only the proxy user can reach the net, so direct
  # `getent hosts` from vscode cannot talk to external DNS. The load-bearing
  # requirement is that squid resolves DNS per-request — verified by asking
  # the proxy to reach a hostname (not a literal IP) and confirming it did
  # not return a DNS-failure surrogate status.
  _integration_restore_env
  run dc_exec curl --max-time 15 --silent -o /dev/null \
    -w "%{http_code}\n%{remote_ip}\n" https://api.anthropic.com
  [ "$status" -eq 0 ]
  local http_code remote_ip
  http_code="$(printf '%s\n' "$output" | sed -n '1p')"
  remote_ip="$(printf '%s\n' "$output" | sed -n '2p')"
  [[ "$http_code" != "000" ]]
  [ -n "$remote_ip" ]
}

# ===========================================================================
# Required tooling & shell environment
# ===========================================================================

@test "tooling: claude --version succeeds inside the container" {
  # Claude installs a symlink in ~/.local/bin, which is only added to PATH
  # by the default Ubuntu ~/.profile on login. Use a login shell to match
  # the environment an interactive user (or `devcontainer exec bash`) gets.
  _integration_restore_env
  run dc_exec bash -lc 'claude --version'
  [ "$status" -eq 0 ]
}

@test "tooling: gt --version succeeds inside the container" {
  _integration_restore_env
  run dc_exec gt --version
  [ "$status" -eq 0 ]
}

@test "tooling: gh --version succeeds inside the container" {
  _integration_restore_env
  run dc_exec gh --version
  [ "$status" -eq 0 ]
}

@test "tooling: codex --version succeeds inside the container" {
  _integration_restore_env
  run dc_exec codex --version
  [ "$status" -eq 0 ]
}

@test "shell env: omlx/ollama/yolo launcher functions are written to ~/.bashrc" {
  _integration_restore_env
  run dc_exec bash -c 'grep -q "yolo()" ~/.bashrc \
    && grep -q "omlx()" ~/.bashrc \
    && grep -q "ollama()" ~/.bashrc'
  [ "$status" -eq 0 ]
}

# ===========================================================================
# scripts/post-create.sh — omlx() per-tier model resolution (unit, no container)
# ===========================================================================
#
# The omlx() launcher is defined as literal text inside a heredoc in
# post-create.sh. We extract just that function with sed (range from the
# `omlx() {` opener to its column-0 closing brace), source it, and replace the
# `claude` binary with a stub that dumps its environment. Asserting on that env
# dump verifies which ANTHROPIC_DEFAULT_*_MODEL / CLAUDE_CODE_SUBAGENT_MODEL
# values each combination of MLX_*_MODEL vars resolves to — without a
# container, a real claude, or post-create's git side effects.

POST_CREATE="$REPO_ROOT/scripts/post-create.sh"

# Extract omlx() to a sourceable file and install a claude stub that prints its
# environment to stdout. The stub uses `env` so every VAR=val the function
# passes through `env "${_env[@]}" claude` is observable.
_load_omlx() {
  sed -n '/^omlx() {/,/^}/p' "$POST_CREATE" > "$BATS_TEST_TMPDIR/omlx.sh"
  printf '#!/bin/sh\nenv\n' > "$BATS_TEST_TMPDIR/stubs/claude"
  chmod +x "$BATS_TEST_TMPDIR/stubs/claude"
}

# Run omlx() with the given VAR=val assignments exported into its environment,
# capturing the stub's env dump in $output. TERM=dumb keeps the function's
# `clear` quiet; </dev/null guards against any read. The leading -u flags clear
# any MLX_*/model-slot vars inherited from the test runner's own shell (the
# host may itself export MLX_MODEL etc.) so each test fully controls its inputs.
_run_omlx() {
  run env \
    -u MLX_MODEL -u MLX_OPUS_MODEL -u MLX_SONNET_MODEL -u MLX_HAIKU_MODEL \
    -u MLX_CONTEXT_WINDOW \
    -u ANTHROPIC_DEFAULT_OPUS_MODEL -u ANTHROPIC_DEFAULT_SONNET_MODEL \
    -u ANTHROPIC_DEFAULT_HAIKU_MODEL -u CLAUDE_CODE_SUBAGENT_MODEL \
    TERM=dumb "$@" bash -c \
    'source "'"$BATS_TEST_TMPDIR"'/omlx.sh"; omlx </dev/null'
}

@test "omlx: per-tier vars drive their own ANTHROPIC_DEFAULT_*_MODEL slots" {
  _load_omlx
  _run_omlx MLX_MODEL=base \
            MLX_OPUS_MODEL=opus-x \
            MLX_SONNET_MODEL=sonnet-y \
            MLX_HAIKU_MODEL=haiku-z
  [ "$status" -eq 0 ]
  [[ "$output" == *"ANTHROPIC_DEFAULT_OPUS_MODEL=opus-x"* ]]
  [[ "$output" == *"ANTHROPIC_DEFAULT_SONNET_MODEL=sonnet-y"* ]]
  [[ "$output" == *"ANTHROPIC_DEFAULT_HAIKU_MODEL=haiku-z"* ]]
  # Subagents follow the sonnet/workhorse tier.
  [[ "$output" == *"CLAUDE_CODE_SUBAGENT_MODEL=sonnet-y"* ]]
}

@test "omlx: unset per-tier vars fall back to MLX_MODEL on every slot" {
  _load_omlx
  _run_omlx MLX_MODEL=base
  [ "$status" -eq 0 ]
  [[ "$output" == *"ANTHROPIC_DEFAULT_OPUS_MODEL=base"* ]]
  [[ "$output" == *"ANTHROPIC_DEFAULT_SONNET_MODEL=base"* ]]
  [[ "$output" == *"ANTHROPIC_DEFAULT_HAIKU_MODEL=base"* ]]
  [[ "$output" == *"CLAUDE_CODE_SUBAGENT_MODEL=base"* ]]
}

@test "omlx: a per-tier var overrides MLX_MODEL only for its own slot" {
  _load_omlx
  _run_omlx MLX_MODEL=base MLX_OPUS_MODEL=opus-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"ANTHROPIC_DEFAULT_OPUS_MODEL=opus-x"* ]]
  [[ "$output" == *"ANTHROPIC_DEFAULT_SONNET_MODEL=base"* ]]
  [[ "$output" == *"ANTHROPIC_DEFAULT_HAIKU_MODEL=base"* ]]
}

@test "omlx: an empty (forwarded-but-unset) per-tier var falls back, not blanks" {
  # devcontainer.json forwards ${localEnv:MLX_OPUS_MODEL} as "" when the host
  # var is unset; ':-' must treat empty as absent so the slot is not blanked.
  _load_omlx
  _run_omlx MLX_MODEL=base MLX_OPUS_MODEL=
  [ "$status" -eq 0 ]
  [[ "$output" == *"ANTHROPIC_DEFAULT_OPUS_MODEL=base"* ]]
}

@test "omlx: with no model vars set, no model slots are emitted" {
  _load_omlx
  _run_omlx
  [ "$status" -eq 0 ]
  [[ "$output" != *"ANTHROPIC_DEFAULT_OPUS_MODEL="* ]]
  [[ "$output" != *"ANTHROPIC_DEFAULT_SONNET_MODEL="* ]]
  [[ "$output" != *"ANTHROPIC_DEFAULT_HAIKU_MODEL="* ]]
  [[ "$output" != *"CLAUDE_CODE_SUBAGENT_MODEL="* ]]
}

# ===========================================================================
# config/git/config — git insteadOf rewrite for egress-locked submit (unit)
# ===========================================================================
#
# Egress is locked to the squid proxy: port 22 / direct DNS are blocked, so all
# git traffic must traverse https through the proxy. The baked XDG git config
# (config/git/config, copied by the Dockerfile to ~/.config/git/config) rewrites
# both the scp-shorthand form (git@github.com:owner/repo) that real remotes use
# and the URL form (ssh://git@github.com/) via url.<https>.insteadOf. Without it,
# `git fetch`/`push` and therefore `gt submit` fall through to real SSH and fail.
#
# These tests stage the repo's *actual* config/git/config at $HOME/.config/git/
# in an isolated HOME (copied verbatim, so the test can't drift from the source),
# then assert `git ls-remote --get-url` — which expands url.insteadOf and exits
# without touching the network — produces the rewritten https URL.

GIT_CONFIG_BAKED="$REPO_ROOT/config/git/config"

# Stage config/git/config at the container's runtime path inside an isolated
# HOME. Must be called directly (not in a command substitution) so its
# `export HOME` reaches the test shell.
_stage_baked_gitconfig() {
  export HOME="$BATS_TEST_TMPDIR/githome"
  # Pin XDG_CONFIG_HOME under the isolated HOME. Without this, a host that
  # exports XDG_CONFIG_HOME makes git read its global config from there,
  # bypassing the staged baked config entirely.
  export XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$HOME/.config/git"
  cp "$GIT_CONFIG_BAKED" "$HOME/.config/git/config"
}

@test "baked gitconfig: scp-shorthand github remote rewrites to https" {
  _stage_baked_gitconfig
  cd "$BATS_TEST_TMPDIR"
  git init -q rewrite-scp && cd rewrite-scp
  git remote add origin git@github.com:owner/name.git
  # --get-url expands url.insteadOf and exits without network access.
  run git ls-remote --get-url origin
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/owner/name.git" ]
}

@test "baked gitconfig: ssh-url-form github remote also rewrites to https" {
  # config/git/config carries the URL-form rule itself (RUS-65), so it no longer
  # depends on the host bot ~/.gitconfig bind mount. Assert the baked config
  # alone rewrites the ssh:// URL form to https.
  _stage_baked_gitconfig
  cd "$BATS_TEST_TMPDIR"
  git init -q rewrite-url && cd rewrite-url
  git remote add origin ssh://git@github.com/owner/name.git
  run git ls-remote --get-url origin
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/owner/name.git" ]
}

@test "baked gitconfig: scp-shorthand for non-github host is left untouched" {
  # The rewrite must be host-specific: a gitlab scp remote must NOT be rerouted
  # through the github https base.
  _stage_baked_gitconfig
  cd "$BATS_TEST_TMPDIR"
  git init -q rewrite-other && cd rewrite-other
  git remote add origin git@gitlab.com:owner/name.git
  run git ls-remote --get-url origin
  [ "$status" -eq 0 ]
  [ "$output" = "git@gitlab.com:owner/name.git" ]
}

# ===========================================================================
# config/git/ignore — global excludes at the XDG default path (unit, no container)
# ===========================================================================
#
# The Dockerfile copies config/ -> /home/vscode/.config, so config/git/ignore
# lands at ~/.config/git/ignore — git's XDG-default core.excludesFile (neither
# the baked config/git/config nor the bot ~/.gitconfig sets core.excludesFile,
# so git falls back to this path automatically). These tests reproduce that
# mechanism hermetically: stage the repo's config/git/ignore at
# $HOME/.config/git/ignore in an isolated HOME, then assert `git check-ignore`
# matches the intended patterns via the global excludes alone.
#
# GIT_CONFIG_NOSYSTEM=1 + an empty XDG_CONFIG_HOME-free HOME guarantee the only
# excludesFile in play is the staged copy, so a host /etc system gitconfig can't
# mask the XDG default and silently pass/fail the test.

GIT_IGNORE="$REPO_ROOT/config/git/ignore"

# Stage config/git/ignore at the container's runtime path inside an isolated
# HOME and init a repo at $GLOBAL_IGNORE_REPO. Must be called directly (not in
# a command substitution) so its `export HOME` reaches the test shell.
_stage_global_ignore() {
  export HOME="$BATS_TEST_TMPDIR/gitignhome"
  mkdir -p "$HOME/.config/git"
  cp "$GIT_IGNORE" "$HOME/.config/git/ignore"
  export GLOBAL_IGNORE_REPO="$HOME/repo"
  git init -q "$GLOBAL_IGNORE_REPO"
}

# git check-ignore against the staged global excludes only (no system config).
_check_ignore() {
  env -u XDG_CONFIG_HOME GIT_CONFIG_NOSYSTEM=1 \
    git -C "$GLOBAL_IGNORE_REPO" check-ignore -q -- "$1"
}

@test "global ignore: TODO.md is ignored via the XDG-default excludes file" {
  _stage_global_ignore
  run _check_ignore "TODO.md"
  [ "$status" -eq 0 ]
}

@test "global ignore: nested .claude/settings.local.json is ignored" {
  _stage_global_ignore
  run _check_ignore "sub/dir/.claude/settings.local.json"
  [ "$status" -eq 0 ]
}

@test "global ignore: workflow patterns (.env, *.swp, .worktrees) all match" {
  _stage_global_ignore
  for p in .env app/.env config.swp .worktrees/feature NOTE.txt .direnv; do
    run _check_ignore "$p"
    [ "$status" -eq 0 ] || { echo "expected '$p' ignored"; return 1; }
  done
}

@test "global ignore: a normal tracked file is NOT ignored" {
  _stage_global_ignore
  run _check_ignore "README.md"
  [ "$status" -ne 0 ]
}

@test "global ignore: macOS-only junk (.DS_Store) is NOT carried into the container excludes" {
  # The container file deliberately drops the host's macOS section; assert it
  # stayed dropped so the file's scope doesn't silently regrow.
  _stage_global_ignore
  run _check_ignore ".DS_Store"
  [ "$status" -ne 0 ]
}

# ===========================================================================
# scripts/post-start.sh — gh registered as git credential helper (static)
# ===========================================================================
#
# `gh auth login --with-token` stores the token but, unlike gh's interactive
# flow, does NOT run setup-git — so https git pushes (and `gt submit`) would
# have no credential helper and fail under the egress guard (RUS-65). post-start
# must therefore call `gh auth setup-git`, and it must come AFTER `gh auth login`
# (setup-git writes a helper for the logged-in account; ordering it before login
# would configure nothing). This can't run hermetically (needs gh + network +
# root), so we assert the source carries the call in the correct order — guarding
# against someone dropping or reordering the line.

POST_START="$REPO_ROOT/scripts/post-start.sh"

@test "post-start: runs gh auth setup-git after gh auth login" {
  grep -q 'gh auth setup-git' "$POST_START"
  local login_line setup_line
  login_line="$(grep -n 'gh auth login' "$POST_START" | head -n1 | cut -d: -f1)"
  setup_line="$(grep -n 'gh auth setup-git' "$POST_START" | head -n1 | cut -d: -f1)"
  [ -n "$login_line" ]
  [ -n "$setup_line" ]
  [ "$setup_line" -gt "$login_line" ]
}
