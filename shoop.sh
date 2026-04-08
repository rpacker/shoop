#!/bin/bash
# shoop — a coding agent in bash
# usage: shoop "fix the bug in main.go"
#        shoop resume <id-or-name>
#        shoop sessions
#        shoop config

set -euo pipefail
for _c in jq curl awk; do command -v "$_c" >/dev/null 2>&1 || { echo "error: $_c is required" >&2; exit 1; }; done
unset _c

# --- Bash 3.2 shims (macOS) ---
(( BASH_VERSINFO[0] >= 4 )) || {
  mapfile() {
    local _t=0 _var=MAPFILE _i=0 _line
    while [[ "${1:-}" == -* ]]; do case "$1" in -t) _t=1 ;; esac; shift; done
    [[ -n "${1:-}" ]] && _var=$1
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      eval "$_var[$_i]=\"\$_line\""
      ((_i++)) || true
    done
  }
  readarray() { mapfile "$@"; }
}

# --- util ---
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | \
    sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-40
}

# --- config ---
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/shoop"
CONFIG="$CONFIG_DIR/config"
SESSION_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/shoop/sessions"

if [[ ! -f "$CONFIG" ]]; then
  mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR"
  cat > "$CONFIG" <<'EOF'
MODEL=openai/gpt-5.4-mini
API=https://openrouter.ai/api/v1/chat/completions
API_KEY=
MAX_TURNS=25
CONFIRM=1
REWRITE=1
EOF
  chmod 600 "$CONFIG"
fi

# safe config loading — only accept known KEY=VALUE, never source
while IFS='=' read -r key value || [[ -n "$key" ]]; do
  key="${key%%[[:space:]]*}"
  value="${value#"${value%%[^[:space:]]*}"}"
  value="${value%"${value##*[^[:space:]]}"}"
  case "$key" in
    MODEL) MODEL="$value" ;;
    API) API="$value" ;;
    API_KEY) API_KEY="$value" ;;
    MAX_TURNS) MAX_TURNS="$value" ;;
    CONFIRM) CONFIRM="$value" ;;
    REWRITE) REWRITE="$value" ;;
  esac
done < "$CONFIG"

# env overrides config — precedence: flag > env > config > default
MODEL="${MODEL:-openai/gpt-5.4-mini}"
API="${API:-https://openrouter.ai/api/v1/chat/completions}"
MAX_TURNS="${MAX_TURNS:-25}"
[[ "$MAX_TURNS" =~ ^[0-9]+$ ]] || MAX_TURNS=25
CONFIRM="${SHOOP_CONFIRM:-${CONFIRM:-1}}"
[[ "$CONFIRM" =~ ^[0-9]$ ]] || CONFIRM=1
REWRITE="${SHOOP_REWRITE:-${REWRITE:-1}}"
[[ "$REWRITE" =~ ^[0-9]$ ]] || REWRITE=1
API_KEY="${SHOOP_API_KEY:-${API_KEY:-${OPENROUTER_API_KEY:-${ZAI_API_KEY:-}}}}"
if [[ -z "$API_KEY" ]]; then
  echo "error: no API key found" >&2
  echo "  add API_KEY=<key> to $CONFIG" >&2
  echo "  or export SHOOP_API_KEY, OPENROUTER_API_KEY, or ZAI_API_KEY" >&2
  exit 1
fi

# --- capabilities ---
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD=gtimeout
else
  TIMEOUT_CMD=
fi

# --- path safety ---
WORKDIR=$(pwd -P)

resolve_path() {
  local p="$1"
  [[ "$p" != /* ]] && p="$WORKDIR/$p"
  if command -v grealpath >/dev/null 2>&1; then
    grealpath -m "$p"
  elif realpath -m / 2>/dev/null | grep -q /; then
    realpath -m "$p"
  else
    # portable fallback: resolve existing parent, append rest
    local dir base
    dir=$(dirname "$p")
    base=$(basename "$p")
    if [[ -d "$dir" ]]; then
      (cd "$dir" && printf '%s/%s' "$(pwd -P)" "$base")
    else
      printf '%s' "$p"
    fi
  fi
}

check_path() {
  local p="$1" resolved
  resolved=$(resolve_path "$p")
  case "$resolved" in
    */.git/*|*/.ssh/*|*/.aws/*|*/.gnupg/*|*/.env|*/.env.*)
      echo "[blocked: sensitive path — $p → $resolved]" ; return 1 ;;
  esac
  if [[ "$resolved" == */../* || "$resolved" == */.. ]]; then
    echo "[blocked: unresolvable '..' — $p → $resolved]"
    return 1
  fi
  if [[ -L "$resolved" ]]; then
    local target
    target=$(resolve_path "$(readlink "$resolved")")
    if [[ "$target" == */../* || "$target" == */.. ]]; then
      echo "[blocked: symlink unresolvable — $p → $target]"
      return 1
    fi
    if [[ "$target" != "$WORKDIR"/* && "$target" != "$WORKDIR" ]]; then
      echo "[blocked: symlink escape — $p → $target (outside $WORKDIR)]"
      return 1
    fi
  fi
  [[ "$resolved" == "$WORKDIR"/* || "$resolved" == "$WORKDIR" ]] && return 0
  echo "[blocked: path escape — $p → $resolved (outside $WORKDIR)]"
  return 1
}

require_path() {
  local msg
  msg=$(check_path "$1" 2>&1) || { reject_tool "${msg:-[blocked: path check failed]}"; return 1; }
}

is_binary() {
  local p="$1" enc
  enc=$(file -b --mime-encoding "$p" 2>/dev/null) && [[ "$enc" == "binary" ]] && return 0 || true
  enc=$(file -I "$p" 2>/dev/null) && [[ "$enc" == *"charset=binary"* ]] && return 0 || true
  return 1
}

# --- session persistence ---
mkdir -p "$SESSION_DIR" && chmod 700 "$SESSION_DIR"
SESSION_ID=$(date +%Y%m%d-%H%M%S)-$$
SESSION_SLUG=""

save_session() {
  local tmp fname="$SESSION_ID"
  [[ -n "$SESSION_SLUG" ]] && fname="${SESSION_ID}--${SESSION_SLUG}"
  tmp=$(mktemp "$SESSION_DIR/.tmp-XXXXXX")
  printf '%s' "$messages" > "$tmp"
  sync "$tmp" 2>/dev/null || true
  mv "$tmp" "$SESSION_DIR/$fname.json"
}

# --- tracking ---
_reads="" _writes="" _cmds=0

# --- tools ---
tools='[
  {
    "type": "function",
    "function": {
      "name": "run_shell",
      "description": "Run a bash command (always requires user confirmation). Returns stdout/stderr (first 200 lines), prefixed with [exit: N].",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {"type": "string", "description": "bash command to execute"},
          "timeout": {"type": "integer", "description": "max seconds (default: 30)"}
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "read_file",
      "description": "Read file contents with line numbers. Reads entire file by default. Omit start_line/end_line unless you need a specific range.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "file path to read"},
          "start_line": {"type": "integer", "description": "first line (1-indexed, default: 1)"},
          "end_line": {"type": "integer", "description": "last line (default: start_line+199)"}
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write_file",
      "description": "Write content to a file (creates parent dirs). Shows diff for existing files.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "file path to write"},
          "content": {"type": "string", "description": "file content"}
        },
        "required": ["path", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "search_files",
      "description": "Search file contents with grep. Returns file:line:match. Max 100 results.",
      "parameters": {
        "type": "object",
        "properties": {
          "pattern": {"type": "string", "description": "grep regex pattern"},
          "path": {"type": "string", "description": "directory to search (default: .)"},
          "include": {"type": "string", "description": "file glob filter, e.g. *.go"},
          "context_lines": {"type": "integer", "description": "lines of context around matches (default: 0)"},
          "case_insensitive": {"type": "boolean", "description": "case-insensitive search (default: false)"}
        },
        "required": ["pattern"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "list_dir",
      "description": "List directory contents with type indicators. No confirmation needed.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "directory to list (default: .)"},
          "depth": {"type": "integer", "description": "max depth (default: 3)"}
        }
      }
    }
  }
]'

system_prompt="You are a coding assistant running in a bash agent loop.
Working directory: $(pwd)
OS: $(uname -s) $(uname -m)
You have five tools: run_shell (execute commands), read_file (read with line ranges), write_file (write a file), search_files (grep with context), list_dir (browse directories).
Use search_files and list_dir for exploration instead of run_shell. Reserve run_shell for execution.
Prefer --dry-run or read-only commands before destructive execution.
Explore the codebase before making changes. Be precise and minimal."

# --- parse flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)  MODEL="${2:?--model requires a value}"; shift 2 ;;
    --api)    API="${2:?--api requires a value}"; shift 2 ;;
    --key)    API_KEY="${2:?--key requires a value}"; shift 2 ;;
    --zai)    API="https://api.z.ai/api/coding/paas/v4/chat/completions"; MODEL="glm-5.1"; REWRITE_MODEL="glm-5-turbo"; API_KEY="${ZAI_API_KEY:-$API_KEY}"; shift ;;
    --no-rewrite)  REWRITE=0; shift ;;
    --no-confirm)  CONFIRM=0; shift ;;
    *)        break ;;
  esac
done

# --- api ---
call_api() {
  local payload="$1" resp http_code body auth_file
  auth_file=$(mktemp)
  trap 'rm -f "$auth_file"' RETURN
  printf 'Authorization: Bearer %s' "$API_KEY" > "$auth_file"
  resp=$(curl -s -w '\n%{http_code}' "$API" \
    -H @"$auth_file" \
    -H "Content-Type: application/json" \
    -d "$payload")
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'"$http_code"}"

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "API error (HTTP $http_code): $body" >&2
    return 1
  fi

  local api_error
  api_error=$(printf '%s' "$body" | jq -r '.error.message // empty')
  if [ -n "$api_error" ]; then
    echo "API error: $api_error" >&2
    return 1
  fi

  printf '%s' "$body"
}

# --- prompt rewriter ---
rewrite_system='You rewrite user prompts for a coding agent using CRISP constraints (Context, Role, Instructions, Specs, Patterns). Enhance clarity but preserve intent perfectly. Under 200 words. Output ONLY the rewritten prompt.'

rewrite_prompt() {
  local raw_prompt="$1"
  local payload rw_resp rw_text rw_err
  local rw_model="${REWRITE_MODEL:-$MODEL}"
  payload=$(jq -n \
    --arg model "$rw_model" \
    --arg sys "$rewrite_system" \
    --arg user "$raw_prompt" \
    '{model: $model, max_tokens: 1200,
      messages: [{role: "system", content: $sys}, {role: "user", content: $user}]}')
  rw_err=$(mktemp)
  rw_resp=$(call_api "$payload" 2>"$rw_err") || { cat "$rw_err" >&2; rm -f "$rw_err"; return 1; }
  rm -f "$rw_err"
  rw_text=$(printf '%s' "$rw_resp" | jq -r '.choices[0].message.content // empty')
  if [[ -z "$rw_text" ]]; then
    echo "rewrite: empty response from API" >&2
    return 1
  fi
  printf '%s' "$rw_text"
}

# --- subcommands ---
case "${1:-}" in
  config|--config)
    echo "$CONFIG"
    "${EDITOR:-vi}" "$CONFIG"
    exit 0
    ;;
  sessions|--list)
    shopt -s nullglob
    files=("$SESSION_DIR"/*.json)
    shopt -u nullglob
    if [ "${#files[@]}" -eq 0 ]; then
      echo "no sessions yet — start one with: shoop \"your prompt\"" >&2
      exit 0
    fi
    for f in "${files[@]}"; do
      id=$(basename "$f" .json)
      prompt=$(jq -r '.[1].content // "?"' "$f" 2>/dev/null | head -1 | cut -c1-80)
      printf '  %s  %s\n' "$id" "$prompt"
    done
    exit 0
    ;;
  resume|--resume)
    if [[ -z "${2:-}" ]]; then
      echo "usage: shoop resume <session-id-or-name>" >&2
      echo "  run 'shoop sessions' to list available" >&2
      exit 1
    fi
    session_file=""
    # try exact match (with and without slug suffix)
    shopt -s nullglob
    exact=("$SESSION_DIR/$2.json" "$SESSION_DIR"/*--"$2".json)
    shopt -u nullglob
    for f in "${exact[@]}"; do
      [[ -f "$f" ]] && { session_file="$f"; break; }
    done
    # then try substring match
    if [[ -z "$session_file" ]]; then
      shopt -s nullglob
      matches=("$SESSION_DIR"/*"$2"*.json)
      shopt -u nullglob
      if [[ ${#matches[@]} -eq 1 ]]; then
        session_file="${matches[0]}"
      elif [[ ${#matches[@]} -gt 1 ]]; then
        echo "multiple sessions match '$2':" >&2
        for f in "${matches[@]}"; do printf '  %s\n' "$(basename "$f" .json)" >&2; done
        echo "use a more specific name or the full session ID" >&2
        exit 1
      fi
    fi
    if [[ -z "$session_file" ]]; then
      echo "no session matches '$2' — run 'shoop sessions' to list available" >&2
      exit 1
    fi
    SESSION_ID=$(basename "$session_file" .json)
    [[ "$SESSION_ID" == *--* ]] && SESSION_SLUG="${SESSION_ID#*--}"
    messages=$(cat "$session_file")
    echo "--- resumed $SESSION_ID (model: $MODEL) ---"
    echo ""
    ;;
  help|--help|-h)
    cat <<'HELP'
shoop — a coding agent in bash

usage:
  shoop [flags] "your prompt"
  shoop resume <id-or-name>    resume a saved session
  shoop sessions               list saved sessions
  shoop config                 edit config file

flags:
  --model NAME     model to use (default: from config)
  --api URL        API endpoint (default: from config)
  --key KEY        API key (default: from config/env)
  --zai            use z.ai coding API with ZAI_API_KEY
  --no-rewrite     skip CRISP prompt enhancement
  --no-confirm     skip write_file confirmation (run_shell always confirms)

api keys (checked in order):
  SHOOP_API_KEY > config API_KEY > OPENROUTER_API_KEY > ZAI_API_KEY
HELP
    exit 0
    ;;
  -*)
    echo "unknown flag: $1 — run 'shoop help' for usage" >&2
    exit 1
    ;;
  "")
    echo "usage: shoop \"your prompt\" — run 'shoop help' for more" >&2
    exit 1
    ;;
  *)
    raw_input="$1"
    SESSION_SLUG=$(slugify "$raw_input")
    if [ "$REWRITE" = "1" ]; then
      if enhanced=$(rewrite_prompt "$raw_input"); then
        printf '\033[2m%s\033[0m\n' "$raw_input"
        printf '  ↓ rewritten ↓\n'
        printf '%s\n\n' "$enhanced"
        raw_input="$enhanced"
      else
        echo "note: prompt rewrite failed, using original" >&2
      fi
    fi
    prompt=$(printf '%s' "$raw_input" | jq -Rs .)
    system=$(printf '%s' "$system_prompt" | jq -Rs .)
    messages="[{\"role\":\"system\",\"content\":$system},{\"role\":\"user\",\"content\":$prompt}]"
    echo "--- shoop $SESSION_ID (model: $MODEL) ---"
    echo ""
    ;;
esac

# --- token tracking ---
total_tokens=0

# --- helpers ---
feed_tool_result() {
  local cid="$1" res="$2"
  messages=$(printf '%s' "$messages" | jq --arg r "$res" --arg cid "$cid" \
    '. + [{"role":"tool","tool_call_id":$cid,"content":$r}]')
}

reject_tool() {
  result="$1"
  printf '%s\n\n' "$result"
  feed_tool_result "$call_id" "$result"
}

truncate_output() {
  local raw="$1" limit="${2:-200}" count keep omitted
  [[ -z "$raw" ]] && return
  count=$(printf '%s\n' "$raw" | awk 'END {print NR}')
  if (( count > limit )); then
    keep=$((limit / 4))
    omitted=$((count - keep * 2))
    printf '%s\n' "$raw" | head -n "$keep"
    # inject first error signal from the omitted region
    local err_line err_num
    err_line=$(printf '%s\n' "$raw" | awk -v s="$((keep+1))" -v e="$((count-keep))" \
      'NR>=s && NR<=e && /[Ee]rror|[Ff]ail|[Pp]anic|fatal/ {print NR": "$0; exit}')
    if [[ -n "$err_line" ]]; then
      printf '\n[... %d lines omitted; first error in gap: %s ...]\n\n' "$omitted" "$err_line"
    else
      printf '\n[... %d lines omitted ...]\n\n' "$omitted"
    fi
    printf '%s\n' "$raw" | tail -n "$keep"
  else
    printf '%s\n' "$raw"
  fi
}

confirm_or_skip() {
  local prompt_text="$1" deny_msg="$2"
  [[ "$CONFIRM" != "1" ]] && return 0
  local yn
  read -r -p "$prompt_text " yn < /dev/tty
  [[ "$yn" == "y" || "$yn" == "Y" ]] && return 0
  result="[$deny_msg]"
  printf '%s\n\n' "$result"
  feed_tool_result "$call_id" "$result"
  return 1
}

# --- main loop ---
turn=0
while true; do
  turn=$((turn + 1))
  if [ "$turn" -gt "$MAX_TURNS" ]; then
    echo "--- shoop hit max turns ($MAX_TURNS), stopping ---" >&2
    break
  fi

  payload=$(jq -n \
    --arg model "$MODEL" \
    --argjson messages "$messages" \
    --argjson tools "$tools" \
    '{model: $model, messages: $messages, tools: $tools, parallel_tool_calls: false}')
  resp=$(call_api "$payload") || { echo "--- shoop aborted due to API error ---" >&2; exit 1; }

  # parse response — use \x1f sentinel to avoid newline splitting multi-line content
  _raw_parse=$(printf '%s' "$resp" | jq -r '
    .choices[0].message as $m |
    [(.usage.total_tokens // 0),
     ($m.tool_calls // [] | length),
     ($m.content // ""),
     ($m | @json)] | join("\u001f")
  ')
  if [[ -z "$_raw_parse" || "$_raw_parse" != *$'\x1f'* ]]; then
    echo "error: failed to parse API response" >&2
    echo "$resp" >&2
    exit 1
  fi
  IFS=$'\x1f' read -d '' -r _tok _tc _content _json _rest <<< "$_raw_parse" || true
  total_tokens=$((total_tokens + _tok))
  tool_count=$_tc
  printf '\n─── turn %d/%s · %s tokens ───\n' "$turn" "$MAX_TURNS" "$total_tokens"
  [[ -n "$_content" ]] && printf '%s\n' "$_content"
  messages=$(printf '%s' "$messages" | jq --argjson m "$_json" '. + [$m]')

  # sliding window: keep system + first user + last 20 messages
  _msg_count=$(printf '%s' "$messages" | jq 'length')
  if (( _msg_count > 30 )); then
    messages=$(printf '%s' "$messages" | jq '[.[0], .[1]] + .[-20:]')
    printf '  [context: trimmed %d → %d messages]\n' "$_msg_count" "$((2 + 20))" >&2
  fi

  # no tool calls → save and done
  if [ "$tool_count" -eq 0 ]; then
    save_session
    break
  fi

  # process all tool calls
  for ((i=0; i<tool_count; i++)); do
    _raw_tool=$(printf '%s' "$resp" | jq -r --argjson i "$i" '
      .choices[0].message.tool_calls[$i] |
      [.function.name, .id, .function.arguments] | join("\u001f")
    ')
    IFS=$'\x1f' read -d '' -r tool_name call_id tool_args _rest <<< "$_raw_tool" || true

    _tdisp=$(printf '%s' "$tool_args" | jq -r '.command // .pattern // .path // "."' 2>/dev/null | cut -c1-120)
    printf '  [%s] %s\n' "$tool_name" "$_tdisp"

    # execute tool
    case "$tool_name" in
      run_shell)
        cmd=$(printf '%s' "$tool_args" | jq -r '.command')
        cmd_timeout=$(printf '%s' "$tool_args" | jq -r '.timeout // 30')
        (( cmd_timeout < 1 )) && cmd_timeout=1
        (( cmd_timeout > 300 )) && cmd_timeout=300
        # run_shell ALWAYS requires confirmation — too dangerous to skip
        if ! [[ -e /dev/tty ]]; then
          reject_tool "[blocked: no /dev/tty — run_shell needs an interactive terminal for confirmation]"; continue
        fi
        # destructive command warning (non-blocking signal)
        case "$cmd" in
          *rm\ -rf*|*chmod\ 777*|*curl\ *|*wget\ *|*ssh\ *|*scp\ *)
            echo "[warning: potentially destructive or network operation]" ;;
        esac
        read -r -p "Execute? [y/N] " yn < /dev/tty
        if [[ "$yn" != "y" && "$yn" != "Y" ]]; then
          reject_tool "[user denied execution]"; continue
        fi
        exit_code=0
        if [[ -n "$TIMEOUT_CMD" ]]; then
          raw=$($TIMEOUT_CMD "$cmd_timeout" bash -c "$cmd" 2>&1) || exit_code=$?
        else
          raw=$(bash -c "$cmd" 2>&1) || exit_code=$?
        fi
        [[ $exit_code -eq 124 ]] && raw+=$'\n[killed: exceeded '"$cmd_timeout"'s timeout]'
        _cmds=$((_cmds + 1))
        _status="ok"; [[ $exit_code -ne 0 ]] && _status="error"
        result="[$_status: exit $exit_code]
$(truncate_output "$raw")"
        ;;

      read_file)
        readarray -t _rf < <(printf '%s' "$tool_args" | jq -r '.path, (.start_line // 1), (.end_line // "")')
        path=${_rf[0]} start=${_rf[1]} endarg=${_rf[2]}
        if ! require_path "$path"; then continue
        elif [[ ! -e "$path" ]]; then
          result="[error: not found — $path]"
        elif [[ -f "$path" ]] && is_binary "$path"; then
          result="[ok: binary — $(file -b "$path" 2>/dev/null | cut -c1-60), $(( $(wc -c < "$path") )) bytes]"
        else
          [[ -z "$endarg" ]] && endarg=9999
          raw=$(awk -v s="$start" -v e="$endarg" 'NR>=s && NR<=e {printf "%d\t%s\n", NR, $0} NR>e {exit}' "$path" 2>&1) || true
          total=$(wc -l < "$path" 2>/dev/null | awk '{print $1}' || echo 0)
          _lines=$(printf '%s' "$raw" | grep -c '' 2>/dev/null || echo 0)
          result="[ok: $_lines lines]
$(truncate_output "$raw")"
          if [[ "$total" -gt "$endarg" ]]; then
            result+=$'\n'"[file has $total lines; showing $start-$endarg — use start_line=$((endarg + 1)) to continue]"
          fi
          _reads="$_reads $path"
        fi
        ;;

      write_file)
        path=$(printf '%s' "$tool_args" | jq -r '.path')
        require_path "$path" || continue
        content=$(printf '%s' "$tool_args" | jq -r '.content')

        if [[ "$CONFIRM" = "1" ]]; then
          if [[ -f "$path" ]]; then
            diff -u "$path" <(printf '%s' "$content") 2>/dev/null || true
          else
            echo "[new file: $path]"
          fi
        fi
        confirm_or_skip "Write? [y/N]" "user denied write" || continue

        mkdir -p "$(dirname "$path")"

        # TOCTOU guard: re-resolve and verify immediately before write
        write_target=$(resolve_path "$path")
        if [[ "$write_target" != "$WORKDIR"/* && "$write_target" != "$WORKDIR" ]]; then
          reject_tool "[blocked: path changed outside working directory before write]"
          continue
        fi

        tmp=$(mktemp "$(dirname "$write_target")/.shoop-XXXXXX")
        printf '%s' "$content" > "$tmp"
        mv "$tmp" "$write_target"
        _writes="$_writes $path"
        result="[ok] wrote $(( $(wc -c < "$path") )) bytes to $path"
        ;;

      search_files)
        pattern=$(printf '%s' "$tool_args" | jq -r '.pattern')
        readarray -t _sf < <(printf '%s' "$tool_args" | jq -r '(.path // "."), (.include // ""), (.context_lines // 0), (.case_insensitive // false)')
        spath=${_sf[0]} include=${_sf[1]} ctx=${_sf[2]} ci=${_sf[3]}
        require_path "$spath" || continue
        grep_args=(-r -n -E --binary-files=without-match)
        [[ -n "$include" ]] && grep_args+=(--include="$include")
        [[ "$ctx" =~ ^[0-9]+$ ]] && [[ "$ctx" -gt 0 ]] && grep_args+=(-C "$ctx")
        [[ "$ci" = "true" ]] && grep_args+=(-i)
        raw=$(grep "${grep_args[@]}" -- "$pattern" "$spath" 2>&1 | head -n 500) || true
        if [[ -z "$raw" ]]; then
          result="[ok: 0 matches]"
        else
          _count=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')
          result="[ok: $_count matches]
$(truncate_output "$raw" 100)"
        fi
        ;;

      list_dir)
        readarray -t _ld < <(printf '%s' "$tool_args" | jq -r '(.path // "."), (.depth // 3)')
        lpath=${_ld[0]} depth=${_ld[1]}
        require_path "$lpath" || continue
        (( depth < 1 )) && depth=1
        (( depth > 10 )) && depth=10
        raw=$(find "$lpath" -maxdepth "$depth" -not -path '*/.*' 2>&1 | sort | head -n 500) || true
        if [[ -z "$raw" ]]; then
          result="[ok: empty directory]"
        else
          _count=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')
          result="[ok: $_count entries]
$(truncate_output "$raw")"
        fi
        ;;

      *)
        result="[error] unknown tool: $tool_name"
        ;;
    esac

    printf '%s\n\n' "$result"

    feed_tool_result "$call_id" "$result"
  done

  # save after tool results appended
  save_session
done

echo ""
echo "--- shoop done ---"
printf '  %d turns, %s tokens\n' "$turn" "$total_tokens"
[[ -n "$_reads" ]] && printf '  read:%s\n' "$_reads"
[[ -n "$_writes" ]] && printf '  wrote:%s\n' "$_writes"
[[ $_cmds -gt 0 ]] && printf '  ran: %d commands\n' "$_cmds"
