# shellcheck shell=bash
# Shared functions for skill-sync scripts.
#
# This file is sourced, never executed. Sourcing it turns on strict mode in
# the caller, so every script runs under `set -euo pipefail`.
# Target: bash 3.2 (no associative arrays, no mapfile, no ${var,,}).

set -euo pipefail

if [ -n "${SS_LIB_LOADED:-}" ]; then
  return 0
fi
SS_LIB_LOADED=1

# Exit codes, fixed so SKILL.md files can branch on them (docs/PLAN.md).
# shellcheck disable=SC2034
{
  SS_EXIT_OK=0
  SS_EXIT_USAGE=1
  SS_EXIT_UNCONFIGURED=2
  SS_EXIT_MISSING_TOOL=3
  SS_EXIT_NETWORK=4
  SS_EXIT_DIVERGED=5
  SS_EXIT_CONFIRM=6
}

# Print MESSAGE to stderr and exit with CODE (default 1).
ss_die() {
  printf '%s\n' "$1" >&2
  exit "${2:-$SS_EXIT_USAGE}"
}

# The Claude Code config directory, honoring CLAUDE_CONFIG_DIR.
ss_config_dir() {
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# The plugin's state directory, honoring SKILL_SYNC_HOME. Created if missing.
ss_state_dir() {
  local dir
  dir="${SKILL_SYNC_HOME:-$(ss_config_dir)/skill-sync}"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

ss_config_file() {
  printf '%s/config\n' "$(ss_state_dir)"
}

# Config keys are [A-Z_]+; anything else is a programming error.
ss__check_key() {
  case "$1" in
    "" | *[!A-Z_]*) ss_die "Invalid config key: '$1'" "$SS_EXIT_USAGE" ;;
  esac
}

# Print the value of KEY from the config file, or DEFAULT when the key is
# absent. The file is parsed with grep and never sourced.
ss_config_get() {
  local key="$1" default="${2:-}" file line
  ss__check_key "$key"
  file="$(ss_config_file)"
  line=""
  if [ -f "$file" ]; then
    line="$(grep "^${key}=" "$file" | tail -n 1)" || true
  fi
  if [ -n "$line" ]; then
    printf '%s\n' "${line#*=}"
  else
    printf '%s\n' "$default"
  fi
}

# Set KEY to VALUE, replacing an existing line in place or appending one.
ss_config_set() {
  local key="$1" value="$2" file tmp
  ss__check_key "$key"
  case "$value" in
    *"
"*) ss_die "Config value for $key must be a single line" "$SS_EXIT_USAGE" ;;
  esac
  file="$(ss_config_file)"
  [ -f "$file" ] || : >"$file"
  tmp="$file.tmp.$$"
  # Pass the value through the environment: awk -v would expand backslashes.
  SS_KEY="$key" SS_VALUE="$value" awk '
    BEGIN { k = ENVIRON["SS_KEY"]; v = ENVIRON["SS_VALUE"]; done = 0 }
    index($0, k "=") == 1 { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Exit 2 unless setup has written a MODE.
ss_require_config() {
  if [ -z "$(ss_config_get MODE)" ]; then
    ss_die "Not configured. Run /skill-sync:setup." "$SS_EXIT_UNCONFIGURED"
  fi
}

# Append "<timestamp> <LEVEL> <message>" to sync.log and echo it to stderr.
ss_log() {
  local line
  line="$(ss_now) $1 $2"
  printf '%s\n' "$line" >>"$(ss_state_dir)/sync.log"
  printf '%s\n' "$line" >&2
}

# Exit 3 naming the first tool in NAME... that is not on PATH.
ss_require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 ||
      ss_die "Required tool not found: $cmd" "$SS_EXIT_MISSING_TOOL"
  done
}

# Short hostname, lowercase, non-alphanumerics replaced by '-'.
ss_host() {
  local name
  name="$(hostname -s 2>/dev/null)" || name=""
  [ -n "$name" ] || name="$(uname -n)"
  name="${name%%.*}"
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')"
  printf '%s\n' "${name:-unknown}"
}

# ISO 8601 UTC timestamp.
ss_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

SS_TMPDIRS=()

ss__cleanup_tmpdirs() {
  local dir
  for dir in ${SS_TMPDIRS[@]+"${SS_TMPDIRS[@]}"}; do
    rm -rf "$dir"
  done
}

# Create a temporary directory, removed when the script exits, and store its
# path in VARNAME (default SS_TMPDIR).
#
# Call it directly, never inside $(...): a command substitution is a subshell,
# so the directory list and the trap would be lost. One EXIT trap serves every
# call; each call adds to SS_TMPDIRS.
ss_tmpdir() {
  local var="${1:-SS_TMPDIR}" base="${TMPDIR:-/tmp}" dir
  dir="$(mktemp -d "${base%/}/skill-sync.XXXXXX")"
  if [ "${#SS_TMPDIRS[@]}" -eq 0 ]; then
    trap ss__cleanup_tmpdirs EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
  fi
  SS_TMPDIRS[${#SS_TMPDIRS[@]}]="$dir"
  printf -v "$var" '%s' "$dir"
}
