#!/usr/bin/env bats

load helpers

setup() {
  setup_fake_home
  # shellcheck source=../scripts/lib.sh
  . "$SCRIPTS_DIR/lib.sh"
}

@test "ss_config_dir uses CLAUDE_CONFIG_DIR when set" {
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/elsewhere"
  run ss_config_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/elsewhere" ]
}

@test "ss_config_dir falls back to HOME/.claude" {
  unset CLAUDE_CONFIG_DIR
  run ss_config_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.claude" ]
}

@test "ss_state_dir defaults under the config dir and is created" {
  run ss_state_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$CLAUDE_CONFIG_DIR/skill-sync" ]
  [ -d "$CLAUDE_CONFIG_DIR/skill-sync" ]
}

@test "ss_state_dir honors SKILL_SYNC_HOME" {
  export SKILL_SYNC_HOME="$BATS_TEST_TMPDIR/state"
  run ss_config_file
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/state/config" ]
  [ -d "$BATS_TEST_TMPDIR/state" ]
}

@test "ss_config_set then ss_config_get round-trips" {
  ss_config_set MODE git
  ss_config_set GIT_REMOTE 'git@github.com:you/x.git'
  [ "$(ss_config_get MODE)" = "git" ]
  [ "$(ss_config_get GIT_REMOTE)" = "git@github.com:you/x.git" ]
}

@test "ss_config_set keeps special characters verbatim" {
  local value='a b=c\d&e/f$g*'
  ss_config_set EXCLUDE "$value"
  [ "$(ss_config_get EXCLUDE)" = "$value" ]
}

@test "ss_config_set replaces an existing key in place" {
  ss_config_set MODE git
  ss_config_set SCOPE_MEMORY 0
  ss_config_set MODE zip
  [ "$(ss_config_get MODE)" = "zip" ]
  [ "$(grep -c '^MODE=' "$(ss_config_file)")" -eq 1 ]
  [ "$(head -n 1 "$(ss_config_file)")" = "MODE=zip" ]
}

@test "ss_config_get prints the default for a missing key" {
  run ss_config_get GIT_BRANCH main
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "ss_config_get prints empty for a missing key without default" {
  run ss_config_get GIT_BRANCH
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "ss_config_get does not execute the config file" {
  printf 'MODE=$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" >"$(ss_config_file)"
  run ss_config_get MODE
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "ss_config_set rejects an invalid key" {
  run ss_config_set 'bad-key' x
  [ "$status" -eq 1 ]
}

@test "ss_require_config exits 2 when MODE is unset" {
  run ss_require_config
  [ "$status" -eq 2 ]
  [ "$output" = "Not configured. Run /skill-sync:setup." ]
}

@test "ss_require_config passes when MODE is set" {
  ss_config_set MODE zip
  run ss_require_config
  [ "$status" -eq 0 ]
}

@test "ss_require_cmd exits 3 naming the missing tool" {
  run ss_require_cmd sh skill-sync-no-such-tool-xyz
  [ "$status" -eq 3 ]
  [[ "$output" == *"skill-sync-no-such-tool-xyz"* ]]
}

@test "ss_require_cmd passes for present tools" {
  run ss_require_cmd sh mkdir
  [ "$status" -eq 0 ]
}

@test "ss_die uses the given code, default 1" {
  run ss_die "boom"
  [ "$status" -eq 1 ]
  [ "$output" = "boom" ]
  run ss_die "boom" 5
  [ "$status" -eq 5 ]
}

@test "ss_log appends a timestamped line and echoes to stderr" {
  run ss_log INFO "hello world"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INFO hello world" ]]
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z INFO hello world$' \
    "$CLAUDE_CONFIG_DIR/skill-sync/sync.log"
}

@test "ss_host is lowercase alphanumerics and dashes" {
  run ss_host
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[a-z0-9-]+$ ]]
}

@test "ss_now is ISO 8601 UTC" {
  run ss_now
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "ss_tmpdir dirs are all removed on exit and the exit code is kept" {
  run bash -c '
    set -euo pipefail
    . "$1/lib.sh"
    ss_tmpdir a
    ss_tmpdir b
    [ -d "$a" ] && [ -d "$b" ] && [ "$a" != "$b" ]
    printf "%s\n%s\n" "$a" "$b"
    exit 7
  ' _ "$SCRIPTS_DIR"
  [ "$status" -eq 7 ]
  [ "${#lines[@]}" -eq 2 ]
  [ ! -e "${lines[0]}" ]
  [ ! -e "${lines[1]}" ]
}

@test "ss_tmpdir defaults to SS_TMPDIR and cleans up on error exit" {
  run bash -c '
    set -euo pipefail
    . "$1/lib.sh"
    ss_tmpdir
    printf "%s\n" "$SS_TMPDIR"
    false
  ' _ "$SCRIPTS_DIR"
  [ "$status" -eq 1 ]
  [ -n "$output" ]
  [ ! -e "$output" ]
}

@test "status.sh exits 2 when not configured" {
  run "$SCRIPTS_DIR/status.sh"
  [ "$status" -eq 2 ]
  [ "$output" = "Not configured. Run /skill-sync:setup." ]
}

@test "status.sh prints the config when configured" {
  ss_config_set MODE git
  run "$SCRIPTS_DIR/status.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "MODE=git" ]
}
