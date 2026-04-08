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
while IFS='=' read -r key value; do
  key="${key%%[[:space:]]*}"
  value="${value#"${value%%[^[:space:]]*}"}"
  case "$key" in
    MODEL|API|API_KEY|MAX_TURNS|CONFIRM|REWRITE) declare "$key=$value" ;;
  esac
done < "$CONFIG"

# env overrides config — precedence: flag > env > config > default
MODEL="${MODEL:-openai/gpt-5.4-mini}"
API="${API:-https://openrouter.ai/api/v1/chat/completions}"
MAX_TURNS="${MAX_TURNS:-25}"
CONFIRM="${SHOOP_CONFIRM:-${CONFIRM:-1}}"
REWRITE="${SHOOP_REWRITE:-${REWRITE:-1}}"
API_KEY="${SHOOP_API_KEY:-${API_KEY:-${OPENROUTER_API_KEY:-${ZAI_API_KEY:-}}}}"
if [[ -z "$API_KEY" ]]; then
  echo "error: no API key set. Use API_KEY in config, SHOOP_API_KEY, OPENROUTER_API_KEY, or ZAI_API_KEY env var." >&2
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
  elif realpath -m "$p" 2>/dev/null; then
    : # output already printed
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
  # safety net: if resolve_path couldn't fully normalize .., reject
  if [[ "$resolved" == */../* || "$resolved" == */.. ]]; then
    echo "[blocked: unable to resolve path]"
    return 1
  fi
  # follow symlinks to verify the real target is also within WORKDIR
  if [[ -L "$resolved" ]]; then
    local target
    target=$(resolve_path "$(readlink "$resolved")")
    if [[ "$target" == */../* || "$target" == */.. ]]; then
      echo "[blocked: unable to resolve symlink target]"
      return 1
    fi
    if [[ "$target" != "$WORKDIR"/* && "$target" != "$WORKDIR" ]]; then
      echo "[blocked: $p is a symlink to outside working directory]"
      return 1
    fi
  fi
  [[ "$resolved" == "$WORKDIR"/* || "$resolved" == "$WORKDIR" ]] && return 0
  echo "[blocked: $p is outside working directory]"
  return 1
}

# --- session persistence ---
mkdir -p "$SESSION_DIR" && chmod 700 "$SESSION_DIR"
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
      "description": "Read file contents with line numbers. Up to 200 lines per call. Use start_line/end_line for large files.",
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
Explore the codebase before making changes. Be precise and minimal."

# --- parse flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)  MODEL="${2:?--model requires a value}"; shift 2 ;;
    --api)    API="${2:?--api requires a value}"; shift 2 ;;
    --key)    API_KEY="${2:?--key requires a value}"; shift 2 ;;
    --zai)    API="https://api.z.ai/api/coding/paas/v4/chat/completions"; API_KEY="${ZAI_API_KEY:-$API_KEY}"; shift ;;
    --no-rewrite)  REWRITE=0; shift ;;
    --no-confirm)  CONFIRM=0; shift ;;
    *)        break ;;
  esac
done

# --- prompt rewriter ---
rewrite_system='You rewrite user prompts for a coding agent using CRISP. Output ONLY the enhanced prompt — no labels, no commentary, no markdown fences.

For each missing dimension, infer and add it:
C (Context): working directory, language, domain constraints
R (Role): expertise needed (e.g. "senior Go developer")
I (Instructions): decompose into numbered steps with acceptance criteria
S (Specifications): format, constraints, output shape
P (Patterns): one concrete example of desired behavior

Rules:
- Preserve the original intent exactly — enhance clarity, do not change the ask
- No placeholders like [INSERT X] — fill everything with inferred values
- If the prompt is already specific (3+ dimensions present), make only minimal improvements
- Keep it under 200 words
- Write as a direct instruction, not a description of what a good prompt would look like'

rewrite_prompt() {
  local raw_prompt="$1"
  local payload rw_resp rw_text
  payload=$(jq -n \
    --arg model "$MODEL" \
    --arg sys "$rewrite_system" \
    --arg user "$raw_prompt" \
    '{model: $model, max_tokens: 400,
      messages: [{role: "system", content: $sys}, {role: "user", content: $user}]}')
  rw_resp=$(call_api "$payload") || return 1
  rw_text=$(printf '%s' "$rw_resp" | jq -r '.choices[0].message.content // empty')
  [[ -z "$rw_text" ]] && return 1
  printf '%s' "$rw_text"
}

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
    if [[ ! "$2" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]]; then
      echo "invalid session ID format" >&2
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
    echo "  --no-rewrite   skip CRISP prompt rewriting"
    echo "  --no-confirm   skip write_file confirmation (run_shell always confirms)"
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
    raw_input="$1"
    if [ "$REWRITE" = "1" ]; then
      if enhanced=$(rewrite_prompt "$raw_input"); then
        echo "--- prompt rewritten ---"
        printf '%s\n' "$enhanced"
        echo "---"
        echo ""
        raw_input="$enhanced"
      else
        echo "warning: prompt rewrite failed, using original prompt" >&2
      fi
    fi
    prompt=$(printf '%s' "$raw_input" | jq -Rs .)
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
  local raw="$1" limit="${2:-200}"
  [[ -z "$raw" ]] && return
  local -a lines
  mapfile -t lines <<< "$raw"
  [[ ${#lines[@]} -gt 0 && -z "${lines[-1]}" ]] && unset 'lines[-1]'
  local count=${#lines[@]}
  if (( count >= limit )); then
    local keep=$((limit / 4))
    local omitted=$((count - keep * 2))
    printf '%s\n' "${lines[@]:0:$keep}"
    printf '[... %d lines omitted ...]\n' "$omitted"
    printf '%s\n' "${lines[@]:count-keep:keep}"
  else
    printf '%s' "$raw"
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

  # parse response — batch scalar fields in one jq call
  IFS=$'\t' read -r tokens tool_count < <(printf '%s' "$resp" | jq -r '[(.usage.total_tokens // 0), (.choices[0].message.tool_calls // [] | length)] | @tsv')
  total_tokens=$((total_tokens + tokens))
  reply=$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty')
  if [ -n "$reply" ]; then printf '%s\n' "$reply"; fi
  assistant_msg=$(printf '%s' "$resp" | jq '.choices[0].message')
  messages=$(printf '%s' "$messages" | jq --argjson m "$assistant_msg" '. + [$m]')

  # no tool calls → save and done
  if [ "$tool_count" -eq 0 ]; then
    save_session
    break
  fi

  # process all tool calls
  for ((i=0; i<tool_count; i++)); do
    IFS=$'\t' read -r tool_name call_id < <(printf '%s' "$resp" | jq -r --argjson i "$i" \
      '.choices[0].message.tool_calls[$i] | [.function.name, .id] | @tsv')
    tool_args=$(printf '%s' "$resp" | jq -r --argjson i "$i" \
      '.choices[0].message.tool_calls[$i].function.arguments')

    echo "[$tool_name] $tool_args"

    # execute tool
    case "$tool_name" in
      run_shell)
        cmd=$(printf '%s' "$tool_args" | jq -r '.command')
        cmd_timeout=$(printf '%s' "$tool_args" | jq -r '.timeout // 30')
        (( cmd_timeout < 1 )) && cmd_timeout=1
        (( cmd_timeout > 300 )) && cmd_timeout=300
        # run_shell ALWAYS requires confirmation — too dangerous to skip
        if ! [[ -e /dev/tty ]]; then
          reject_tool "[blocked: run_shell requires interactive terminal]"; continue
        fi
        yn=""
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
        result="[exit: $exit_code]
$(truncate_output "$raw")"
        ;;

      read_file)
        path=$(printf '%s' "$tool_args" | jq -r '.path')
        if ! check_path "$path" >/dev/null; then
          result="[blocked: read_file restricted to working directory]"
        elif [[ ! -e "$path" ]]; then
          result="[error: file not found: $path]"
        elif [[ -f "$path" ]] && [[ "$(file -b --mime-encoding "$path" 2>/dev/null)" == "binary" ]]; then
          result="[binary file: $(file -b --mime-type "$path" 2>/dev/null), $(( $(wc -c < "$path") )) bytes]"
        else
          start=$(printf '%s' "$tool_args" | jq -r '.start_line // 1')
          endarg=$(printf '%s' "$tool_args" | jq -r '.end_line // empty')
          [[ -z "$endarg" ]] && endarg=$((start + 199))
          raw=$(awk -v s="$start" -v e="$endarg" 'NR>=s && NR<=e {printf "%d\t%s\n", NR, $0} NR>e {exit}' "$path" 2>&1) || true
          total=$(wc -l < "$path" 2>/dev/null || echo 0)
          result=$(truncate_output "$raw")
          if [[ "$total" -gt "$endarg" ]]; then
            result+=$'\n'"[file has $total lines; showing $start-$endarg. Use start_line=$((endarg + 1)) to continue]"
          fi
        fi
        ;;

      write_file)
        path=$(printf '%s' "$tool_args" | jq -r '.path')
        if ! check_path "$path" >/dev/null; then
          reject_tool "[blocked: write_file restricted to working directory]"; continue
        fi
        content=$(printf '%s' "$tool_args" | jq -r '.content')
        mkdir -p "$(dirname "$path")"

        if [[ "$CONFIRM" = "1" ]]; then
          if [[ -f "$path" ]]; then
            diff -u "$path" <(printf '%s' "$content") || true
          else
            echo "[new file: $path]"
          fi
        fi
        confirm_or_skip "Write? [y/N]" "user denied write" || continue

        tmp=$(mktemp "$(dirname "$path")/.shoop-XXXXXX")
        printf '%s' "$content" > "$tmp"
        mv "$tmp" "$path"
        result="wrote $(( $(wc -c < "$path") )) bytes to $path"
        ;;

      search_files)
        pattern=$(printf '%s' "$tool_args" | jq -r '.pattern')
        IFS=$'\t' read -r spath include ctx ci < <(printf '%s' "$tool_args" | jq -r '[(.path // "."), (.include // ""), (.context_lines // 0), (.case_insensitive // false)] | @tsv')
        if ! check_path "$spath" >/dev/null; then
          reject_tool "[blocked: search_files restricted to working directory]"; continue
        fi
        grep_args=(-r -n)
        [[ -n "$include" ]] && grep_args+=(--include="$include")
        [[ "$ctx" =~ ^[0-9]+$ ]] && [[ "$ctx" -gt 0 ]] && grep_args+=(-C "$ctx")
        [[ "$ci" = "true" ]] && grep_args+=(-i)
        raw=$(grep "${grep_args[@]}" -- "$pattern" "$spath" 2>&1) || true
        result=$(truncate_output "$raw" 100)
        ;;

      list_dir)
        IFS=$'\t' read -r lpath depth < <(printf '%s' "$tool_args" | jq -r '[(.path // "."), (.depth // 3)] | @tsv')
        if ! check_path "$lpath" >/dev/null; then
          reject_tool "[blocked: list_dir restricted to working directory]"; continue
        fi
        (( depth < 1 )) && depth=1
        (( depth > 10 )) && depth=10
        raw=$(find "$lpath" -maxdepth "$depth" -not -path '*/.*' 2>&1 | sort) || true
        result=$(truncate_output "$raw")
        ;;

      *)
        result="unknown tool: $tool_name"
        ;;
    esac

    printf '%s\n\n' "$result"

    feed_tool_result "$call_id" "$result"
  done

  # save after tool results appended
  save_session
done

echo ""
echo "--- shoop done ($turn turns, $total_tokens tokens) ---"
