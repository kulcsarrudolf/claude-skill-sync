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
