# shellcheck shell=bash
# Shared functions for skill-sync scripts.
#
# This file is sourced, never executed. Sourcing it turns on strict mode in
# the caller, so every script runs under `set -euo pipefail`.
# Target: bash 3.2 (no associative arrays, no mapfile, no ${var,,}).

set -euo pipefail

# comm, sort, and glob order must agree on one byte-wise collation.
export LC_ALL=C

if [ -n "${SS_LIB_LOADED:-}" ]; then
  return 0
fi
SS_LIB_LOADED=1

SS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ---------------------------------------------------------------------------
# The sync set. Push, pull, export, and import move files only through these
# functions, so they cannot disagree about what is in scope (docs/PLAN.md).
# ---------------------------------------------------------------------------

SS_MANIFEST_NAME=skill-sync.json
SS_MANIFEST_FORMAT=1
SS_BACKUP_KEEP=10
SS_DIFF_CHANGES=10

# Roots under BASE, relative to it, one per line: skills, and when
# SCOPE_MEMORY=1 every existing projects/<key>/memory directory.
ss__roots_in() {
  local base="$1" dir
  printf 'skills\n'
  if [ "$(ss_config_get SCOPE_MEMORY 0)" = 1 ]; then
    for dir in "$base"/projects/*/memory; do
      if [ -d "$dir" ]; then
        printf '%s\n' "${dir#"$base"/}"
      fi
    done
  fi
}

# The sync roots of the config dir, relative to it, one per line.
ss_sync_roots() {
  ss__roots_in "$(ss_config_dir)"
}

# Roots present in SRC or in the config dir, sorted and unique.
ss__union_roots() {
  local src="$1" a b
  a="$(ss__roots_in "$src")"
  b="$(ss_sync_roots)"
  printf '%s\n%s\n' "$a" "$b" | sort -u
}

# EXCLUDE split on ':', one pattern per line, empty entries dropped.
ss__exclude_patterns() {
  local rest pat
  rest="$(ss_config_get EXCLUDE '.git:.DS_Store:*.bak'):"
  while [ -n "$rest" ]; do
    pat="${rest%%:*}"
    rest="${rest#*:}"
    if [ -n "$pat" ]; then
      printf '%s\n' "$pat"
    fi
  done
}

# One tar --exclude argument per line. Read the lines into an array; never
# expand the output unquoted, or a pattern like *.bak is globbed.
ss_exclude_args() {
  local pat
  ss__exclude_patterns | while IFS= read -r pat; do
    printf -- '--exclude=%s\n' "$pat"
  done
}

# Copy the contents of directory SRC into DEST with a tar pipe, excludes
# applied. Existing files in DEST are overwritten; nothing is deleted.
ss__copy_tree() {
  local src="$1" dest="$2" arg
  local -a args=()
  while IFS= read -r arg; do
    args[${#args[@]}]="$arg"
  done < <(ss_exclude_args)
  mkdir -p "$dest"
  # COPYFILE_DISABLE keeps macOS tar from adding ._ AppleDouble files.
  COPYFILE_DISABLE=1 tar -C "$src" ${args[@]+"${args[@]}"} -cf - . |
    tar -C "$dest" -xf -
}

# Files and symlinks under DIR, relative to it, excludes applied, sorted.
# Prints nothing when DIR does not exist.
ss__list_files() {
  local dir="$1" pat list
  local -a expr=()
  [ -d "$dir" ] || return 0
  while IFS= read -r pat; do
    if [ "${#expr[@]}" -gt 0 ]; then
      expr[${#expr[@]}]=-o
    fi
    expr[${#expr[@]}]=-name
    expr[${#expr[@]}]="$pat"
  done < <(ss__exclude_patterns)
  if [ "${#expr[@]}" -gt 0 ]; then
    list="$(cd "$dir" && find . \( "${expr[@]}" \) -prune -o \( -type f -o -type l \) -print)"
  else
    list="$(cd "$dir" && find . \( -type f -o -type l \) -print)"
  fi
  if [ -n "$list" ]; then
    printf '%s\n' "$list" | sed 's|^\./||' | sort
  fi
}

# Copy every sync root from the config dir into DEST, giving DEST/skills/...
# and DEST/projects/<key>/memory/.... Each root directory is created in DEST
# even when it is missing locally.
ss_stage() {
  local dest="$1" cfg roots root
  cfg="$(ss_config_dir)"
  roots="$(ss_sync_roots)"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    mkdir -p "$dest/$root"
    if [ -d "$cfg/$root" ]; then
      ss__copy_tree "$cfg/$root" "$dest/$root"
    fi
  done <<<"$roots"
}

# The version field of the plugin.json that ships with these scripts.
ss__plugin_version() {
  local file="$SS_LIB_DIR/../.claude-plugin/plugin.json" version=""
  if [ -f "$file" ]; then
    version="$(grep -m 1 '"version"' "$file" |
      sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')" || true
  fi
  version="$(printf '%s' "$version" | tr -cd 'A-Za-z0-9.+-')"
  printf '%s\n' "${version:-unknown}"
}

# Write DIR/skill-sync.json. Every value is generated here and contains no
# character that needs JSON escaping, so printf is enough.
ss_write_manifest() {
  local dir="$1" memory=false
  if [ "$(ss_config_get SCOPE_MEMORY 0)" = 1 ]; then
    memory=true
  fi
  mkdir -p "$dir"
  printf '{"format":%s,"host":"%s","createdAt":"%s","memory":%s,"pluginVersion":"%s"}\n' \
    "$SS_MANIFEST_FORMAT" "$(ss_host)" "$(ss_now)" "$memory" "$(ss__plugin_version)" \
    >"$dir/$SS_MANIFEST_NAME"
}

# Print the top-level string, boolean, or integer value of KEY in manifest
# FILE. Returns 1 with no output when the file or the key is missing.
ss_read_manifest() {
  local file="$1" key="$2" match
  case "$key" in
    "" | *[!A-Za-z]*) ss_die "Invalid manifest key: '$key'" "$SS_EXIT_USAGE" ;;
  esac
  [ -f "$file" ] || return 1
  match="$(grep -oE "\"$key\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|true|false|-?[0-9]+)" "$file" |
    head -n 1)" || return 1
  [ -n "$match" ] || return 1
  printf '%s\n' "${match#*:}" | sed 's/^[[:space:]]*//; s/^"//; s/"$//'
}

# Paths under SRCDIR whose content differs from the same path under DSTDIR,
# relative to both, one per line, from diff -rq. Presence differences are
# left to the caller, which lists files the same way the mirror does.
ss__changed_files() {
  local srcdir="$1" dstdir="$2" pat out line mid rel n tail rc=0
  local -a args=()
  while IFS= read -r pat; do
    args[${#args[@]}]=-x
    args[${#args[@]}]="$pat"
  done < <(ss__exclude_patterns)
  out="$(command diff -rq ${args[@]+"${args[@]}"} "$srcdir" "$dstdir" 2>&1)" || rc=$?
  if [ "$rc" -gt 1 ]; then
    ss_die "diff failed comparing $srcdir and $dstdir:
$out" "$SS_EXIT_USAGE"
  fi
  [ -n "$out" ] || return 0
  tail=" and $dstdir/"
  while IFS= read -r line; do
    case "$line" in
      "Files $srcdir/"*" differ") ;;
      *) continue ;;
    esac
    # The line is "Files S/rel and D/rel differ" with the same rel twice, so
    # its length pins rel down even when rel itself contains " and ".
    mid="${line#"Files $srcdir/"}"
    mid="${mid%" differ"}"
    n=$(((${#mid} - ${#tail}) / 2))
    rel="${mid:0:n}"
    if [ "$mid" != "$rel$tail$rel" ]; then
      ss_die "Unexpected diff output: $line" "$SS_EXIT_USAGE"
    fi
    printf '%s\n' "$rel"
  done <<<"$out"
}

# Compare SRC/<root> with <config dir>/<root> for every root on either side
# and print the changes applying SRC would make:
#
#   added:    in SRC only
#   changed:  in both, different content
#   deleted:  local only (removed by a mirror apply)
#
# Each section lists paths relative to the config dir, sorted, indented two
# spaces; a count summary follows. Returns 0 when there are no differences
# and 10 otherwise, so call it as `ss_diff "$src" || rc=$?`.
ss_diff() {
  local src="$1" cfg roots root theirs ours added="" changed="" deleted="" out
  local n_added n_changed n_deleted
  [ -d "$src" ] || ss_die "Not a directory: $src" "$SS_EXIT_USAGE"
  cfg="$(ss_config_dir)"
  roots="$(ss__union_roots "$src")"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    theirs="$(ss__list_files "$src/$root")"
    ours="$(ss__list_files "$cfg/$root")"
    out="$(comm -23 <(printf '%s\n' "$theirs") <(printf '%s\n' "$ours") | sed '/^$/d')"
    [ -z "$out" ] || added="$added$(printf '%s\n' "$out" | ss__prefix "$root")
"
    out="$(comm -13 <(printf '%s\n' "$theirs") <(printf '%s\n' "$ours") | sed '/^$/d')"
    [ -z "$out" ] || deleted="$deleted$(printf '%s\n' "$out" | ss__prefix "$root")
"
    if [ -d "$src/$root" ] && [ -d "$cfg/$root" ]; then
      out="$(ss__changed_files "$src/$root" "$cfg/$root")"
      [ -z "$out" ] || changed="$changed$(printf '%s\n' "$out" | ss__prefix "$root")
"
    fi
  done <<<"$roots"

  n_added=0 n_changed=0 n_deleted=0
  ss__print_section added "$added"
  n_added=$SS__SECTION_COUNT
  ss__print_section changed "$changed"
  n_changed=$SS__SECTION_COUNT
  ss__print_section deleted "$deleted"
  n_deleted=$SS__SECTION_COUNT
  printf '%s added, %s changed, %s deleted\n' "$n_added" "$n_changed" "$n_deleted"
  if [ $((n_added + n_changed + n_deleted)) -gt 0 ]; then
    return "$SS_DIFF_CHANGES"
  fi
}

# Prefix each line of stdin with "PREFIX/".
ss__prefix() {
  local line
  while IFS= read -r line; do
    printf '%s/%s\n' "$1" "$line"
  done
}

# Print "NAME:" and the sorted lines of LIST indented two spaces. Stores the
# line count in SS__SECTION_COUNT (a global, so no subshell is needed).
ss__print_section() {
  local name="$1" list="$2" sorted=""
  SS__SECTION_COUNT=0
  printf '%s:\n' "$name"
  if [ -n "$list" ]; then
    sorted="$(printf '%s' "$list" | sort -u)"
    SS__SECTION_COUNT=$(printf '%s\n' "$sorted" | wc -l | tr -d ' ')
    printf '%s\n' "$sorted" | sed 's/^/  /'
  fi
}

# Delete CFG/ROOT/REL, refusing anything that could resolve outside a sync
# root: an unknown root, an absolute or empty REL, or any '.' or '..'
# component.
ss__remove_in_root() {
  local cfg="$1" root="$2" rel="$3" path
  path="$cfg/$root/$rel"
  case "$root" in
    skills | projects/*/memory) ;;
    *) ss_die "Refusing to delete outside the sync roots: $path" "$SS_EXIT_USAGE" ;;
  esac
  case "/$root/" in
    */../* | */./* | *//*)
      ss_die "Refusing to delete outside the sync roots: $path" "$SS_EXIT_USAGE" ;;
  esac
  case "/$rel/" in
    // | //* | */../* | */./* | *//*)
      ss_die "Refusing to delete outside the sync roots: $path" "$SS_EXIT_USAGE" ;;
  esac
  case "$path" in
    "$cfg/$root/"?*) ;;
    *) ss_die "Refusing to delete outside the sync roots: $path" "$SS_EXIT_USAGE" ;;
  esac
  rm -f -- "$path"
}

# Delete local files under ROOT that SRC/ROOT does not have, then remove
# directories left empty. The root directory itself is kept.
ss__mirror_root() {
  local src="$1" cfg="$2" root="$3" theirs ours stale rel
  [ -d "$cfg/$root" ] || return 0
  theirs="$(ss__list_files "$src/$root")"
  ours="$(ss__list_files "$cfg/$root")"
  stale="$(comm -23 <(printf '%s\n' "$ours") <(printf '%s\n' "$theirs"))"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    ss__remove_in_root "$cfg" "$root" "$rel"
  done <<<"$stale"
  find "$cfg/$root" -mindepth 1 -type d -empty -delete
}

# Copy every root in SRC into the config dir. MODE merge adds and
# overwrites; mirror also deletes local files inside the roots that SRC does
# not have. Take a backup first (ss_backup).
ss_apply() {
  local src="$1" mode="${2:-}" cfg roots root
  case "$mode" in
    merge | mirror) ;;
    *) ss_die "ss_apply: MODE must be merge or mirror, got '$mode'" "$SS_EXIT_USAGE" ;;
  esac
  [ -d "$src" ] || ss_die "Not a directory: $src" "$SS_EXIT_USAGE"
  cfg="$(ss_config_dir)"
  roots="$(ss__union_roots "$src")"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if [ -d "$src/$root" ]; then
      ss__copy_tree "$src/$root" "$cfg/$root"
    fi
    if [ "$mode" = mirror ]; then
      ss__mirror_root "$src" "$cfg" "$root"
    fi
  done <<<"$roots"
}

# Zip the current sync set, with a manifest, as
# <state dir>/backups/<YYYYMMDD-HHMMSS>-<REASON>.zip, print its path, and
# delete all but the newest ten backups.
ss_backup() {
  local reason="$1" dir stamp zip tmp old i
  local -a all=()
  reason="$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')"
  [ -n "$reason" ] || ss_die "ss_backup: REASON is required" "$SS_EXIT_USAGE"
  ss_require_cmd zip
  dir="$(ss_state_dir)/backups"
  mkdir -p "$dir"

  # Names sort by time; wait out a same-second collision instead of
  # inventing a suffix that would break the order.
  stamp="$(date +%Y%m%d-%H%M%S)"
  while ss__glob_exists "$dir/$stamp"-*.zip; do
    sleep 1
    stamp="$(date +%Y%m%d-%H%M%S)"
  done
  zip="$dir/$stamp-$reason.zip"

  ss_tmpdir tmp
  ss_stage "$tmp/payload"
  ss_write_manifest "$tmp/payload"
  (cd "$tmp/payload" && zip -qry "$tmp/backup.zip" .)
  mv "$tmp/backup.zip" "$zip"
  rm -rf "$tmp"
  printf '%s\n' "$zip"

  for old in "$dir"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*.zip; do
    if [ -f "$old" ]; then
      all[${#all[@]}]="$old"
    fi
  done
  i=0
  while [ $((${#all[@]} - i)) -gt "$SS_BACKUP_KEEP" ]; do
    rm -f -- "${all[$i]}"
    i=$((i + 1))
  done
}

# True when the first argument (an expanded glob) names an existing path.
ss__glob_exists() {
  [ -e "$1" ]
}
