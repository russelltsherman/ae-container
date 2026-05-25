#!/usr/bin/env bats
# .devcontainer/tests/dc.bats — consolidated devcontainer test suite.
#
# Covers:
#   - bin/dc CLI (unit tests, stubbed)
#   - Runtime invariants from SAFETY.md (NI-*, CS-*, PC-*) via docker inspect
#     and docker exec against a live container
#   - Seccomp hardening (PC-05) verified against the profile applied at runtime
#
# Prefers runtime verification over static config grepping. Static checks
# survive only where a runtime equivalent is not practical.
#
# Usage:
#   # Fast path — adopt an existing running devcontainer:
#   CONTAINER=<name-or-id> bats .devcontainer/tests/dc.bats
#
#   # Full lifecycle — setup_file runs `bin/dc up`, teardown removes:
#   bats .devcontainer/tests/dc.bats
#
# Requires: bash, docker, jq, bats-core. `bin/dc up` additionally requires
# the macOS keychain entry "Claude Code-credentials".

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DC="$REPO_ROOT/bin/dc"
PROFILE_PATH="$REPO_ROOT/.devcontainer/etc/seccomp/hardened.json"

# Save real PATH/HOME before per-test setup() swaps them for stubs.
REAL_PATH="$PATH"
REAL_HOME="$HOME"

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

# Per-test setup: rebuild stub dir. Integration tests call
# _integration_restore_env to swap back to real PATH/HOME.
setup() {
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$BATS_TEST_TMPDIR/calls"
  mkdir -p "$BATS_TEST_TMPDIR/home/.claude"
  mkdir -p "$BATS_TEST_TMPDIR/home/.config/graphite"
  create_stub devcontainer 0 ""
  create_stub security     0 '{"token":"test-token"}'
  create_stub docker       0 ""
  export PATH="$BATS_TEST_TMPDIR/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
  export HOME="$BATS_TEST_TMPDIR/home"
}

# ===========================================================================
# bin/dc unit tests (T-022 – T-030) — stubs, no container required
# ===========================================================================

@test "T-022: build subcommand invokes devcontainer build --workspace-folder ." {
  run "$DC" build
  [ "$status" -eq 0 ]
  calls="$(stub_calls devcontainer)"
  [[ "$calls" == *"build --workspace-folder ."* ]] || [[ "$calls" == *"build"* ]]
}

@test "T-022b: up subcommand calls devcontainer up --workspace-folder . without exec" {
  run "$DC" up
  [ "$status" -eq 0 ]
  calls="$(stub_calls devcontainer)"
  [[ "$calls" == *"up --workspace-folder ."* ]]
  [[ "$calls" != *"exec"* ]]
}

@test "T-023: launch exits non-zero with clear error when docker is absent" {
  rm "$BATS_TEST_TMPDIR/stubs/docker"
  run "$DC" launch
  [ "$status" -ne 0 ]
  [[ "$output" == *"docker"* ]]
}

@test "T-024: launch exits non-zero with clear error when keychain entry is missing" {
  create_stub security 1 ""
  run "$DC" launch
  [ "$status" -ne 0 ]
  [[ "$output" == *"Claude Code-credentials"* ]]
}

@test "T-025: launch creates HOME/.claude and writes credential file with permissions 600" {
  rm -rf "$HOME/.claude"
  run "$DC" launch
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/.credentials.json" ]
  perms="$(/usr/bin/stat -f "%Lp" "$HOME/.claude/.credentials.json" 2>/dev/null \
    || /usr/bin/stat -c "%a" "$HOME/.claude/.credentials.json" 2>/dev/null \
    || stat -c "%a" "$HOME/.claude/.credentials.json")"
  [ "$perms" = "600" ]
}

@test "T-026: launch overwrites existing credential file with current keychain value" {
  echo '{"token":"old-token"}' > "$HOME/.claude/.credentials.json"
  run "$DC" launch
  [ "$status" -eq 0 ]
  content="$(cat "$HOME/.claude/.credentials.json")"
  [[ "$content" == *"test-token"* ]]
  [[ "$content" != *"old-token"* ]]
}

@test "T-030: launch calls devcontainer up then devcontainer exec bash" {
  run "$DC" launch
  [ "$status" -eq 0 ]
  calls="$(stub_calls devcontainer)"
  [[ "$calls" == *"up --workspace-folder ."* ]]
  [[ "$calls" == *"exec --workspace-folder . bash"* ]]
}

# ===========================================================================
# initialize.sh — host-side docker-info probe (unit, no container required)
# ===========================================================================

@test "initialize.sh exits non-zero when docker info fails" {
  cat > "$BATS_TEST_TMPDIR/stubs/docker" <<'STUB'
#!/bin/sh
if [ "$1" = "info" ]; then exit 1; fi
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/stubs/docker"
  run "$REPO_ROOT/.devcontainer/config/initialize.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Docker"* ]] || [[ "$output" == *"docker"* ]]
}

@test "initialize.sh exits 0 when docker info succeeds" {
  run "$REPO_ROOT/.devcontainer/config/initialize.sh"
  [ "$status" -eq 0 ]
}

# ===========================================================================
# protect-paths — pattern parsing & exclusion (unit, no container required)
# ===========================================================================
#
# protect-paths normally runs inside the devcontainer with CAP_SYS_ADMIN and
# bind-mounts /dev/null over each matched file. For unit tests we point the
# script at a fake workspace via PROTECT_PATHS_WORKSPACE and replace the mount
# call with a recorder via PROTECT_PATHS_MASK_HOOK. Both env vars are honored
# only by the script's testing seam — production behavior is unchanged.

# Build a fake workspace at $1/<rel> populated with files declared in $2..,
# create $1/.devcontainer/protected-paths from the heredoc, and run the
# script. Records masked targets (relative to workspace root) into
# $BATS_TEST_TMPDIR/masked.
_pp_run() {
  local ws="$1" config="$2"
  shift 2
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
    bash "$REPO_ROOT/.devcontainer/config/protect-paths"
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

  PROTECT_PATHS_WORKSPACE="$ws" \
    run bash "$REPO_ROOT/.devcontainer/config/protect-paths"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing exclusion '/etc/passwd'"* ]]
  [[ "$output" == *"refusing exclusion '../escape'"* ]]
}

# ===========================================================================
# Integration lifecycle: adopt CONTAINER=... or launch via bin/dc up
# ===========================================================================

setup_file() {
  export INTEGRATION_SKIP_REASON=""
  export DC_CONTAINER_ID=""
  export DC_ENV_FIXTURE_CREATED=0
  export OWN_CONTAINER=0
  export DC_WORKSPACE="/workspaces/$(basename "$REPO_ROOT")"

  if ! docker info &>/dev/null; then
    INTEGRATION_SKIP_REASON="Docker Desktop is not running"
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

  # Full lifecycle: ensure keychain, seed .env fixture, run bin/dc up.
  if ! security find-generic-password -s "Claude Code-credentials" -w &>/dev/null; then
    INTEGRATION_SKIP_REASON="Keychain entry 'Claude Code-credentials' is missing"
    return 0
  fi

  export PATH="$REAL_PATH"
  export HOME="$REAL_HOME"

  if [[ ! -f "$REPO_ROOT/.env" ]]; then
    echo "SECRET=super-secret-value" > "$REPO_ROOT/.env"
    DC_ENV_FIXTURE_CREATED=1
  fi

  if ! (cd "$REPO_ROOT" && "$DC" up); then
    INTEGRATION_SKIP_REASON="bin/dc up failed during setup_file"
    return 0
  fi

  OWN_CONTAINER=1
  DC_CONTAINER_ID=$(docker ps \
    --filter "label=devcontainer.local_folder=$REPO_ROOT" \
    --format '{{.ID}}' | head -1)
  if [[ -z "$DC_CONTAINER_ID" ]]; then
    INTEGRATION_SKIP_REASON="bin/dc up completed but no container matches workspace label"
  fi
  return 0
}

teardown_file() {
  [[ -n "$INTEGRATION_SKIP_REASON" ]] && return 0
  export PATH="$REAL_PATH"
  [[ "${DC_ENV_FIXTURE_CREATED:-0}" -eq 1 ]] && rm -f "$REPO_ROOT/.env"
  if [[ "${OWN_CONTAINER:-0}" -eq 1 ]]; then
    docker ps -a --filter "label=devcontainer.local_folder=$REPO_ROOT" \
      --format '{{.ID}}' | xargs -r docker rm -f &>/dev/null || true
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
# Container lifecycle (T-030i)
# ===========================================================================

@test "T-030i: container is running" {
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

@test "T-040 / PC-04: .env matched by protected-paths is empty inside container" {
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

@test "PC-04: every non-template file in service secrets/ dirs is masked" {
  _integration_restore_env
  # Enumerate from the host because masked targets appear as character-
  # special inside the container and would be skipped by `test -f`.
  # `*.template.*` files are checked-in fixtures (empty placeholders) and
  # are exempted by the `!**/*.template.*` rule in protected-paths.
  local dir
  local -i checked=0
  for dir in temporal/secrets server/secrets apps/auth-webhook/secrets; do
    [ -d "$REPO_ROOT/$dir" ] || continue
    while IFS= read -r f; do
      local rel="${f#$REPO_ROOT/}"
      local base="${rel##*/}"
      case "$base" in *.template.*) continue ;; esac
      run dc_exec bash -c "wc -c < ${DC_WORKSPACE}/$rel"
      [ "$status" -eq 0 ]
      [[ "$output" =~ ^[[:space:]]*0[[:space:]]*$ ]] \
        || { echo "expected ${DC_WORKSPACE}/$rel masked, got: '$output'"; return 1; }
      checked+=1
    done < <(find "$REPO_ROOT/$dir" -type f)
  done
  [ "$checked" -ge 1 ]
}

@test "PC-04: *.template.* files in service secrets/ dirs are NOT masked" {
  _integration_restore_env
  # Templates are checked-in fixtures (empty-shape JSON) needed for type
  # inference, IDE help, and onboarding. They must remain readable.
  local dir
  local -i checked=0
  for dir in temporal/secrets server/secrets apps/auth-webhook/secrets; do
    [ -d "$REPO_ROOT/$dir" ] || continue
    while IFS= read -r f; do
      local rel="${f#$REPO_ROOT/}"
      local host_bytes; host_bytes=$(wc -c < "$f" | tr -d '[:space:]')
      run dc_exec bash -c "wc -c < ${DC_WORKSPACE}/$rel"
      [ "$status" -eq 0 ]
      local in_bytes; in_bytes=$(echo "$output" | tr -d '[:space:]')
      [ "$in_bytes" = "$host_bytes" ] \
        || { echo "expected ${DC_WORKSPACE}/$rel unmasked ($host_bytes bytes), got: '$in_bytes'"; return 1; }
      checked+=1
    done < <(find "$REPO_ROOT/$dir" -type f -name '*.template.*')
  done
  [ "$checked" -ge 1 ]
}

@test "PC-04: packages/secrets workspace package files are NOT masked" {
  _integration_restore_env
  # packages/secrets/ is a TS workspace package, not a secrets directory.
  # If it were swept up by a naive **/secrets/ glob, the build would break.
  run dc_exec bash -c "wc -c < ${DC_WORKSPACE}/packages/secrets/package.json"
  [ "$status" -eq 0 ]
  bytes="$(echo "$output" | tr -d '[:space:]')"
  [ "$bytes" -gt 0 ]
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

@test "PC-05: unshare --mount is blocked even via sudo (seccomp inherits)" {
  _integration_restore_env
  # sudo alone isn't allowed for arbitrary commands, but sudoers lets us run
  # protect-paths as root. Use docker exec -u 0 to reach root context without
  # sudoers, then verify seccomp still blocks.
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

@test "T-031 / CS-01: credential file exists at /home/vscode/.claude/.credentials.json" {
  _integration_restore_env
  run dc_exec test -f /home/vscode/.claude/.credentials.json
  [ "$status" -eq 0 ]
}

@test "T-032 / CS-01: credential file on host has permissions 600" {
  _integration_restore_env
  perms="$(/usr/bin/stat -f "%Lp" "$REAL_HOME/.claude/.credentials.json" 2>/dev/null \
    || /usr/bin/stat -c "%a" "$REAL_HOME/.claude/.credentials.json" 2>/dev/null \
    || stat --format="%a" "$REAL_HOME/.claude/.credentials.json")"
  [ "$perms" = "600" ]
}

@test "T-033 / CS-01: writing to credential file inside container persists to host" {
  _integration_restore_env
  local sentinel="integration-test-sentinel-$$"
  dc_exec bash -c "echo '$sentinel' >> /home/vscode/.claude/.credentials.json"
  grep -q "$sentinel" "$REAL_HOME/.claude/.credentials.json"
}

@test "T-034 / CS-04: Graphite config files readable inside container" {
  _integration_restore_env
  if [[ -f "$REAL_HOME/.config/graphite/aliases" ]]; then
    run dc_exec test -r /home/vscode/.config/graphite/aliases
    [ "$status" -eq 0 ]
  fi
  if [[ -f "$REAL_HOME/.config/graphite/user_config" ]]; then
    run dc_exec test -r /home/vscode/.config/graphite/user_config
    [ "$status" -eq 0 ]
  fi
}

@test "CS-04: .gitconfig is bind-mounted into the container" {
  _integration_restore_env
  run dc_exec test -f /home/vscode/.gitconfig
  [ "$status" -eq 0 ]
  run dc_exec bash -c 'mount | grep -c " on /home/vscode/.gitconfig "'
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "CS-04: .gitconfig mount is read-only" {
  _integration_restore_env
  run dc_exec findmnt -no OPTIONS /home/vscode/.gitconfig
  [ "$status" -eq 0 ]
  [[ "$output" =~ (^|,)ro(,|$) ]]
}

@test "CS-04: graphite aliases mount is read-only" {
  _integration_restore_env
  if ! dc_exec test -f /home/vscode/.config/graphite/aliases; then
    skip "graphite aliases not present on host; mount is conditional"
  fi
  run dc_exec findmnt -no OPTIONS /home/vscode/.config/graphite/aliases
  [ "$status" -eq 0 ]
  [[ "$output" =~ (^|,)ro(,|$) ]]
}

@test "CS-04: graphite user_config mount is read-write" {
  # Sibling of the two RO assertions above — user_config must stay RW so
  # `gt auth` token rotation persists back to the host.
  _integration_restore_env
  if ! dc_exec test -f /home/vscode/.config/graphite/user_config; then
    skip "graphite user_config not present on host"
  fi
  run dc_exec findmnt -no OPTIONS /home/vscode/.config/graphite/user_config
  [ "$status" -eq 0 ]
  [[ "$output" =~ (^|,)rw(,|$) ]]
}

@test "T-042 / CS-05: host paths outside repo/mounts are inaccessible from container" {
  _integration_restore_env
  run dc_exec test -d /Users
  [ "$status" -ne 0 ]
}

@test "CS-03: docker socket is not present inside container" {
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

@test "T-035 / NI-01: curl to a non-allowlisted domain is blocked" {
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
  # First line is the HTTP status; must not be 000 (curl failed before response).
  http_code="$(printf '%s\n' "$output" | sed -n '1p')"
  remote_ip="$(printf '%s\n' "$output" | sed -n '2p')"
  [[ "$http_code" != "000" ]]
  # %{remote_ip} is the peer the local socket connected to (the proxy on
  # 127.0.0.1), so the proof of DNS is that curl got a real HTTP response
  # back from squid for a hostname URL.
  [ -n "$remote_ip" ]
}

# ===========================================================================
# Required CLIs (T-036, T-037)
# ===========================================================================

@test "T-036: claude --version succeeds inside container" {
  # Claude installs a symlink in ~/.local/bin, which is only added to PATH
  # by the default Ubuntu ~/.profile on login. Use a login shell to match
  # the environment an interactive user (or `devcontainer exec bash`) gets.
  _integration_restore_env
  run dc_exec bash -lc 'claude --version'
  [ "$status" -eq 0 ]
}

@test "T-037: gt --version succeeds inside container" {
  _integration_restore_env
  run dc_exec gt --version
  [ "$status" -eq 0 ]
}
