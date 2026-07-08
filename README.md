# shoop

A coding agent in pure bash. Send a prompt, watch it execute shell commands, read and write files, and search code — looping until the task is done.

```bash
shoop "add error handling to cmd/main.go"
```

```
--- shoop 20260410-185653-18845 (model: openai/gpt-5.4-mini) ---

─── turn 1/25 · 312 tokens ───
  [read_file] cmd/main.go
...

─── turn 4/25 · 1842 tokens ───
Done. Added error handling to all three entry points.

--- shoop done ---
  4 turns, 1842 tokens
```

Dependencies: `bash`, `curl`, `jq`

---

## Install

```bash
git clone https://github.com/dotcommander/shoop
cd shoop
chmod +x shoop.sh
ln -sf "$(pwd)/shoop.sh" ~/bin/shoop
```

---

## Quick Start

```bash
# Set your API key (OpenRouter, or any OpenAI-compatible provider)
export OPENROUTER_API_KEY=sk-or-...

# Run a task
shoop "refactor the auth package"

# Pipe a prompt from stdin
echo "fix the failing tests" | shoop

# Raw one-shot output for scripts
printf 'summarize this' | shoop --raw

# Use a specific model
shoop --model anthropic/claude-sonnet-4 "add input validation"

# Resume a previous session
shoop sessions                          # list saved sessions
shoop resume 20260410-185653            # resume by ID prefix
shoop resume "fix the bug"             # resume by prompt search
```

---

## Commands

| Command | Aliases | Description |
|---------|---------|-------------|
| `shoop "prompt"` | | Run a task |
| `shoop sessions` | `list`, `ls`, `history` | List saved sessions |
| `shoop resume <id> ["prompt"]` | | Resume a session (by ID, prefix, or prompt text) |
| `shoop config show` | `config print` | Print current config (API key redacted) |
| `shoop config edit` | | Open config in `$EDITOR` |
| `shoop undo` | | Revert the last checkpoint commit |
| `shoop help` | `--help`, `-h` | Show usage |
| `shoop --version` | `version` | Print version |

---

## Flags

| Flag | Description |
|------|-------------|
| `--model NAME` | Model to use |
| `--api URL` | API endpoint |
| `--key KEY` | API key (overrides config and env) |
| `--zai` | Use z.ai coding API with `ZAI_API_KEY` |
| `--raw` | Print only assistant text; useful for pipelines |
| `--no-rewrite` | Skip CRISP prompt enhancement |
| `--no-confirm` | Skip confirmation for write/replace/fetch (`run_shell` always confirms) |
| `--checkpoint` | Git-commit working tree before the agent runs |

---

## Config

On first run, shoop creates `~/.config/shoop/config`:

```bash
MODEL=openai/gpt-5.4-mini
API=https://openrouter.ai/api/v1/chat/completions
API_KEY=
MAX_TURNS=25
CONFIRM=1
REWRITE=1
FORMAT_CMD=
CHECKPOINT=0
```

Edit directly, or use `shoop config edit`.

| Key | Default | Description |
|-----|---------|-------------|
| `MODEL` | `openai/gpt-5.4-mini` | Model identifier |
| `API` | OpenRouter endpoint | Chat completions URL |
| `API_KEY` | *(empty)* | API key (stored in config) |
| `MAX_TURNS` | `25` | Maximum agent loop iterations |
| `CONFIRM` | `1` | Prompt before write/replace/fetch (`run_shell` always prompts) |
| `REWRITE` | `1` | CRISP prompt enhancement before agent loop |
| `FORMAT_CMD` | *(empty)* | Formatter run after every write (e.g. `prettier --write`) |
| `CHECKPOINT` | `0` | Git-commit working tree before each run |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `SHOOP_API_KEY` | API key (highest priority) |
| `SHOOP_CONFIRM=0` | Skip confirmation prompts |
| `SHOOP_REWRITE=0` | Skip CRISP prompt enhancement |
| `SHOOP_CHECKPOINT=1` | Enable git checkpoints |
| `OPENROUTER_API_KEY` | Fallback API key (OpenRouter) |
| `ZAI_API_KEY` | Fallback API key (z.ai) |

**API key precedence:** `SHOOP_API_KEY` > config `API_KEY` > `OPENROUTER_API_KEY` > `ZAI_API_KEY`

---

## Tools

The agent has seven tools. Read-only tools run without confirmation. Write and execution tools prompt before acting.

| Tool | Description | Confirmation |
|------|-------------|--------------|
| `run_shell` | Execute bash commands (output capped at 200 lines, timeout 1-300s) | Always |
| `read_file` | Read file contents with optional line range (capped at 200 lines) | No |
| `write_file` | Write file with diff preview, creates parent directories | Yes |
| `replace_in_file` | Surgical text replacement via exact match (first occurrence) | Yes |
| `search_files` | Grep with regex, glob filter, context lines (max 100 result lines) | No |
| `list_dir` | Directory tree with depth control 1-10 (excludes dotfiles) | No |
| `web_fetch` | Fetch URL content, converts HTML to text if `lynx`/`w3m` available | Yes |

---

## Providers

Works with any OpenAI-compatible chat completions API.

**OpenRouter** (default):

```bash
export OPENROUTER_API_KEY=sk-or-...
shoop "your prompt"
```

**z.ai:**

```bash
export ZAI_API_KEY=your-key
shoop --zai "your prompt"
```

**Any compatible API:**

```bash
shoop --api https://your-api/v1/chat/completions --key sk-... --model your-model "prompt"
```

---

## Sessions

Every tool result is saved atomically to `~/.local/share/shoop/sessions/`. If a run crashes mid-task, no progress is lost.

```bash
# List all sessions
shoop sessions

# Resume by session ID (or prefix)
shoop resume 20260410-185653

# Resume by searching prompt text
shoop resume "fix the auth bug"

# Resume with a new follow-up prompt
shoop resume 20260410-185653 "now add tests for that fix"

# Resume interactively (shows last response, prompts for input)
shoop resume 20260410-185653
```

When message history exceeds 30 messages, shoop automatically summarizes older context via the LLM to stay within token limits.

---

## Features

**CRISP Prompt Enhancement** — Before the agent loop, your prompt is rewritten by the LLM to add context, role, and structure. Disable with `--no-rewrite` or `REWRITE=0`.

**Git Checkpoints** — Run with `--checkpoint` (or `CHECKPOINT=1`) to auto-commit the working tree before the agent starts. Revert with `shoop undo`.

**Format Hooks** — Set `FORMAT_CMD` in config (e.g. `FORMAT_CMD=prettier --write`) and shoop runs it after every `write_file` and `replace_in_file`.

**Typo Detection** — Mistyped commands like `sesions` or `confi` are caught and suggest the correct command instead of burning API tokens.

**Path Security** — All file operations are sandboxed to the working directory. Symlink escapes, `.git`/`.env`/`.ssh` access, and path traversal are blocked.

---

## License

[MIT](LICENSE)
