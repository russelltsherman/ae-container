#!/usr/bin/env bats
# test/devc.bats — consolidated devcontainer test suite.
#
# The repository is a devcontainer *template*: the canonical sources live at
# the repo root (config/, etc/, bin/, Dockerfile, devcontainer.json,
# protected-paths) and install.sh's `devc template` copies them into a target
# project's .devcontainer/ (which is gitignored / generated).
#
# Layers (mirrors the host-side / in-container split):
#
#   UNIT (no container, stubbed) — target the repo-root sources:
#     - install.sh            the `devc` host CLI (up/rebuild/down/template/...)
#     - config/initialize.sh  host-side initializeCommand: docker probe, macOS
#                             keychain export, project settings seeding,
#                             mount-source placeholder creation
#     - config/protect-paths  protected-paths pattern parser / exclusions
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
# additionally needs the macOS keychain entry "Claude Code-credentials" and the
# bot identity under ~/.bot (gitconfig, gh, graphite, ssh).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
INITIALIZE="$REPO_ROOT/config/initialize.sh"
PROTECT_PATHS="$REPO_ROOT/config/protect-paths"

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
  create_stub security     0 '{"token":"test-token"}'
  export PATH="$BATS_TEST_TMPDIR/stubs:$JQ_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
  export HOME="$BATS_TEST_TMPDIR/home"
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
  [ -f "$dest/.devcontainer/config/protect-paths" ]
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
# config/initialize.sh — host-side initializeCommand (unit, no container)
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

@test "initialize.sh: macOS keychain export writes credentials with 0600 perms" {
  [ "$(uname)" = "Darwin" ] || skip "macOS keychain export only runs on Darwin"
  run bash "$INITIALIZE"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/.credentials.json" ]
  local perms; perms="$(/usr/bin/stat -f '%Lp' "$HOME/.claude/.credentials.json")"
  [ "$perms" = "600" ]
  [[ "$(cat "$HOME/.claude/.credentials.json")" == *"test-token"* ]]
}

@test "initialize.sh: keychain export overwrites a stale credentials file" {
  [ "$(uname)" = "Darwin" ] || skip "macOS keychain export only runs on Darwin"
  echo '{"token":"old-token"}' > "$HOME/.claude/.credentials.json"
  run bash "$INITIALIZE"
  [ "$status" -eq 0 ]
  local content; content="$(cat "$HOME/.claude/.credentials.json")"
  [[ "$content" == *"test-token"* ]]
  [[ "$content" != *"old-token"* ]]
}

@test "initialize.sh: exits non-zero with a clear error when keychain entry is missing" {
  [ "$(uname)" = "Darwin" ] || skip "macOS keychain export only runs on Darwin"
  create_stub security 1 ""
  run bash "$INITIALIZE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"credentials"* ]]
}

# ===========================================================================
# config/protect-paths — pattern parsing & exclusion (unit, no container)
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
# Integration lifecycle: adopt CONTAINER=... or regenerate template + devc up
# ===========================================================================

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
    return 0
  fi

  # Full lifecycle needs the devcontainer CLI and (on macOS) the keychain entry.
  if ! command -v devcontainer &>/dev/null; then
    INTEGRATION_SKIP_REASON="devcontainer CLI not installed on host"
    return 0
  fi
  if [[ "$(uname)" == "Darwin" ]] \
     && ! security find-generic-password -s "Claude Code-credentials" -w &>/dev/null; then
    INTEGRATION_SKIP_REASON="Keychain entry 'Claude Code-credentials' is missing"
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

@test "CS-01: credential file exists at /home/vscode/.claude/.credentials.json" {
  _integration_restore_env
  run dc_exec test -f /home/vscode/.claude/.credentials.json
  [ "$status" -eq 0 ]
}

@test "CS-01: credential file on host has permissions 600" {
  _integration_restore_env
  local perms
  perms="$(/usr/bin/stat -f "%Lp" "$REAL_HOME/.claude/.credentials.json" 2>/dev/null \
    || /usr/bin/stat -c "%a" "$REAL_HOME/.claude/.credentials.json" 2>/dev/null \
    || stat --format="%a" "$REAL_HOME/.claude/.credentials.json")"
  [ "$perms" = "600" ]
}

@test "CS-01: writing to the credential file inside the container persists to host" {
  _integration_restore_env
  local sentinel="integration-test-sentinel-$$"
  dc_exec bash -c "echo '$sentinel' >> /home/vscode/.claude/.credentials.json"
  grep -q "$sentinel" "$REAL_HOME/.claude/.credentials.json"
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
  run dc_exec test -d /Users
  [ "$status" -ne 0 ]
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
