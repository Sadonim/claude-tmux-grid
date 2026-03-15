# claude-tmux-grid

Auto-layout for Claude multi-agent tmux workflows. Arrange N Claude agents in a dynamic grid with a live monitor pane — task progress, token usage, and agent status at a glance.

```
┌──────────────────────┬──────────┐
│                      │ARCHITECT │
│     Monitor          ├──────────┤
│  ● thinking          │  CRITIC  │
│  ● working    tokens ├──────────┤
│  ● idle    ──────────┤ SECURITY │
├────────┬─────────────┼──────────┤
│DESIGNER│   TESTER    │ REFACTOR │
├────────┼─────────────┼──────────┤
│ RUNNER │   BACKEND   │  (slot)  │
└────────┴─────────────┴──────────┘
```

Each pane border shows the agent name and live todo progress:
```
ARCHITECT  ████████░░ 4/5 (80%)
```

## Features

- **Auto grid** — pass N agent names, layout is calculated automatically
- **Live monitor** — 20s refresh showing agent status, Claude token usage (24h), session count
- **Border labels** — agent name + todo-based progress bar (parses Claude's `TodoWrite` output)
- **Resize resilience** — layout proportions restored on terminal resize via `window-resized` hook
- **Configurable** — refresh rate, window name, skip monitor option

## Requirements

- tmux ≥ 3.0
- bash ≥ 3.2 (macOS built-in works)
- python3 (for token stats; gracefully degrades if missing)

## Installation

```bash
git clone https://github.com/Sadonim/claude-tmux-grid.git
cd claude-tmux-grid
bash install.sh
```

Or use directly without installing:

```bash
bash auto-layout.sh -s SESSION AGENT1 AGENT2 AGENT3
```

## Usage

```bash
# Basic: session name + agent names as positional args
claude-tmux-grid -s mysession writer reviewer tester

# From file (one agent per line, # = comment)
claude-tmux-grid -s mysession -f agents.txt

# Custom window name and refresh interval
claude-tmux-grid -s mysession -w overview -r 30 ARCH CRITIC DESIGN

# Without monitor pane (agents only)
claude-tmux-grid -s mysession -M ARCH CRITIC DESIGN TEST
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-s SESSION` | *(required)* | tmux session name |
| `-w WINDOW` | `grid` | window name |
| `-a "A1 A2"` | — | space-separated agent names |
| `-f FILE` | — | file with agent names (one per line) |
| `-r SECS` | `20` | monitor refresh interval |
| `-M` | off | skip monitor pane |

## Layout Algorithm

Grid dimensions are computed automatically based on agent count:

| Agents | Layout |
|--------|--------|
| 1 | Monitor (left) │ Agent (right) |
| 2 | Monitor (left) │ A1 / A2 stacked |
| 3–8 | Monitor + 2 top-right │ remaining in grid |
| 9+ | Monitor + 2 top-right │ 4-column grid |

Bottom grid column count:

| Bottom agents | Columns |
|--------------|---------|
| 1–3 | 1–3 (1 row) |
| 4 | 2×2 |
| 5–6 | 3 columns |
| 7–8 | 4 columns |

## Todo Progress

The border title updates automatically when Claude uses `TodoWrite`:

- `☑` / `[x]` → completed item
- `☐` / `[ ]` → pending item

Format: `AGENT_NAME  ████████░░ 4/5 (80%)`

## Files

```
claude-tmux-grid/
├── auto-layout.sh      # Main entry point
├── monitor.sh          # Monitor pane display loop
├── update-borders.sh   # Pane border title updater
├── rebalance.sh        # Layout resize handler
├── install.sh          # Installer
└── examples/
    ├── quickstart.sh   # 4-agent demo
    └── 8-agents.sh     # Full 8-agent layout
```

## Examples

See the [`examples/`](examples/) directory:

```bash
# 4-agent quickstart demo
bash examples/quickstart.sh

# 8-agent full layout (matches uf-agents session)
bash examples/8-agents.sh my-session
```

## Integration with Claude Code

Each agent window should have its own Claude Code instance running. The monitor detects activity by:

1. Capturing the last 30 lines of each pane
2. MD5-hashing content to detect changes
3. Matching spinner chars (`⠋⠙⠹...`) for "thinking" state
4. Matching `✓ Bash/Edit/Write/...` for "working" state

Token usage is read from `~/.claude/projects/**/*.jsonl` (last 24 hours).

## Keybinding (optional)

After `install.sh`, optionally add to `~/.tmux.conf`:

```tmux
# Rebalance layout: prefix + =
bind = run-shell "bash ~/.config/tmux/claude-tmux-grid/rebalance.sh \
  $(tmux display-message -p '#S') grid"
```

## License

MIT
