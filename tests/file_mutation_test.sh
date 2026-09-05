#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/shoop-file-mutation-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/workspace"
payload_log="$test_root/payloads.jsonl"
curl_count="$test_root/curl-count"
format_log="$test_root/format.log"
# shellcheck disable=SC2016 # $1 and SHOOP_FORMAT_LOG are expanded by run_format_hook.
format_cmd='printf "\\nformatted" >> "$1"; printf "%s\n" "$1" >> "$SHOOP_FORMAT_LOG"; :'

cat > "$test_root/bin/curl" <<'FAKE_CURL'
#!/bin/bash
set -euo pipefail

payload=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) payload=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$payload" >> "$SHOOP_FAKE_PAYLOAD_LOG"

count=0
[[ -f "$SHOOP_FAKE_CURL_COUNT" ]] && count=$(cat "$SHOOP_FAKE_CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$SHOOP_FAKE_CURL_COUNT"

case "${SHOOP_FAKE_SCENARIO:-success}:$count" in
  success:1)
    cat <<'JSON'
{"choices":[{"message":{"content":"","tool_calls":[{"id":"write-call","type":"function","function":{"name":"write_file","arguments":"{\"path\":\"nested/file.txt\",\"content\":\"alpha alpha\"}"}},{"id":"replace-call","type":"function","function":{"name":"replace_in_file","arguments":"{\"path\":\"nested/file.txt\",\"old_text\":\"alpha\",\"new_text\":\"beta\"}"}}]},"usage":{"total_tokens":1}}]}
JSON
    ;;
  denial:1)
    cat <<'JSON'
{"choices":[{"message":{"content":"","tool_calls":[{"id":"denied-write","type":"function","function":{"name":"write_file","arguments":"{\"path\":\"denied/file.txt\",\"content\":\"not written\"}"}}]},"usage":{"total_tokens":1}}]}
JSON
    ;;
  mkdir-failure:1)
    cat <<'JSON'
{"choices":[{"message":{"content":"","tool_calls":[{"id":"mkdir-failure-write","type":"function","function":{"name":"write_file","arguments":"{\"path\":\"blocker/child.txt\",\"content\":\"not written\"}"}}]},"usage":{"total_tokens":1}}]}
JSON
    ;;
  mixed:1)
    cat <<'JSON'
{"choices":[{"message":{"content":"","tool_calls":[{"id":"mixed-write","type":"function","function":{"name":"write_file","arguments":"{\"path\":\"mixed-blocker/child.txt\",\"content\":\"not written\"}"}},{"id":"mixed-read","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"mixed-read.txt\"}"}}]},"usage":{"total_tokens":1}}]}
JSON
    ;;
  *:2)
    cat <<'JSON'
{"choices":[{"message":{"content":"done","tool_calls":[]},"usage":{"total_tokens":1}}]}
JSON
    ;;
  *)
    echo "unexpected fake curl call: $count" >&2
    exit 1
    ;;
esac
printf '200\n'
FAKE_CURL
chmod +x "$test_root/bin/curl"

run_shoop() {
  local scenario=$1
  local script_command
  (
    cd "$test_root/workspace"
    export HOME="$test_root/home" XDG_CONFIG_HOME="$test_root/config" XDG_DATA_HOME="$test_root/data"
    export PATH="$test_root/bin:$PATH" SHOOP_API_KEY=test-key FORMAT_CMD="$format_cmd"
    export SHOOP_FAKE_SCENARIO="$scenario" SHOOP_FAKE_PAYLOAD_LOG="$payload_log" SHOOP_FAKE_CURL_COUNT="$curl_count" SHOOP_FORMAT_LOG="$format_log"
    if [[ "$scenario" = "denial" ]]; then
      case "$(uname -s)" in
        Darwin)
          printf 'n\n' | script -q /dev/null "$repo_dir/shoop.sh" --no-rewrite "exercise file mutations"
          ;;
        *)
          printf -v script_command '%q ' "$repo_dir/shoop.sh" --no-rewrite "exercise file mutations"
          printf 'n\n' | script -q -c "$script_command" /dev/null
          ;;
      esac
    else
      "$repo_dir/shoop.sh" --no-confirm --no-rewrite "exercise file mutations"
    fi
  )
}

assert_tool_result() {
  local log=$1 expected_call_id=$2 expected_content=$3
  if ! jq -se --arg call_id "$expected_call_id" --arg content "$expected_content" '
    [ .[] | .messages[]? | select(.tool_call_id? == $call_id) ] |
    length == 1 and .[0].role == "tool" and .[0].content == $content
  ' "$log" >/dev/null; then
    echo "unexpected tool result for $expected_call_id" >&2
    exit 1
  fi
}

assert_ordered_tool_results() {
  local log=$1 first_id=$2 first_content=$3 second_id=$4 second_content=$5
  if ! jq -se --arg first_id "$first_id" --arg first_content "$first_content" --arg second_id "$second_id" --arg second_content "$second_content" '
    ([ .[] |
       [ .messages[]? | select(.tool_call_id? == $first_id or .tool_call_id? == $second_id) ] |
       select(length > 0)
    ]) as $batches |
    (length == 2) and
    ($batches | length == 1) and
    ($batches[0] | length == 2) and
    ($batches[0][0].role == "tool") and
    ($batches[0][0].tool_call_id == $first_id) and
    ($batches[0][0].content == $first_content) and
    ($batches[0][1].role == "tool") and
    ($batches[0][1].tool_call_id == $second_id) and
    ($batches[0][1].content == $second_content)
  ' "$log" >/dev/null; then
    echo "unexpected ordered tool results for $first_id and $second_id" >&2
    exit 1
  fi
}

payload_log="$test_root/success-payloads.jsonl"
curl_count="$test_root/success-curl-count"
format_log="$test_root/success-format.log"
run_shoop success >/dev/null

target="$test_root/workspace/nested/file.txt"
[[ -f "$target" ]] || { echo "write_file did not create nested target" >&2; exit 1; }
[[ "$(cat "$target")" == $'beta alpha\nformatted\nformatted' ]] || {
  echo "unexpected final file contents" >&2
  exit 1
}
assert_tool_result "$payload_log" write-call "[ok] wrote 11 bytes to nested/file.txt
[formatted: $format_cmd]"
assert_tool_result "$payload_log" replace-call "[ok] replaced text in nested/file.txt
[formatted: $format_cmd]"
[[ -f "$format_log" ]] || {
  echo "format hook did not record successful mutations" >&2
  exit 1
}
[[ "$(cat "$format_log")" == $'nested/file.txt\nnested/file.txt' ]] || {
  echo "format hook did not run exactly once per successful mutation" >&2
  exit 1
}

payload_log="$test_root/denial-payloads.jsonl"
curl_count="$test_root/denial-curl-count"
format_log="$test_root/denial-format.log"
denial_output=$(run_shoop denial)
[[ "$denial_output" == *'[new file: denied/file.txt]'* ]] || {
  echo "normal-mode denial did not show the new-file preview on stdout" >&2
  exit 1
}
[[ "$denial_output" == *'[user denied write]'* ]] || {
  echo "explicit write denial was not shown" >&2
  exit 1
}
assert_tool_result "$payload_log" denied-write '[user denied write]'
[[ ! -e "$format_log" ]] || {
  echo "format hook ran after a denied write" >&2
  exit 1
}
[[ ! -e "$test_root/workspace/denied/file.txt" ]] || {
  echo "denied write created a file" >&2
  exit 1
}

printf 'blocker' > "$test_root/workspace/blocker"
payload_log="$test_root/mkdir-failure-payloads.jsonl"
curl_count="$test_root/mkdir-failure-curl-count"
format_log="$test_root/mkdir-failure-format.log"
run_shoop mkdir-failure >/dev/null
assert_tool_result "$payload_log" mkdir-failure-write '[error: unable to create parent directory for blocker/child.txt]'
[[ ! -e "$format_log" ]] || {
  echo "format hook ran after parent creation failure" >&2
  exit 1
}
[[ ! -e "$test_root/workspace/blocker/child.txt" ]] || {
  echo "parent creation failure created a target" >&2
  exit 1
}
[[ "$(cat "$test_root/workspace/blocker")" == blocker ]] || {
  echo "parent creation failure changed the blocker" >&2
  exit 1
}

printf 'blocker' > "$test_root/workspace/mixed-blocker"
printf 'ready' > "$test_root/workspace/mixed-read.txt"
payload_log="$test_root/mixed-payloads.jsonl"
curl_count="$test_root/mixed-curl-count"
format_log="$test_root/mixed-format.log"
run_shoop mixed >/dev/null
assert_ordered_tool_results "$payload_log" mixed-write '[error: unable to create parent directory for mixed-blocker/child.txt]' mixed-read $'[ok: 1 lines]\n1\tready'
[[ ! -e "$format_log" ]] || {
  echo "format hook ran after the failed mixed mutation" >&2
  exit 1
}
