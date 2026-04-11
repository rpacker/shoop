#!/bin/bash
# shoop — a coding agent in bash
# usage: shoop "fix the bug in main.go"
#        shoop resume <id-or-name> ["new prompt"]
#        shoop sessions | list | ls
#        shoop config [show|edit]
#        shoop undo

SHOOP_VERSION="0.3.1"
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
      eval "${_var}[$_i]=\"\$_line\""
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
FORMAT_CMD=
CHECKPOINT=0
EOF
  chmod 600 "$CONFIG"
fi

# migrate config: append any keys missing from older config files
_config_defaults=(REWRITE=1 FORMAT_CMD= CHECKPOINT=0)
for _kv in "${_config_defaults[@]}"; do
  _k="${_kv%%=*}"
  grep -qE "^${_k}=" "$CONFIG" 2>/dev/null || printf '%s\n' "$_kv" >> "$CONFIG"
done
unset _kv _k _config_defaults

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
    FORMAT_CMD) FORMAT_CMD="$value" ;;
    CHECKPOINT) CHECKPOINT="$value" ;;
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
FORMAT_CMD="${FORMAT_CMD:-}"
CHECKPOINT="${SHOOP_CHECKPOINT:-${CHECKPOINT:-0}}"
[[ "$CHECKPOINT" =~ ^[0-9]$ ]] || CHECKPOINT=0
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

if command -v lynx >/dev/null 2>&1; then
  _html2text() { lynx -dump -nolist; }
  HAS_HTML2TEXT=1
elif command -v w3m >/dev/null 2>&1; then
  _html2text() { w3m -dump; }
  HAS_HTML2TEXT=1
else
  HAS_HTML2TEXT=0
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
      "name": "replace_in_file",
      "description": "Replace exact text in a file. Safer and cheaper than rewriting via write_file. old_text must match exactly (including whitespace/indentation). Replaces first occurrence only.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "file path"},
          "old_text": {"type": "string", "description": "exact text to find (must exist in file)"},
          "new_text": {"type": "string", "description": "replacement text"}
        },
        "required": ["path", "old_text", "new_text"]
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
  },
  {
    "type": "function",
    "function": {
      "name": "web_fetch",
      "description": "Fetch a URL and return its text content. Use for reading documentation, issues, or API references.",
      "parameters": {
        "type": "object",
        "properties": {
          "url": {"type": "string", "description": "URL to fetch (must be http:// or https://)"}
        },
        "required": ["url"]
      }
    }
  }
]'

system_prompt="You are a coding assistant running in a bash agent loop.
Working directory: $WORKDIR
OS: $(uname -s) $(uname -m)
You have seven tools: run_shell (execute commands), read_file (read with line ranges), write_file (write a file), replace_in_file (surgical edits), search_files (grep with context), list_dir (browse directories), web_fetch (read URLs).
Prefer replace_in_file over write_file for targeted edits — it saves tokens and shows a clear diff.
Use search_files and list_dir for exploration instead of run_shell. Reserve run_shell for execution.
Prefer --dry-run or read-only commands before destructive execution.
Explore the codebase before making changes. Be precise and minimal."

# --- parse flags ---
_need_arg() { [[ -n "$2" ]] || { echo "shoop: $1 requires a value" >&2; exit 1; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)  _need_arg "$1" "${2:-}"; MODEL="$2"; shift 2 ;;
    --api)    _need_arg "$1" "${2:-}"; API="$2"; shift 2 ;;
    --key)    _need_arg "$1" "${2:-}"; API_KEY="$2"; shift 2 ;;
    --zai)    API="https://api.z.ai/api/coding/paas/v4/chat/completions"; MODEL="glm-5.1"; REWRITE_MODEL="glm-5-turbo"; API_KEY="${ZAI_API_KEY:-$API_KEY}"; shift ;;
    --no-rewrite)  REWRITE=0; shift ;;
    --no-confirm)  CONFIRM=0; shift ;;
    --checkpoint)  CHECKPOINT=1; shift ;;
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

# stdin support: read prompt from pipe when no args remain
if [[ $# -eq 0 && ! -t 0 ]]; then
  _stdin=$(cat)
  [[ -n "$_stdin" ]] && set -- "$_stdin"
fi

# die_ambiguous_sessions <query> <file...> — print matching sessions and exit 1
die_ambiguous_sessions() {
  local query=$1; shift
  echo "multiple sessions match '$query':" >&2
  local f _p
  for f in "$@"; do
    _p=$(jq -r '.[1].content // ""' "$f" 2>/dev/null | head -1 | cut -c1-60)
    printf '  %s  %s\n' "$(basename "$f" .json)" "$_p" >&2
  done
  echo "use a more specific name or ID" >&2
  exit 1
}

# find_session <query> — locate session file by exact/substring/content search; echoes path
find_session() {
  local query=$1
  # Strategy 1: exact match (with and without slug suffix)
  local exact="$SESSION_DIR/${query}.json"
  if [[ -f "$exact" ]]; then
    echo "$exact"
    return 0
  fi
  # also check slug-suffixed exact matches
  local f
  while IFS= read -r f; do
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done < <(shopt -s nullglob; printf '%s\n' "$SESSION_DIR"/*--"${query}".json)

  # Strategy 2: substring match on filename
  local matches=()
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == *"$query"* ]] && matches+=("$f")
  done < <(shopt -s nullglob; printf '%s\n' "$SESSION_DIR"/*.json)
  if (( ${#matches[@]} == 1 )); then echo "${matches[0]}"; return 0; fi
  (( ${#matches[@]} > 1 )) && die_ambiguous_sessions "$query" "${matches[@]}"

  # Strategy 3: content search (first user message)
  local _fp
  matches=()
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    _fp=$(jq -r '.[1].content // ""' "$f" 2>/dev/null)
    [[ "$_fp" == *"$query"* ]] && matches+=("$f")
  done < <(shopt -s nullglob; printf '%s\n' "$SESSION_DIR"/*.json)
  if (( ${#matches[@]} == 1 )); then echo "${matches[0]}"; return 0; fi
  (( ${#matches[@]} > 1 )) && die_ambiguous_sessions "$query" "${matches[@]}"

  echo "error: no session matching '$query'" >&2
  return 1
}

# --- subcommands ---
case "${1:-}" in
  config|--config)
    case "${2:-}" in
      show|print)
        sed 's/^\(API_KEY=\).\{1,\}$/\1***/' "$CONFIG"
        exit 0 ;;
      edit) ;;
      "")
        if [[ ! -t 1 ]]; then
          sed 's/^\(API_KEY=\).\{1,\}$/\1***/' "$CONFIG"
          exit 0
        fi ;;
      *)
        echo "usage: shoop config [show|edit]" >&2; exit 1 ;;
    esac
    echo "$CONFIG"
    "${EDITOR:-vi}" "$CONFIG"
    exit 0
    ;;
  sessions|--list|list|ls|history)
    files=()
    while IFS= read -r f; do files+=("$f"); done < <(shopt -s nullglob; printf '%s\n' "$SESSION_DIR"/*.json)
    if [ "${#files[@]}" -eq 0 ]; then
      echo "no sessions yet — start one with: shoop \"your prompt\"" >&2
      exit 0
    fi
    _seen=""
    for f in "${files[@]}"; do
      id=$(basename "$f" .json)
      ts_id="${id%%--*}"
      # deduplicate: skip if same base ID already displayed (double-slug files)
      case "$_seen" in *"|$ts_id|"*) continue ;; esac
      _seen="${_seen}|$ts_id|"
      prompt=$(jq -r '.[1].content // "?"' "$f" 2>/dev/null | head -1 | cut -c1-80)
      printf '  %-23s  %s\n' "$ts_id" "$prompt"
    done
    unset _seen
    exit 0
    ;;
  resume|--resume)
    if [[ -z "${2:-}" ]]; then
      echo "usage: shoop resume <session-id-or-name> [\"new prompt\"]" >&2
      echo "  run 'shoop sessions' to list available" >&2
      exit 1
    fi
    _sf=$(find_session "$2") || exit 1
    session_file="$_sf"
    SESSION_ID=$(basename "$session_file" .json)
    if [[ "$SESSION_ID" == *--* ]]; then
      SESSION_SLUG="${SESSION_ID#*--}"
      SESSION_ID="${SESSION_ID%%--*}"
    fi
    messages=$(cat "$session_file")
    echo "--- resumed ${SESSION_ID%%--*} (model: $MODEL) ---"
    # show last assistant message as preview
    _last=$(printf '%s' "$messages" | jq -r '[.[] | select(.role == "assistant") | .content // empty] | last // empty')
    if [[ -n "$_last" ]]; then
      _last_lines=$(printf '%s' "$_last" | wc -l | tr -d ' ')
      printf '\n  last:\n%s\n' "$(printf '%s' "$_last" | head -5)"
      (( _last_lines > 5 )) && printf '  [... %d more lines]\n' "$((_last_lines - 5))"
    fi
    # add continuation prompt — inline arg, interactive, or pipe
    if [[ -n "${3:-}" ]]; then
      _rp=$(printf '%s' "${*:3}" | jq -Rs .)
      messages=$(printf '%s' "$messages" | jq --argjson p "$_rp" '. + [{"role":"user","content":$p}]')
    elif [[ -t 0 ]]; then
      printf '\n'
      read -r -p "continue> " _rp < /dev/tty || { echo ""; exit 0; }
      if [[ -z "$_rp" ]]; then
        exit 0
      fi
      _rp=$(printf '%s' "$_rp" | jq -Rs .)
      messages=$(printf '%s' "$messages" | jq --argjson p "$_rp" '. + [{"role":"user","content":$p}]')
    fi
    echo ""
    ;;
  undo|--undo)
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "error: not in a git repository" >&2; exit 1
    fi
    if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
      echo "error: uncommitted changes would be lost by undo" >&2
      echo "  commit or stash your changes first, then retry" >&2
      exit 1
    fi
    head_msg=$(git log -1 --format="%s" 2>/dev/null)
    if [[ "$head_msg" != shoop\ checkpoint* ]]; then
      echo "error: HEAD is not a shoop checkpoint — cannot undo" >&2
      echo "  HEAD: $head_msg" >&2; exit 1
    fi
    git reset HEAD~1 --quiet
    echo "checkpoint undone — working tree restored to pre-shoop state"
    exit 0
    ;;
  version|--version)
    echo "shoop $SHOOP_VERSION"
    exit 0
    ;;
  help|--help|-h)
    cat <<HELP
shoop $SHOOP_VERSION — a coding agent in bash

usage:
  shoop [flags] "your prompt"
  echo "prompt" | shoop           read prompt from stdin
  shoop resume <id> ["prompt"]    resume a saved session
  shoop sessions                  list saved sessions
  shoop config [show|edit]        view or edit config file
  shoop undo                      revert the last shoop checkpoint commit

flags:
  --model NAME     model to use (current: $MODEL)
  --api URL        API endpoint (default: from config)
  --key KEY        API key (default: from config/env)
  --zai            use z.ai coding API with ZAI_API_KEY
  --no-rewrite     skip CRISP prompt enhancement
  --no-confirm     skip confirmation for write/replace/fetch (run_shell always confirms)
  --checkpoint     git-commit working tree before agent runs
  --version        show version

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
    # catch likely command typos — bare lowercase word resembling a known command
    if [[ "$1" =~ ^[a-z]{3,}$ ]]; then
      for _known in sessions resume config undo help; do
        _klen=${#_known}; _ilen=${#1}
        _diff=$(( _ilen - _klen )); (( _diff < 0 )) && _diff=$(( -_diff ))
        # match: truncation ("sess") OR same-first-3 within ±2 chars ("sesions")
        if [[ "${_known:0:$_ilen}" == "$1" ]] \
          || { (( _diff <= 2 )) && [[ "${_known:0:3}" == "${1:0:3}" ]]; }; then
          echo "shoop: '$1' is not a known command — did you mean '$_known'?" >&2
          echo "  to run as a prompt: shoop \"$1\"" >&2
          exit 1
        fi
      done
      unset _known _klen _ilen _diff
    fi
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

# --- git checkpoint ---
if [[ "$CHECKPOINT" = "1" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git diff --quiet HEAD 2>/dev/null; then
    if git add -u && git commit -m "shoop checkpoint $SESSION_ID" --quiet 2>/dev/null; then
      echo "  [checkpoint: committed working tree before agent run]"
    fi
  fi
fi

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
    local err_line
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

run_format_hook() {
  [[ -z "${FORMAT_CMD:-}" ]] && return 0
  local target="$1"
  if bash -c "$FORMAT_CMD \"\$1\"" _ "$target" >/dev/null 2>&1; then
    result+=$'\n'"[formatted: $FORMAT_CMD]"
  fi
}

confirm_or_skip() {
  local prompt_text="$1" deny_msg="$2"
  [[ "$CONFIRM" != "1" ]] && return 0
  if ! { true </dev/tty; } 2>/dev/null; then
    result="[$deny_msg — no terminal]"
    printf '%s\n\n' "$result"
    feed_tool_result "$call_id" "$result"
    return 1
  fi
  local yn
  read -r -p "$prompt_text " yn < /dev/tty
  [[ "$yn" == "y" || "$yn" == "Y" ]] && return 0
  result="[$deny_msg]"
  printf '%s\n\n' "$result"
  feed_tool_result "$call_id" "$result"
  return 1
}

# run_with_timeout <secs> <cmd> [args...] — run under timeout if available, else directly
run_with_timeout() {
  local secs=$1; shift
  if [[ -n "$TIMEOUT_CMD" ]]; then
    $TIMEOUT_CMD "$secs" "$@" 2>&1
  else
    "$@" 2>&1
  fi
}

# safe_write <path> <content> <call_id> — TOCTOU-safe atomic write; updates _writes
safe_write() {
  local path=$1 content=$2 call_id=$3
  local write_target; write_target=$(resolve_path "$path")
  if [[ "$write_target" != "$WORKDIR"/* && "$write_target" != "$WORKDIR" ]]; then
    reject_tool "[blocked: path escape — $path resolves outside workdir after write]"
    return 1
  fi
  local tmp; tmp=$(mktemp "$(dirname "$write_target")/.shoop-XXXXXX")
  printf '%s' "$content" > "$tmp"
  mv "$tmp" "$write_target"
  _writes="$_writes $path"
}

# trim_messages <keep> — keep system+first-user msg plus last $keep messages
trim_messages() {
  local keep=$1
  messages=$(printf '%s' "$messages" | jq --argjson k "$keep" '[.[0], .[1]] + .[-$k:]')
}

# manage_context — summarize or trim message history when window fills
manage_context() {
  local _msg_count; _msg_count=$(printf '%s' "$messages" | jq 'length')
  if (( _msg_count <= 30 )); then
    return 0
  fi

  local _keep=12 _walk=0
  # don't split tool_call/result pairs — walk back past any orphaned tool results or assistant+tool_calls
  local _boundary_role _has_tc
  while (( _walk < 10 )); do
    _boundary_role=$(printf '%s' "$messages" | jq -r ".[-$_keep].role")
    [[ "$_boundary_role" == "tool" ]] && _keep=$((_keep + 1)) && _walk=$((_walk + 1)) && continue
    _has_tc=$(printf '%s' "$messages" | jq -r ".[-$_keep] | if .tool_calls and (.tool_calls | length > 0) then \"yes\" else \"no\" end")
    [[ "$_has_tc" == "yes" ]] && _keep=$((_keep + 1)) && _walk=$((_walk + 1)) && continue
    break
  done

  # if boundary walking consumed most messages, just trim — not worth summarizing
  if (( _keep >= _msg_count - 4 )); then
    trim_messages "$_keep"
    printf '  [context: trimmed %d → %d messages]\n' "$_msg_count" "$((2 + _keep))" >&2
    return 0
  fi

  local _old_msgs; _old_msgs=$(printf '%s' "$messages" | jq -r \
    "[.[2:-$_keep][] | .role + \": \" + (.content // \"[tool call]\" | tostring)] | join(\"\\n\")" 2>/dev/null | head -c 8000)

  local _sum_payload; _sum_payload=$(jq -n \
    --arg model "${REWRITE_MODEL:-$MODEL}" \
    --arg hist "$_old_msgs" \
    '{model: $model, max_tokens: 400,
      messages: [{role: "system", content: "Summarize this agent conversation history in under 150 words. Focus on: files read/modified, key decisions made, current state of the task, what remains to do."},
                 {role: "user", content: $hist}]}')

  local _sum_resp _summary
  if _sum_resp=$(call_api "$_sum_payload" 2>/dev/null); then
    _summary=$(printf '%s' "$_sum_resp" | jq -r '.choices[0].message.content // empty')
    if [[ -n "$_summary" ]]; then
      messages=$(printf '%s' "$messages" | jq --arg s "$_summary" --argjson k "$_keep" \
        '[.[0], .[1], {"role":"system","content":("Conversation summary:\n" + $s)}] + .[-$k:]')
      printf '  [context: summarized %d → %d messages]\n' "$_msg_count" "$(printf '%s' "$messages" | jq 'length')" >&2
    else
      trim_messages "$_keep"
      printf '  [context: trimmed %d → %d messages (summary empty)]\n' "$_msg_count" "$((2 + _keep))" >&2
    fi
  else
    trim_messages "$_keep"
    printf '  [context: trimmed %d → %d messages (summary failed)]\n' "$_msg_count" "$((2 + _keep))" >&2
  fi
}

# dispatch_tool <tool_name> <tool_args_json> <call_id> — execute tool; sets $result; returns 1 if rejected
dispatch_tool() {
  local tool_name=$1 tool_args=$2 call_id=$3

  case "$tool_name" in
    run_shell)
      local cmd cmd_timeout exit_code raw yn _status
      cmd=$(printf '%s' "$tool_args" | jq -r '.command')
      cmd_timeout=$(printf '%s' "$tool_args" | jq -r '.timeout // 30')
      (( cmd_timeout < 1 )) && cmd_timeout=1
      (( cmd_timeout > 300 )) && cmd_timeout=300
      # run_shell ALWAYS requires confirmation — too dangerous to skip
      if ! { true </dev/tty; } 2>/dev/null; then
        reject_tool "[blocked: no /dev/tty — run_shell needs an interactive terminal for confirmation]"; return 1
      fi
      # destructive command warning (non-blocking signal)
      case "$cmd" in
        *rm\ -rf*|*chmod\ 777*|*curl\ *|*wget\ *|*ssh\ *|*scp\ *)
          echo "[warning: potentially destructive or network operation]" ;;
      esac
      read -r -p "Execute? [y/N] " yn < /dev/tty
      if [[ "$yn" != "y" && "$yn" != "Y" ]]; then
        reject_tool "[user denied execution]"; return 1
      fi
      exit_code=0
      raw=$(run_with_timeout "$cmd_timeout" bash -c "$cmd") || exit_code=$?
      [[ $exit_code -eq 124 ]] && raw+=$'\n[killed: exceeded '"$cmd_timeout"'s timeout]'
      _cmds=$((_cmds + 1))
      _status="ok"; [[ $exit_code -ne 0 ]] && _status="error"
      result="[$_status: exit $exit_code]
$(truncate_output "$raw")"
      ;;

    read_file)
      local path start endarg raw total _lines
      readarray -t _rf < <(printf '%s' "$tool_args" | jq -r '.path, (.start_line // 1), (.end_line // "")')
      path=${_rf[0]} start=${_rf[1]} endarg=${_rf[2]}
      if ! require_path "$path"; then return 1
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
      local path content
      path=$(printf '%s' "$tool_args" | jq -r '.path')
      require_path "$path" || return 1
      content=$(printf '%s' "$tool_args" | jq -r '.content')

      if [[ "$CONFIRM" = "1" ]]; then
        if [[ -f "$path" ]]; then
          diff -u "$path" <(printf '%s' "$content") 2>/dev/null || true
        else
          echo "[new file: $path]"
        fi
      fi
      confirm_or_skip "Write? [y/N]" "user denied write" || return 1

      mkdir -p "$(dirname "$path")"

      safe_write "$path" "$content" "$call_id" || return 1
      result="[ok] wrote $(( $(wc -c < "$path") )) bytes to $path"
      run_format_hook "$path"
      ;;

    search_files)
      local pattern spath include ctx ci raw
      pattern=$(printf '%s' "$tool_args" | jq -r '.pattern')
      readarray -t _sf < <(printf '%s' "$tool_args" | jq -r '(.path // "."), (.include // ""), (.context_lines // 0), (.case_insensitive // false)')
      spath=${_sf[0]} include=${_sf[1]} ctx=${_sf[2]} ci=${_sf[3]}
      require_path "$spath" || return 1
      local grep_args=(-r -n -E --binary-files=without-match)
      [[ -n "$include" ]] && grep_args+=(--include="$include")
      [[ "$ctx" =~ ^[0-9]+$ ]] && [[ "$ctx" -gt 0 ]] && grep_args+=(-C "$ctx")
      [[ "$ci" = "true" ]] && grep_args+=(-i)
      raw=$(grep "${grep_args[@]}" -- "$pattern" "$spath" 2>&1 | head -n 500) || true
      if [[ -z "$raw" ]]; then
        result="[ok: 0 matches]"
      else
        local _count; _count=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')
        result="[ok: $_count matches]
$(truncate_output "$raw" 100)"
      fi
      ;;

    replace_in_file)
      local path old_text new_text new_content
      path=$(printf '%s' "$tool_args" | jq -r '.path')
      require_path "$path" || return 1
      old_text=$(printf '%s' "$tool_args" | jq -r '.old_text')
      new_text=$(printf '%s' "$tool_args" | jq -r '.new_text')

      if [[ -z "$old_text" ]]; then
        result="[error: old_text must not be empty]"
      elif [[ ! -f "$path" ]]; then
        result="[error: not found — $path]"
      elif is_binary "$path"; then
        result="[error: binary file — $path]"
      else
        if ! new_content=$(jq -Rrs --arg old "$old_text" --arg new "$new_text" '
          if contains($old) then
            (index($old)) as $i |
            .[:$i] + $new + .[($i + ($old | length)):]
          else error("not found") end
        ' < "$path" 2>&1); then
          result="[error: old_text not found in $path]"
        else
          if [[ "$CONFIRM" = "1" ]]; then
            diff -u "$path" <(printf '%s' "$new_content") 2>/dev/null || true
          fi
          confirm_or_skip "Replace? [y/N]" "user denied replace" || return 1

          safe_write "$path" "$new_content" "$call_id" || return 1
          result="[ok] replaced text in $path"
          run_format_hook "$path"
        fi
      fi
      ;;

    list_dir)
      local lpath depth raw
      readarray -t _ld < <(printf '%s' "$tool_args" | jq -r '(.path // "."), (.depth // 3)')
      lpath=${_ld[0]} depth=${_ld[1]}
      require_path "$lpath" || return 1
      (( depth < 1 )) && depth=1
      (( depth > 10 )) && depth=10
      raw=$(find "$lpath" -maxdepth "$depth" -not -path '*/.*' 2>&1 | sort | head -n 500) || true
      if [[ -z "$raw" ]]; then
        result="[ok: empty directory]"
      else
        local _count; _count=$(printf '%s\n' "$raw" | wc -l | tr -d ' ')
        result="[ok: $_count entries]
$(truncate_output "$raw")"
      fi
      ;;

    web_fetch)
      local url fetch_timeout raw
      url=$(printf '%s' "$tool_args" | jq -r '.url')
      if [[ "$url" != http://* && "$url" != https://* ]]; then
        result="[error: URL must start with http:// or https://]"
      else
        confirm_or_skip "Fetch $url? [y/N]" "user denied fetch" || return 1
        fetch_timeout=15
        raw=$(run_with_timeout "$fetch_timeout" curl -sL --proto '=https,http' --max-redirs 5 --max-filesize 2097152 --max-time "$fetch_timeout" -A "shoop/$SHOOP_VERSION" "$url") || true
        if [[ -z "$raw" ]]; then
          result="[error: empty response from $url]"
        elif [[ "$HAS_HTML2TEXT" = "1" ]]; then
          raw=$(printf '%s' "$raw" | _html2text 2>/dev/null) || true
          result="[ok: fetched $url]
$(truncate_output "$raw")"
        else
          raw=$(printf '%s' "$raw" | sed 's/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&nbsp;/ /g; s/&#[0-9]*;//g' | tr -s '[:space:]' | head -n 500)
          result="[ok: fetched $url (raw — install lynx for cleaner output)]
$(truncate_output "$raw")"
        fi
      fi
      ;;

    *)
      result="[error] unknown tool: $tool_name"
      ;;
  esac
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

  # context management: summarize old messages when window fills
  manage_context

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

    _tdisp=$(printf '%s' "$tool_args" | jq -r '.command // .pattern // .path // .url // "."' 2>/dev/null | cut -c1-120)
    printf '  [%s] %s\n' "$tool_name" "$_tdisp"

    result=""
    dispatch_tool "$tool_name" "$tool_args" "$call_id" || continue

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
