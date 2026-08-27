#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/shoop-state-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

run_shoop() {
  env -u SHOOP_API_KEY -u OPENROUTER_API_KEY -u ZAI_API_KEY \
    HOME="$test_root/home" \
    XDG_CONFIG_HOME="$test_root/config" \
    XDG_DATA_HOME="$test_root/data" \
    "$repo_dir/shoop.sh" "$@"
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

run_shoop help >/dev/null
run_shoop --version >/dev/null

if [[ -e "$test_root/config" || -e "$test_root/data" ]]; then
  echo "informational commands initialized persistent state" >&2
  exit 1
fi

if run_shoop --no-rewrite "test first-run initialization" >/dev/null 2>&1; then
  echo "agent run without an API key unexpectedly succeeded" >&2
  exit 1
fi

config_file="$test_root/config/shoop/config"
session_dir="$test_root/data/shoop/sessions"
[[ -f "$config_file" ]] || { echo "normal run did not create config" >&2; exit 1; }
[[ -d "$session_dir" ]] || { echo "normal run did not create session directory" >&2; exit 1; }
[[ "$(file_mode "$config_file")" == 600 ]] || { echo "config mode is not 600" >&2; exit 1; }
[[ "$(file_mode "$session_dir")" == 700 ]] || { echo "session directory mode is not 700" >&2; exit 1; }
