# fanout.sh

Multi-agent task fan-out coordinator for [herdr](https://herdr.dev). Dispatches concurrent subtasks to agent panes, waits for completion, detects provider errors, and retries automatically.

## What it does

herdr runs each agent in its own terminal pane. `fanout.sh` lets you:

1. **Send tasks** to multiple agents simultaneously
2. **Wait for all** to finish (using `state_change_seq` tracking to catch fast completions)
3. **Detect errors** (provider failures, rate limits, timeouts) in the current run only
4. **Retry** failed agents automatically (up to N retries per agent)
5. **Collect results** tagged by agent name

No hardcoded agent names — configure your own via `~/.config/fanout/agents.conf`.

## Requirements

- `bash` 4+
- `herdr` (with agents running in panes)
- `python3` (for JSON parsing)
- `awk`, `grep` (standard)

## Install

```bash
git clone https://github.com/YOUR_USER/herdr-coordinator.git
cd herdr-coordinator
ln -s "$PWD/bin/fanout.sh" ~/.local/bin/fanout  # optional: make it a PATH command
```

## Configuration

Create `~/.config/fanout/agents.conf`:

```
# agent_name = pane_id
goose = w1:p1J
crush = w1:p1K
```

Pane ids change on herdr restart. Re-discover with:

```bash
fanout agents        # list all agents from herdr
fanout pane-of goose # resolve one agent's current pane id
```

Override the config path with `FANOUT_CONFIG=/path/to/file`.

## Usage

### Fan out tasks to two agents

```bash
fanout fanout \
  -a goose -t "What is the capital of France?" \
  -a crush -t "What is 6 * 7?"
```

Output:
```
fanout: goose=w1:p1J  crush=w1:p1K  (marker=FANOUT.1725400000.12345)
[ok] crush finished
[ok] goose finished
--- results ---
[goose] Paris FANOUT.1725400000.12345
[crush] 42 FANOUT.1725400000.12345
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-a, --agent NAME` | (required) | Agent name (repeat for each) |
| `-t, --task TEXT` | (required) | Task text (repeat, matched by position) |
| `-m, --marker TEXT` | `FANOUT` | Completion marker prefix |
| `-r, --retries N` | `5` | Max retries per agent on provider error |
| `-p, --polls N` | `30` | Max completion polls |
| `-d, --delay SECS` | `1` | Seconds between polls |

### Other commands

```bash
fanout agents              # list all agents
fanout status [AGENT]      # agent state + pane info
fanout read <pane> [LINES] # tail pane output
fanout send <pane> "text"  # send text + Enter
fanout pane-of <agent>     # resolve name → pane id
fanout worktree            # list herdr worktrees
```

## How completion detection works

Each agent pane is a TUI that reports its state to herdr via integration hooks. When an agent processes a task, its `state_change_seq` increments. `fanout.sh` captures this sequence number before dispatching, then polls until it detects the increment — even if the agent completes so fast that the `working` state is never observed between polls.

## Error detection

After all agents finish, `fanout.sh` checks each pane for provider/API errors (e.g. `Provider returned error`, HTTP 5xx, rate limits) **only in output after the current marker** — stale errors from previous runs in scrollback are ignored. If errors are found, the affected agent's task is re-sent and re-waited, up to `--retries` times.

## Use case: opencode + goose + crush

This was built for a dev session running three AI coding agents in herdr:

- **opencode** (coordinator) — splits work and dispatches via `fanout.sh`
- **goose** — routed through a local [LiteLLM](https://github.com/BerriAI/litellm) proxy to Gemini
- **crush** — routed through [OpenRouter](https://openrouter.ai) (MiniMax M3 Free)

The coordinator (opencode) runs `fanout.sh` to send subtasks to goose and crush concurrently, waits for both to finish, reads their pane outputs, and merges the results.

### Setup

```bash
# 1. Install herdr and start a dev session
herdr --session dev

# 2. In herdr, launch agents in separate panes:
#    - opencode (coordinator) in one pane
#    - goose in another pane
#    - crush in another pane

# 3. Configure pane ids
fanout agents  # see current pane ids
vim ~/.config/fanout/agents.conf

# 4. Fan out from opencode (or any pane)
fanout fanout -a goose -t "Analyze this function" -a crush -t "Write tests for this"
```

### Agent restart gotcha

If you kill and restart an agent pane (e.g. to pick up config changes), its pane id changes. Re-discover with `fanout agents` and update `~/.config/fanout/agents.conf`.

## License

MIT
