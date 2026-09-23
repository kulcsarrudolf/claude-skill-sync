#!/bin/bash
# shellcheck shell=bash
# Placeholder: print the config, or exit 2 when setup has not run.
# Issue #5 replaces this with the full status report.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  printf 'Usage: status.sh\n\nPrint the skill-sync configuration.\n'
}

case "${1:-}" in
  "") ;;
  -h | --help) usage; exit "$SS_EXIT_OK" ;;
  *) usage >&2; exit "$SS_EXIT_USAGE" ;;
esac

ss_require_config
cat "$(ss_config_file)"

ss_ci_probe() { echo $1; }
