# shellcheck shell=bash
# Shared bats helpers. Every test runs against a throwaway HOME and
# CLAUDE_CONFIG_DIR under $BATS_TEST_TMPDIR, never the real ~/.claude.

SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/../scripts" && pwd)"
export SCRIPTS_DIR

setup_fake_home() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  unset SKILL_SYNC_HOME

  mkdir -p "$CLAUDE_CONFIG_DIR/skills/alpha" \
    "$CLAUDE_CONFIG_DIR/skills/beta" \
    "$CLAUDE_CONFIG_DIR/projects/-fake-project/memory"

  printf -- '---\nname: alpha\ndescription: Alpha test skill.\n---\n\nAlpha body.\n' \
    >"$CLAUDE_CONFIG_DIR/skills/alpha/SKILL.md"
  printf -- '---\nname: beta\ndescription: Beta test skill.\n---\n\nBeta body.\n' \
    >"$CLAUDE_CONFIG_DIR/skills/beta/SKILL.md"
  printf -- '# Memory\n\n- fake project note\n' \
    >"$CLAUDE_CONFIG_DIR/projects/-fake-project/memory/MEMORY.md"
}

# Checksum every file under CLAUDE_CONFIG_DIR except the sync roots
# (skills/ and projects/*/memory/), plus the list of directories, so a test
# can assert that nothing outside the roots changed.
checksum_outside_roots() {
  (
    cd "$CLAUDE_CONFIG_DIR" || exit 1
    find . \( -path ./skills -o -path './projects/*/memory' \) -prune -o -print |
      LC_ALL=C sort |
      while IFS= read -r path; do
        if [ -f "$path" ]; then
          printf '%s %s\n' "$(cksum <"$path")" "$path"
        else
          printf 'dir %s\n' "$path"
        fi
      done
  )
}

# Files outside the roots that a mirror apply must never touch.
add_private_files() {
  printf '{"model":"opus"}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
  printf '# private\n' >"$CLAUDE_CONFIG_DIR/CLAUDE.md"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/-fake-project/sessions"
  printf 'session\n' >"$CLAUDE_CONFIG_DIR/projects/-fake-project/sessions/a.jsonl"
}
