#!/usr/bin/env bats

load helpers

setup() {
  setup_fake_home
  # shellcheck source=../scripts/lib.sh
  . "$SCRIPTS_DIR/lib.sh"
  PAYLOAD="$BATS_TEST_TMPDIR/payload"
}

# --- roots and excludes -----------------------------------------------------

@test "roots are skills only by default" {
  run ss_sync_roots
  [ "$status" -eq 0 ]
  [ "$output" = "skills" ]
}

@test "roots include each existing memory dir when SCOPE_MEMORY=1" {
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/-other/memory" \
    "$CLAUDE_CONFIG_DIR/projects/-no-memory"
  ss_config_set SCOPE_MEMORY 1
  run ss_sync_roots
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "skills" ]
  [ "${lines[1]}" = "projects/-fake-project/memory" ]
  [ "${lines[2]}" = "projects/-other/memory" ]
}

@test "roots exclude memory when SCOPE_MEMORY=0" {
  ss_config_set SCOPE_MEMORY 0
  run ss_sync_roots
  [ "$output" = "skills" ]
}

@test "exclude args default to .git, .DS_Store, *.bak" {
  run ss_exclude_args
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "--exclude=.git" ]
  [ "${lines[1]}" = "--exclude=.DS_Store" ]
  [ "${lines[2]}" = "--exclude=*.bak" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "exclude args follow EXCLUDE and drop empty entries" {
  ss_config_set EXCLUDE 'node_modules::*.tmp:'
  run ss_exclude_args
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "--exclude=node_modules" ]
  [ "${lines[1]}" = "--exclude=*.tmp" ]
}

# --- staging ------------------------------------------------------------------

@test "staging copies skills and skips .git, .DS_Store, and *.bak" {
  mkdir -p "$CLAUDE_CONFIG_DIR/skills/alpha/.git/objects"
  printf 'ref\n' >"$CLAUDE_CONFIG_DIR/skills/alpha/.git/HEAD"
  printf 'x\n' >"$CLAUDE_CONFIG_DIR/skills/alpha/.DS_Store"
  printf 'x\n' >"$CLAUDE_CONFIG_DIR/skills/.DS_Store"
  printf 'x\n' >"$CLAUDE_CONFIG_DIR/skills/beta/SKILL.md.bak"
  ss_stage "$PAYLOAD"
  [ -f "$PAYLOAD/skills/alpha/SKILL.md" ]
  [ -f "$PAYLOAD/skills/beta/SKILL.md" ]
  [ ! -e "$PAYLOAD/skills/alpha/.git" ]
  [ ! -e "$PAYLOAD/skills/alpha/.DS_Store" ]
  [ ! -e "$PAYLOAD/skills/.DS_Store" ]
  [ ! -e "$PAYLOAD/skills/beta/SKILL.md.bak" ]
  [ ! -e "$PAYLOAD/projects" ]
  cmp "$CLAUDE_CONFIG_DIR/skills/alpha/SKILL.md" "$PAYLOAD/skills/alpha/SKILL.md"
}

@test "staging includes memory when SCOPE_MEMORY=1 and never private files" {
  add_private_files
  ss_config_set SCOPE_MEMORY 1
  ss_stage "$PAYLOAD"
  [ -f "$PAYLOAD/projects/-fake-project/memory/MEMORY.md" ]
  [ ! -e "$PAYLOAD/projects/-fake-project/sessions" ]
  [ ! -e "$PAYLOAD/settings.json" ]
  [ ! -e "$PAYLOAD/CLAUDE.md" ]
  [ ! -e "$PAYLOAD/skill-sync" ]
}

@test "staging creates an empty skills dir when there are no skills" {
  rm -rf "$CLAUDE_CONFIG_DIR/skills"
  ss_stage "$PAYLOAD"
  [ -d "$PAYLOAD/skills" ]
}

@test "staging keeps a file name with spaces and a glob character" {
  printf 'x\n' >"$CLAUDE_CONFIG_DIR/skills/alpha/notes [draft] v2.md"
  ss_stage "$PAYLOAD"
  [ -f "$PAYLOAD/skills/alpha/notes [draft] v2.md" ]
}

# --- manifest -------------------------------------------------------------------

@test "manifest round-trips host and memory" {
  ss_write_manifest "$PAYLOAD"
  local file="$PAYLOAD/skill-sync.json"
  [ -f "$file" ]
  [ "$(ss_read_manifest "$file" host)" = "$(ss_host)" ]
  [ "$(ss_read_manifest "$file" memory)" = "false" ]
  [ "$(ss_read_manifest "$file" format)" = "1" ]
  [[ "$(ss_read_manifest "$file" createdAt)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
  [ "$(ss_read_manifest "$file" pluginVersion)" = \
    "$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SCRIPTS_DIR/../.claude-plugin/plugin.json")" ]

  ss_config_set SCOPE_MEMORY 1
  ss_write_manifest "$PAYLOAD"
  [ "$(ss_read_manifest "$file" memory)" = "true" ]
}

@test "manifest is one line of JSON in the documented shape" {
  ss_write_manifest "$PAYLOAD"
  [ "$(wc -l <"$PAYLOAD/skill-sync.json" | tr -d ' ')" -eq 1 ]
  grep -Eq '^\{"format":1,"host":"[a-z0-9-]+","createdAt":"[^"]+","memory":(true|false),"pluginVersion":"[^"]+"\}$' \
    "$PAYLOAD/skill-sync.json"
  if command -v jq >/dev/null 2>&1; then
    jq -e '.format == 1' "$PAYLOAD/skill-sync.json"
  fi
}

@test "read_manifest returns 1 for a missing key or file" {
  ss_write_manifest "$PAYLOAD"
  run ss_read_manifest "$PAYLOAD/skill-sync.json" nope
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  run ss_read_manifest "$PAYLOAD/missing.json" host
  [ "$status" -eq 1 ]
}

@test "read_manifest tolerates whitespace from other writers" {
  printf '{\n  "format": 1,\n  "host" : "box-2",\n  "memory": true\n}\n' >"$BATS_TEST_TMPDIR/m.json"
  [ "$(ss_read_manifest "$BATS_TEST_TMPDIR/m.json" host)" = "box-2" ]
  [ "$(ss_read_manifest "$BATS_TEST_TMPDIR/m.json" memory)" = "true" ]
  [ "$(ss_read_manifest "$BATS_TEST_TMPDIR/m.json" format)" = "1" ]
}

# --- diff -----------------------------------------------------------------------

@test "diff of a fresh stage is empty and returns 0" {
  ss_stage "$PAYLOAD"
  run ss_diff "$PAYLOAD"
  [ "$status" -eq 0 ]
  [ "${lines[3]}" = "0 added, 0 changed, 0 deleted" ]
}

@test "diff reports one added, one changed, one deleted after editing the fake home" {
  ss_stage "$PAYLOAD"
  printf 'changed\n' >>"$CLAUDE_CONFIG_DIR/skills/alpha/SKILL.md"
  rm -rf "$CLAUDE_CONFIG_DIR/skills/beta"
  mkdir -p "$CLAUDE_CONFIG_DIR/skills/gamma"
  printf 'gamma\n' >"$CLAUDE_CONFIG_DIR/skills/gamma/SKILL.md"

  run ss_diff "$PAYLOAD"
  [ "$status" -eq 10 ]
  [ "$output" = "added:
  skills/beta/SKILL.md
changed:
  skills/alpha/SKILL.md
deleted:
  skills/gamma/SKILL.md
1 added, 1 changed, 1 deleted" ]
}

@test "diff ignores excluded files on both sides" {
  ss_stage "$PAYLOAD"
  printf 'x\n' >"$PAYLOAD/skills/alpha/.DS_Store"
  mkdir -p "$CLAUDE_CONFIG_DIR/skills/beta/.git"
  printf 'x\n' >"$CLAUDE_CONFIG_DIR/skills/beta/.git/HEAD"
  printf 'x\n' >"$CLAUDE_CONFIG_DIR/skills/beta/old.bak"
  run ss_diff "$PAYLOAD"
  [ "$status" -eq 0 ]
}

@test "diff sorts paths and handles names with spaces and ' and '" {
  ss_stage "$PAYLOAD"
  printf 'a\n' >"$PAYLOAD/skills/alpha/x and y.md"
  printf 'b\n' >"$CLAUDE_CONFIG_DIR/skills/alpha/x and y.md"
  printf 'z\n' >"$PAYLOAD/skills/beta/z.md"
  printf 'a\n' >"$PAYLOAD/skills/alpha/a.md"
  run ss_diff "$PAYLOAD"
  [ "$status" -eq 10 ]
  [ "${lines[1]}" = "  skills/alpha/a.md" ]
  [ "${lines[2]}" = "  skills/beta/z.md" ]
  [ "${lines[4]}" = "  skills/alpha/x and y.md" ]
  [ "${lines[6]}" = "2 added, 1 changed, 0 deleted" ]
}

@test "diff covers memory roots present on only one side" {
  ss_config_set SCOPE_MEMORY 1
  ss_stage "$PAYLOAD"
  mkdir -p "$PAYLOAD/projects/-remote-only/memory"
  printf 'r\n' >"$PAYLOAD/projects/-remote-only/memory/MEMORY.md"
  rm -rf "$PAYLOAD/projects/-fake-project"
  run ss_diff "$PAYLOAD"
  [ "$status" -eq 10 ]
  [[ "$output" == *"added:
  projects/-remote-only/memory/MEMORY.md
changed:
deleted:
  projects/-fake-project/memory/MEMORY.md
"* ]]
}

# --- apply ----------------------------------------------------------------------

@test "merge apply adds and overwrites and keeps a local-only skill" {
  ss_stage "$PAYLOAD"
  rm -rf "$PAYLOAD/skills/beta"
  printf 'remote alpha\n' >"$PAYLOAD/skills/alpha/SKILL.md"
  mkdir -p "$PAYLOAD/skills/delta"
  printf 'delta\n' >"$PAYLOAD/skills/delta/SKILL.md"

  ss_apply "$PAYLOAD" merge
  [ "$(cat "$CLAUDE_CONFIG_DIR/skills/alpha/SKILL.md")" = "remote alpha" ]
  [ -f "$CLAUDE_CONFIG_DIR/skills/delta/SKILL.md" ]
  [ -f "$CLAUDE_CONFIG_DIR/skills/beta/SKILL.md" ]
}

@test "mirror apply deletes a local-only skill and its empty directory" {
  ss_stage "$PAYLOAD"
  rm -rf "$PAYLOAD/skills/beta"
  mkdir -p "$CLAUDE_CONFIG_DIR/skills/beta/nested/deeper"
  printf 'n\n' >"$CLAUDE_CONFIG_DIR/skills/beta/nested/deeper/file.md"

  ss_apply "$PAYLOAD" mirror
  [ ! -e "$CLAUDE_CONFIG_DIR/skills/beta" ]
  [ -f "$CLAUDE_CONFIG_DIR/skills/alpha/SKILL.md" ]
  [ -d "$CLAUDE_CONFIG_DIR/skills" ]
  run ss_diff "$PAYLOAD"
  [ "$status" -eq 0 ]
}

@test "mirror apply keeps excluded local files such as a skill's .git" {
  mkdir -p "$CLAUDE_CONFIG_DIR/skills/alpha/.git"
  printf 'ref\n' >"$CLAUDE_CONFIG_DIR/skills/alpha/.git/HEAD"
  ss_stage "$PAYLOAD"
  ss_apply "$PAYLOAD" mirror
  [ -f "$CLAUDE_CONFIG_DIR/skills/alpha/.git/HEAD" ]
}

@test "mirror apply never deletes outside the roots" {
  add_private_files
  ss_config_set SCOPE_MEMORY 1
  ss_stage "$PAYLOAD"
  # An empty payload: mirror has the most to delete.
  rm -rf "$PAYLOAD/skills" "$PAYLOAD/projects"
  mkdir -p "$PAYLOAD/skills"
  local settings_before before after
  settings_before="$(cksum <"$CLAUDE_CONFIG_DIR/settings.json")"
  before="$(checksum_outside_roots)"

  ss_apply "$PAYLOAD" mirror

  [ -f "$CLAUDE_CONFIG_DIR/settings.json" ]
  [ "$(cksum <"$CLAUDE_CONFIG_DIR/settings.json")" = "$settings_before" ]
  after="$(checksum_outside_roots)"
  [ "$before" = "$after" ]
  [[ "$before" == *"./settings.json"* ]]
  [[ "$before" == *"./projects/-fake-project/sessions/a.jsonl"* ]]
  [ ! -e "$CLAUDE_CONFIG_DIR/skills/alpha" ]
  [ ! -e "$CLAUDE_CONFIG_DIR/projects/-fake-project/memory/MEMORY.md" ]
}

@test "mirror apply with SCOPE_MEMORY=0 leaves memory alone" {
  ss_stage "$PAYLOAD"
  rm -rf "$PAYLOAD/skills/alpha"
  ss_apply "$PAYLOAD" mirror
  [ -f "$CLAUDE_CONFIG_DIR/projects/-fake-project/memory/MEMORY.md" ]
  [ ! -e "$CLAUDE_CONFIG_DIR/skills/alpha" ]
}

@test "the delete guard refuses paths outside the roots" {
  local cfg="$CLAUDE_CONFIG_DIR"
  printf '{}\n' >"$cfg/settings.json"
  run ss__remove_in_root "$cfg" skills ../settings.json
  [ "$status" -eq 1 ]
  [[ "$output" == "Refusing to delete outside the sync roots"* ]]
  run ss__remove_in_root "$cfg" . settings.json
  [ "$status" -eq 1 ]
  run ss__remove_in_root "$cfg" projects/../memory x
  [ "$status" -eq 1 ]
  run ss__remove_in_root "$cfg" skills "alpha/../../settings.json"
  [ "$status" -eq 1 ]
  run ss__remove_in_root "$cfg" skills "/etc/hosts"
  [ "$status" -eq 1 ]
  run ss__remove_in_root "$cfg" skills ""
  [ "$status" -eq 1 ]
  [ -f "$cfg/settings.json" ]
  [ -f "$cfg/skills/alpha/SKILL.md" ]

  run ss__remove_in_root "$cfg" skills alpha/SKILL.md
  [ "$status" -eq 0 ]
  [ ! -e "$cfg/skills/alpha/SKILL.md" ]
}

@test "apply rejects an unknown mode" {
  ss_stage "$PAYLOAD"
  run ss_apply "$PAYLOAD" overwrite
  [ "$status" -eq 1 ]
}

# --- backup ---------------------------------------------------------------------

@test "backup zip exists and contains skills/alpha/SKILL.md and the manifest" {
  run ss_backup pull
  [ "$status" -eq 0 ]
  local zip="$output"
  [[ "$zip" == "$CLAUDE_CONFIG_DIR/skill-sync/backups/"* ]]
  [[ "$(basename "$zip")" =~ ^[0-9]{8}-[0-9]{6}-pull\.zip$ ]]
  [ -f "$zip" ]
  unzip -l "$zip" | grep -q ' skills/alpha/SKILL.md$'
  unzip -l "$zip" | grep -q ' skill-sync.json$'
  unzip -p "$zip" skills/alpha/SKILL.md | cmp - "$CLAUDE_CONFIG_DIR/skills/alpha/SKILL.md"
}

@test "backup leaves no temporary directory behind" {
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  ss_backup pull >/dev/null
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "the eleventh backup removes the oldest" {
  local dir="$CLAUDE_CONFIG_DIR/skill-sync/backups" i
  mkdir -p "$dir"
  for i in 01 02 03 04 05 06 07 08 09 10; do
    printf 'old\n' >"$dir/200001${i}-000000-pull.zip"
  done
  printf 'mine\n' >"$dir/notes.zip"

  run ss_backup import
  [ "$status" -eq 0 ]
  [ -f "$output" ]
  [ ! -e "$dir/20000101-000000-pull.zip" ]
  [ -f "$dir/20000102-000000-pull.zip" ]
  [ -f "$dir/notes.zip" ]
  [ "$(ls "$dir" | grep -c '^[0-9]\{8\}-[0-9]\{6\}-.*\.zip$')" -eq 10 ]
}

@test "backups taken in the same second get distinct names" {
  local a b
  a="$(ss_backup pull)"
  b="$(ss_backup pull)"
  [ "$a" != "$b" ]
  [ -f "$a" ]
  [ -f "$b" ]
}

@test "no function in lib.sh calls rsync" {
  ! grep -v '^[[:space:]]*#' "$SCRIPTS_DIR/lib.sh" | grep -q rsync
}
