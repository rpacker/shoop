# shoop

A minimal coding agent in pure bash. Send a prompt, watch it execute shell commands, read and write files, and search code — looping until the task is done.

```bash
shoop "add error handling to cmd/main.go"
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

## Usage

```bash
shoop "your prompt"
shoop --model anthropic/claude-sonnet-4 "refactor the auth package"
shoop --resume 20260407-203100-1234
shoop --list
shoop --config
```

**Flags**

| Flag | Description |
|------|-------------|
| `--model NAME` | Model to use |
| `--api URL` | API base URL |
| `--key KEY` | API key |
| `--zai` | Use z.ai coding plan endpoint |
| `--resume ID` | Resume a previous session |
| `--list` | List saved sessions |
| `--config` | Open config file |

---

## Config

On first run, shoop creates `~/.config/shoop/config`:

```bash
MODEL=openai/gpt-5.4-mini
API=https://openrouter.ai/api/v1/chat/completions
API_KEY=
MAX_TURNS=25
CONFIRM=1
```

Edit it directly or run `shoop --config`.

**API key precedence:** `SHOOP_API_KEY` > config `API_KEY` > `OPENROUTER_API_KEY` > `ZAI_API_KEY`

**Skip all confirmation prompts:**

```bash
SHOOP_CONFIRM=0 shoop "delete all .DS_Store files recursively"
```

---

## Tools

The agent has four tools:

| Tool | What it does |
|------|-------------|
| `run_shell` | Executes bash commands — prompts `Execute? [y/N]` first |
| `read_file` | Reads file contents (first 200 lines) |
| `write_file` | Writes files — shows diff and prompts `Write? [y/N]` for existing files |
| `search_files` | Grep wrapper for code exploration (no prompt, read-only) |

---

## Providers

Works with any OpenAI-compatible API.

**OpenRouter** (default):

```bash
export OPENROUTER_API_KEY=sk-or-...
shoop "your prompt"
```

**z.ai coding plan endpoint:**

```bash
shoop --zai "your prompt"
```

**Any compatible API:**

```bash
shoop --api https://your-api/v1/chat/completions --key your-key --model your-model "your prompt"
```

---

## Sessions

Every turn is saved atomically to `~/.local/share/shoop/sessions/<id>.json`. If a run crashes, nothing is lost.

```bash
# List sessions
shoop --list

# Resume where you left off
shoop --resume <session-id>
```

Token usage prints at the end of each run.
