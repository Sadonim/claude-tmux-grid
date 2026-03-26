<p align="center">
  <br />
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://img.shields.io/badge/%F0%9F%96%A5%EF%B8%8F-claude--tmux--grid-03B26C?style=for-the-badge&labelColor=141B2D">
    <img alt="claude-tmux-grid" src="https://img.shields.io/badge/%F0%9F%96%A5%EF%B8%8F-claude--tmux--grid-03B26C?style=for-the-badge&labelColor=191F28" height="48">
  </picture>
  <br />
  <b>Live multi-agent tmux dashboard for Claude Code workflows</b>
  <br />
  <sub>Colour-coded status borders, todo progress bars, tool-type action icons, and system resource monitoring in a single overview pane</sub>
  <br />
  <br />
  <a href="https://github.com/Sadonim/claude-tmux-grid/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="MIT License"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="bash 3.2+"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/tmux-3.0%2B-1BB91F?style=flat-square&logo=tmux&logoColor=white" alt="tmux 3.0+"></a>
  <a href="#requirements"><img src="https://img.shields.io/badge/python-3.x-3776AB?style=flat-square&logo=python&logoColor=white" alt="Python 3.x"></a>
  <a href="#"><img src="https://img.shields.io/badge/platform-macOS-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS"></a>
  <br />
  <br />
</p>

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Layout Algorithm](#layout-algorithm)
- [Status Detection](#status-detection)
- [Action History Hierarchy](#action-history-hierarchy)
- [Files](#files)
- [Optional tmux Keybinding](#optional-tmux-keybinding)
- [License](#license)

---

## Overview

```
┌─ ! DESIGNER ──────────────────┬─ ● ARCHITECT ⠼ ─────────────┐
│                                │                               │
│   claude-tmux-grid  15:42:07  │  (architect pane content)     │
│   ────────────────────────    ├─ ✓ CRITIC  ████████░░ 4/5 ───┤
│   Project: my-project         │                               │
│   Tokens: in:45k  out:12k     │  (critic pane content)        │
│   CPU ████░░░░ 38%            ├─ ✗ SECURITY ───────────────── ┤
│   RAM ██████░░ 12/48GB        │                               │
│   GPU ░░░░░░░░  0%            │  (security pane content)      │
│                               ├────────────────────────────── ┤
│   AGENT    STATUS   LAST ACT  │  BACKEND  │  TESTER           │
│   ──────── ──────── ───────── │           │                   │
│   ARCH     ●think   ✎ Write.. ├───────────┼────────────────── ┤
│   CRITIC   ✓ Edit   ✎ Edit..  │  DESIGNER │  RUNNER           │
│   BACKEND  ●run     ⚡ Bash.. │           │                   │
│   DESIGNER ! approv ! waiting  └───────────┴────────────────── ┘
│   ──────── ──────── ──────────
│   ●ARCH →✓CRIT →●BACK →!DESI
└───────────────────────────────
```

---

## Features

### Live Monitor Pane

```
  claude-tmux-grid  2026-03-25  15:42:07
  ─────────────────────────────────────────────────────────────────
  Project: my-project          Procs: 4      Sessions: 2
  Tokens (24h):  in:45.2k  out:12.1k  cache:8.3k
  CPU ████░░░░ 38%   RAM ██████░░ 12/48GB   GPU ░░░░░░░░  0%
  ─────────────────────────────────────────────────────────────────
  AGENT              STATUS        AGO     LAST ACTION
  ────────────────   ────   ────────────   ──────   ──────────────────────
  ARCHITECT          ●      thinking       2m       ✎ Write  system_design.md
  CRITIC             ●      ✓ Edit         5m       ✎ Edit   routes/auth.py
  BACKEND            ●      running        30s      ⚡ Bash  pytest tests/ -x
  DESIGNER           !      approval       1m       ! awaiting approval
  TESTER             ○      idle           8m       3/5✓ Add login endpoint
  SECURITY           ✓      done           12m      ✎ Write  SECURITY_REPORT.md
  ─────────────────────────────────────────────────────────────────
  Pipeline:  ●ARCH →✓CRIT →●BACK →!DESI →○TEST →✓SECU
```

**Status icons**

| Icon | Colour | Meaning |
|------|--------|---------|
| `!` | Orange | Awaiting approval — Claude Code permission dialog detected |
| `●` | Cyan | Thinking / running (braille spinner `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) |
| `✓` | Green | Last tool succeeded |
| `✗` | Red | Error detected |
| `○` | Grey | Idle |

**LAST ACTION icons**

| Prefix | Tool |
|--------|------|
| `✎ Edit` | File edited |
| `✎ Write` | File written |
| `⚡ Bash` | Shell command |
| `≡ Read` | File read |
| `✓ N/M` | Todo progress (from `TodoWrite`) |
| `! awaiting approval` | Permission dialog open (overrides content) |

### Border Titles

Each pane border shows the agent name, live status icon, and todo progress:

```
─ ● ARCHITECT ⠼ ──────────────────────────────────────────────
─ ✓ CRITIC  ████████░░ 4/5 (80%) ─────────────────────────────
─ ! DESIGNER ──────────────────────────────────────────────────
─ ○ TESTER ────────────────────────────────────────────────────
```

Border colour follows the status icon:

| Icon | Border colour |
|------|--------------|
| `!` | Orange |
| `●` | Cyan |
| `✓` | Green |
| `✗` | Red |
| `○` | Dark grey |

### Todo Progress

The border progress bar updates automatically when Claude uses `TodoWrite`. Claude Code's native symbols are supported:

| Symbol | Meaning |
|--------|---------|
| `✔` | completed |
| `◼` | in progress |
| `◻` | pending |

Legacy formats (`☑`/`☐`, `[x]`/`[ ]`) are also recognised as fallbacks.

### System Resources

Displayed in the monitor header on every refresh:

```
CPU ████░░░░ 38%   RAM ██████░░ 12/48GB   GPU ░░░░░░░░  0%
```

- **CPU** — average across all cores via `ps -A`
- **RAM** — used / total GB via `vm_stat`
- **GPU** — Apple Silicon utilisation via `ioreg -c IOAccelerator`

### Pipeline Flow

One-line summary of all agents' current state at the bottom of the header:

```
Pipeline:  ●ARCH →✓CRIT →●BACK →!DESI →○TEST →✓SECU
```

---

## Requirements

- tmux ≥ 3.0
- bash ≥ 3.2 (macOS built-in works)
- python3 (token stats + display-width truncation; degrades gracefully if missing)

---

## Installation

```bash
git clone https://github.com/Sadonim/claude-tmux-grid.git ~/claude-tmux-grid
cd ~/claude-tmux-grid
```

No installer needed — invoke `auto-layout.sh` directly from the cloned directory.

---

## Usage

### Direct

```bash
# Minimal: session + agent names
bash auto-layout.sh -s mysession ARCH CRITIC BACKEND TESTER

# Custom window name and refresh rate
bash auto-layout.sh -s mysession -w overview -r 30 ARCH CRITIC BACKEND

# Without monitor pane
bash auto-layout.sh -s mysession -M ARCH CRITIC BACKEND TESTER
```

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-s SESSION` | *(required)* | tmux session name |
| `-w WINDOW` | `grid` | overview window name |
| `-r SECS` | `20` | monitor refresh interval |
| `-M` | off | skip monitor pane |

---

## Layout Algorithm

Grid dimensions are computed automatically from agent count:

| Agents | Layout |
|--------|--------|
| 1 | Monitor (left) + Agent (right) |
| 2 | Monitor (left) + A1 / A2 stacked |
| 3–8 | Monitor + 2 top-right + remaining bottom grid |
| 9+ | Monitor + 2 top-right + 4-column bottom grid |

Bottom grid columns:

| Bottom panes | Columns |
|-------------|---------|
| 1–3 | 1 per pane |
| 4 | 2×2 |
| 5–6 | 3 |
| 7–8 | 4 |

---

## Status Detection

The monitor captures the last 100 lines of each agent pane every refresh cycle and determines status by priority:

```
1. approval    — "Allow" + "Deny" lines both visible
2. thinking    — braille spinner chars (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏)
3. running     — "esc to interrupt" visible
4. ✓ Tool      — "✓ Bash/Edit/Write/…" visible
5. error       — "error" / "failed" / "✗" visible
6. done        — prompt visible, changed within 30s
7. idle        — prompt visible, unchanged
```

Status is persisted to `/tmp/claude-agent-status/{AGENT}` so `update-borders.sh` can sync border colours without re-reading pane content.

---

## Action History Hierarchy

LAST ACTION is sourced from three levels, falling back in order:

| Level | Source | What it shows |
|-------|--------|---------------|
| 1 | `~/.claude/projects/**/*.jsonl` | Latest `TodoWrite` progress or last tool call |
| 2 | `docs/handoffs/signals/*.done` | Handoff signal summary |
| 3 | Pane scroll buffer | Last non-chrome line visible |

---

## Files

```
claude-tmux-grid/
├── auto-layout.sh       Main entry point — creates layout, starts monitor + border updater
├── monitor.sh           Monitor pane display loop (agents table, header, pipeline flow)
├── update-borders.sh    Pane border title + todo progress updater
└── rebalance.sh         Layout resize handler (called by tmux window-resized hook)
```

---

## Optional tmux Keybinding

```tmux
# Rebalance layout: prefix + =
bind = run-shell "bash ~/claude-tmux-grid/rebalance.sh $(tmux display-message -p '#S') grid"
```

---

## License

MIT
