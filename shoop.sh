#!/bin/bash
# shoop - a coding agent in bash
# usage: shoop "fix the bug in main.go"
#        shoop --resume <session-id>
#        shoop --list
#        shoop --config

set -euo pipefail

# --- config ---
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/shoop"
CONFIG="$CONFIG_DIR/config"
SESSION_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/shoop/sessions"

if [[ ! -f "$CONFIG" ]]; then
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG" <<'EOF'
MODEL=openai/gpt-5.4-mini
API=https://openrouter.ai/api/v1/chat/completions
API_KEY=
MAX_TURNS=25
CONFIRM=1
EOF
fi

# shellcheck source=/dev/null
source "$CONFIG"

# env overrides config — precedence: flag > env > config > default
MODEL="${MODEL:-openai/gpt-5.4-mini}"
API="${API:-https://openrouter.ai/api/v1/chat/completions}"
MAX_TURNS="${MAX_TURNS:-25}"
CONFIRM="${SHOOP_CONFIRM:-${CONFIRM:-1}}"
API_KEY="${SHOOP_API_KEY:-${API_KEY:-${OPENROUTER_API_KEY:-${ZAI_API_KEY:-}}}}"
if [[ -z "$API_KEY" ]]; then
  echo "error: no API key set. Use API_KEY in config, SHOOP_API_KEY, OPENROUTER_API_KEY, or ZAI_API_KEY env var." >&2
  exit 1
fi

# --- session persistence ---
mkdir -p "$SESSION_DIR"
SESSION_ID=$(date +%Y%m%d-%H%M%S)-$$

save_session() {
  local tmp
  tmp=$(mktemp "$SESSION_DIR/.tmp-XXXXXX")
  printf '%s' "$messages" > "$tmp"
  mv "$tmp" "$SESSION_DIR/$SESSION_ID.json"
}

# --- tools ---
tools='[
  {
    "type": "function",
    "function": {
      "name": "run_shell",
      "description": "Run a bash command and return stdout/stderr (first 200 lines). Result is prefixed with [exit: N].",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {"type": "string", "description": "bash command to execute"}
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "read_file",
      "description": "Read file contents (first 200 lines)",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "file path to read"}
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
      "description": "Search file contents with grep. Returns matching lines as file:line:match. Max 100 results. Use this for code exploration instead of run_shell.",
      "parameters": {
        "type": "object",
        "properties": {
          "pattern": {"type": "string", "description": "grep regex pattern"},
          "path": {"type": "string", "description": "directory to search (default: .)"},
          "include": {"type": "string", "description": "file glob filter, e.g. *.go"}
        },
        "required": ["pattern"]
      }
    }
  }
]'

system_prompt="You are a coding assistant running in a bash agent loop.
Working directory: $(pwd)
OS: $(uname -s) $(uname -m)
You have four tools: run_shell (execute bash commands), read_file (read a file), write_file (write a file), search_files (grep for patterns).
Use search_files for code exploration instead of run_shell grep. Reserve run_shell for execution and commands.
Explore the codebase before making changes. Be precise and minimal."

# --- parse flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)  MODEL="${2:?--model requires a value}"; shift 2 ;;
    --api)    API="${2:?--api requires a value}"; shift 2 ;;
    --key)    API_KEY="${2:?--key requires a value}"; shift 2 ;;
    --zai)    API="https://api.z.ai/api/coding/paas/v4/chat/completions"; API_KEY="${ZAI_API_KEY:-$API_KEY}"; shift ;;
    *)        break ;;
  esac
done

# --- subcommands ---
case "${1:-}" in
  --config)
    echo "$CONFIG"
    "${EDITOR:-vi}" "$CONFIG"
    exit 0
    ;;
  --list)
    shopt -s nullglob
    files=("$SESSION_DIR"/*.json)
    shopt -u nullglob
    if [ "${#files[@]}" -eq 0 ]; then
      echo "no sessions" >&2
      exit 0
    fi
    for f in "${files[@]}"; do
      id=$(basename "$f" .json)
      prompt=$(jq -r '.[1].content // "?"' "$f" 2>/dev/null | head -1 | cut -c1-80)
      echo "$id  $prompt"
    done
    exit 0
    ;;
  --resume)
    if [[ -z "${2:-}" ]]; then
      echo "usage: shoop --resume <session-id>" >&2
      exit 1
    fi
    session_file="$SESSION_DIR/$2.json"
    if [[ ! -f "$session_file" ]]; then
      echo "session not found: $2" >&2
      exit 1
    fi
    SESSION_ID="$2"
    messages=$(cat "$session_file")
    echo "--- shoop resumed session $SESSION_ID (model: $MODEL) ---"
    echo ""
    # fall through to the main loop
    ;;
  --help|-h)
    echo "shoop - a coding agent in bash"
    echo ""
    echo "usage:"
    echo "  shoop [flags] \"your prompt\""
    echo "  shoop --resume <id>        resume a saved session"
    echo "  shoop --list               list saved sessions"
    echo "  shoop --config             edit config file"
    echo ""
    echo "flags:"
    echo "  --model NAME   model to use (default: from config)"
    echo "  --api URL      API base URL (default: from config)"
    echo "  --key KEY      API key (default: from config/env)"
    echo "  --zai          shortcut for z.ai coding plan endpoint"
    echo ""
    echo "env: SHOOP_API_KEY, OPENROUTER_API_KEY, or ZAI_API_KEY"
    echo "     SHOOP_CONFIRM=0 (skip prompts)"
    exit 0
    ;;
  -*)
    echo "unknown flag: $1" >&2
    exit 1
    ;;
  "")
    echo "usage: shoop \"your prompt here\"" >&2
    exit 1
    ;;
  *)
    # normal prompt mode
    prompt=$(printf '%s' "$1" | jq -Rs .)
    system=$(printf '%s' "$system_prompt" | jq -Rs .)
    messages="[{\"role\":\"system\",\"content\":$system},{\"role\":\"user\",\"content\":$prompt}]"
    echo "--- shoop started session $SESSION_ID (model: $MODEL) ---"
    echo ""
    ;;
esac

# --- token tracking ---
total_tokens=0

# --- api ---
call_api() {
  local resp http_code body
  resp=$(curl -s -w '\n%{http_code}' "$API" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
      "model":"'"$MODEL"'",
      "messages":'"$messages"',
      "tools":'"$tools"',
      "parallel_tool_calls": false
    }')
  http_code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')

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

# --- helpers ---
feed_tool_result() {
  local cid="$1" res="$2"
  messages=$(printf '%s' "$messages" | jq --arg r "$res" --arg cid "$cid" \
    '. + [{"role":"tool","tool_call_id":$cid,"content":$r}]')
}

truncate_output() {
  local raw="$1" limit="${2:-200}"
  local line_count
  line_count=$(printf '%s' "$raw" | wc -l | tr -d ' ')
  if [ "$line_count" -ge "$limit" ]; then
    printf '%s\n[truncated at %s lines]' "$raw" "$limit"
  else
    printf '%s' "$raw"
  fi
}

# --- main loop ---
turn=0
while true; do
  turn=$((turn + 1))
  if [ "$turn" -gt "$MAX_TURNS" ]; then
    echo "--- shoop hit max turns ($MAX_TURNS), stopping ---" >&2
    break
  fi

  resp=$(call_api) || { echo "--- shoop aborted due to API error ---" >&2; exit 1; }

  # track tokens
  tokens=$(printf '%s' "$resp" | jq -r '.usage.total_tokens // 0')
  total_tokens=$((total_tokens + tokens))

  # extract reply text
  reply=$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty')
  if [ -n "$reply" ]; then echo "$reply"; fi

  # count tool calls
  tool_count=$(printf '%s' "$resp" | jq '.choices[0].message.tool_calls // [] | length')

  # append assistant message to history
  assistant_msg=$(printf '%s' "$resp" | jq '.choices[0].message')
  messages=$(printf '%s' "$messages" | jq --argjson m "$assistant_msg" '. + [$m]')

  # no tool calls → save and done
  if [ "$tool_count" -eq 0 ]; then
    save_session
    break
  fi

  # process all tool calls
  for ((i=0; i<tool_count; i++)); do
    tool_call=$(printf '%s' "$resp" | jq ".choices[0].message.tool_calls[$i]")
    tool_name=$(printf '%s' "$tool_call" | jq -r '.function.name')
    tool_args=$(printf '%s' "$tool_call" | jq -r '.function.arguments')
    call_id=$(printf '%s' "$tool_call" | jq -r '.id')

    echo "[$tool_name] $(printf '%s' "$tool_args" | jq -c '.')"

    # execute tool
    case "$tool_name" in
      run_shell)
        cmd=$(printf '%s' "$tool_args" | jq -r '.command')
        if [ "$CONFIRM" = "1" ]; then
          read -r -p "Execute? [y/N] " yn < /dev/tty
          if [ "$yn" != "y" ] && [ "$yn" != "Y" ]; then
            result="[user denied execution]"
            echo "$result"
            echo ""
            feed_tool_result "$call_id" "$result"
            continue
          fi
        fi
        exit_code=0
        raw=$(bash -c "$cmd" 2>&1) || exit_code=$?
        result="[exit: $exit_code]
$(truncate_output "$raw")"
        ;;

      read_file)
        path=$(printf '%s' "$tool_args" | jq -r '.path')
        raw=$(cat "$path" 2>&1) || true
        result=$(truncate_output "$raw")
        ;;

      write_file)
        path=$(printf '%s' "$tool_args" | jq -r '.path')
        content=$(printf '%s' "$tool_args" | jq -r '.content')
        mkdir -p "$(dirname "$path")"

        if [ "$CONFIRM" = "1" ]; then
          if [[ -f "$path" ]]; then
            diff -u "$path" <(printf '%s' "$content") || true
          else
            echo "[new file: $path]"
          fi
          read -r -p "Write? [y/N] " yn < /dev/tty
          if [ "$yn" != "y" ] && [ "$yn" != "Y" ]; then
            result="[user denied write]"
            echo "$result"
            echo ""
            feed_tool_result "$call_id" "$result"
            continue
          fi
        fi

        tmp=$(mktemp "$(dirname "$path")/.shoop-XXXXXX")
        printf '%s' "$content" > "$tmp"
        mv "$tmp" "$path"
        result="wrote $(wc -c < "$path" | tr -d ' ') bytes to $path"
        ;;

      search_files)
        pattern=$(printf '%s' "$tool_args" | jq -r '.pattern')
        spath=$(printf '%s' "$tool_args" | jq -r '.path // "."')
        include=$(printf '%s' "$tool_args" | jq -r '.include // ""')
        grep_args=(-r -n)
        if [[ -n "$include" ]]; then
          grep_args+=(--include="$include")
        fi
        raw=$(grep "${grep_args[@]}" -- "$pattern" "$spath" 2>&1 | head -100) || true
        result=$(truncate_output "$raw" 100)
        ;;

      *)
        result="unknown tool: $tool_name"
        ;;
    esac

    echo "$result"
    echo ""

    feed_tool_result "$call_id" "$result"
  done

  # save after tool results appended
  save_session
done

echo ""
echo "--- shoop done ($turn turns, $total_tokens tokens) ---"
