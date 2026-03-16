#!/usr/bin/env bash
# =============================================================================
# claude-tmux-grid: auto-layout.sh
# Automatically creates a tmux layout for N Claude agents + 1 monitor pane
#
# Layout (example: 8 agents):
#   ┌──────────────────┬──────────┐
#   │                  │ Agent 1  │
#   │    Monitor       ├──────────┤
#   │   (left ~50%)    │ Agent 2  │
#   ├──────┬───────────┼──────────┤
#   │  A3  │    A4     │   A5     │
#   ├──────┼───────────┼──────────┤
#   │  A6  │    A7     │   A8     │
#   └──────┴───────────┴──────────┘
#
# Usage:
#   ./auto-layout.sh -s SESSION AGENT1 AGENT2 AGENT3 ...
#   ./auto-layout.sh -s SESSION -a "ARCH CRITIC DESIGN TEST RUNNER"
#   ./auto-layout.sh -s SESSION -f agents.txt -w mywindow -r 30
#
# Requirements: tmux >= 3.0, bash >= 3.2 (macOS built-in), python3 (optional)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="/tmp/claude-tmux-grid.conf"

# ─── ANSI colors ──────────────────────────────────────────────────────────────
C_RED='\033[31m'; C_YEL='\033[33m'; C_GRN='\033[32m'
C_RST='\033[0m';  C_BLD='\033[1m'

# ─── Globals ──────────────────────────────────────────────────────────────────
SESSION=""
WINDOW="grid"
AGENTS=()
REFRESH=20
SKIP_MONITOR=false
MONITOR_PANE=""

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

usage() {
  cat <<'EOF'
claude-tmux-grid — Auto-layout for Claude multi-agent tmux workflows

Usage:
  auto-layout.sh -s SESSION [OPTIONS] [AGENT...]

Options:
  -s SESSION    tmux session name (required)
  -w WINDOW     window name (default: grid)
  -a "A1 A2"    space-separated agent names
  -f FILE       agent names from file (one per line, # = comment)
  -r SECS       monitor refresh interval (default: 20)
  -M            skip monitor pane (agent windows only)
  -h            show this help

Examples:
  auto-layout.sh -s work writer reviewer tester
  auto-layout.sh -s work -a "ARCH CRITIC DESIGNER TESTER"
  auto-layout.sh -s work -f my-agents.txt -r 10
EOF
  exit 0
}

die()  { echo -e "${C_RED}Error: $*${C_RST}" >&2; exit 1; }
ok()   { echo -e "   ${C_GRN}✓${C_RST}  $*"; }

# Return active pane ID in the current window.
# tmux split-window focuses the new pane, so this reliably returns
# the most recently created pane when called right after a split.
active_pane() {
  tmux display-message -t "${SESSION}:${WINDOW}" -p "#{pane_id}"
}

# Register a pane→agent mapping and set its border title.
# If a window named $agent already exists in the session, the overview pane
# becomes a mirror (live capture loop) and the config tracks the real agent pane.
register_agent() {
  local pane_id="$1" agent="$2"
  tmux select-pane -t "$pane_id" -T "$agent" 2>/dev/null || true

  # Look for an existing window with the same name as this agent
  local actual_pane=""
  if tmux list-windows -t "$SESSION" -F "#{window_name}" 2>/dev/null | grep -qx "$agent"; then
    actual_pane=$(tmux list-panes -t "${SESSION}:${agent}" -F "#{pane_id}" 2>/dev/null | head -1)
  fi

  if [ -n "$actual_pane" ]; then
    # Config: real pane for monitor activity tracking
    echo "${actual_pane}=${agent}" >> "$CONF_FILE"
    # Config: overview pane for rebalance layout sizing
    echo "LAYOUT_${pane_id}=${agent}" >> "$CONF_FILE"
    # Overview pane continuously mirrors the real agent pane.
    # awk strips the last 6 lines (Claude's bottom input UI: ❯ prompt, esc/shortcuts,
    # auto-compact bar) so only actual output content is visible in the small overview pane.
    # Uses awk instead of 'head -n -N' for macOS (BSD head) compatibility.
    tmux send-keys -t "$pane_id" \
      "old=''; while true; do new=\$(tmux capture-pane -t ${actual_pane} -p 2>/dev/null | awk 'NR>6{print prev[NR%6]} {prev[NR%6]=\$0}'); if [ \"\$new\" != \"\$old\" ]; then clear; printf '%s\n' \"\$new\"; old=\"\$new\"; fi; sleep 0.5; done" Enter
    ok "$agent  mirror →  ${actual_pane}  (overview pane: $pane_id)"
  else
    # No existing window — this pane IS the agent (original behaviour)
    echo "${pane_id}=${agent}" >> "$CONF_FILE"
    ok "$agent  →  $pane_id"
  fi
}

# =============================================================================
# GRID CALCULATION
# =============================================================================

# Outputs: "top_right bottom cols rows" for N agents
calc_grid() {
  local n="$1"
  local top_right bottom cols rows

  if [ "$n" -le 2 ]; then
    top_right="$n"; bottom=0
  else
    top_right=2; bottom=$(( n - 2 ))
  fi

  if   [ "$bottom" -le 0 ]; then cols=1; rows=0
  elif [ "$bottom" -le 2 ]; then cols="$bottom"; rows=1
  elif [ "$bottom" -le 3 ]; then cols=3; rows=1
  elif [ "$bottom" -le 4 ]; then cols=2; rows=2
  elif [ "$bottom" -le 6 ]; then cols=3; rows=2
  elif [ "$bottom" -le 8 ]; then cols=4; rows=2
  else
    cols=4
    rows=$(( (bottom + 3) / 4 ))
  fi

  echo "$top_right $bottom $cols $rows"
}

# =============================================================================
# PANE SPLITTING
# =============================================================================

# Split a pane into N equal parts along direction (-h or -v).
# Populates the caller-provided array name with resulting pane IDs.
# Usage: split_into_n -h BASE_PANE N RESULT_ARRAY_NAME
#
# Uses a while loop instead of seq to stay macOS/bash-3.2 compatible
# (macOS `seq 2 1` outputs "2\n1" rather than nothing).
split_into_n() {
  local direction="$1"
  local base_pane="$2"
  local count="$3"
  local arr_name="$4"

  # Seed the result array with the base pane
  eval "${arr_name}=(\"\$base_pane\")"

  local i=2
  while [ "$i" -le "$count" ]; do
    local remaining=$(( count - i + 1 ))
    local total=$(( count - i + 2 ))
    local pct=$(( remaining * 100 / total ))

    # Index of the pane to split (last appended)
    local prev_idx=$(( i - 2 ))
    local prev_pane
    eval "prev_pane=\"\${${arr_name}[$prev_idx]}\""

    tmux split-window "$direction" -t "$prev_pane" -p "$pct"
    local new_pane; new_pane=$(active_pane)
    eval "${arr_name}+=(\"\$new_pane\")"
    i=$(( i + 1 ))
  done
}

# =============================================================================
# LAYOUT BUILDERS
# =============================================================================

build_layout_monitor_only() {
  echo "MONITOR_PANE=$MONITOR_PANE" >> "$CONF_FILE"
  start_monitor "$MONITOR_PANE"
}

build_layout_1() {
  # Monitor (left 50%) | Agent (right 50%)
  tmux split-window -h -t "$MONITOR_PANE" -p 50
  local a1; a1=$(active_pane)
  register_agent "$a1" "${AGENTS[0]}"
  echo "MONITOR_PANE=$MONITOR_PANE" >> "$CONF_FILE"
  start_monitor "$MONITOR_PANE"
}

build_layout_2() {
  # Monitor (left) | A1 (top-right) | A2 (bottom-right)
  tmux split-window -h -t "$MONITOR_PANE" -p 50
  local top_r; top_r=$(active_pane)
  tmux split-window -v -t "$top_r" -p 50
  local bot_r; bot_r=$(active_pane)
  register_agent "$top_r" "${AGENTS[0]}"
  register_agent "$bot_r" "${AGENTS[1]}"
  echo "MONITOR_PANE=$MONITOR_PANE" >> "$CONF_FILE"
  start_monitor "$MONITOR_PANE"
}

build_layout_n() {
  # N >= 3: top (Monitor + 2 stacked) + bottom grid
  local top_right_n="$1"
  local bottom_n="$2"
  local bottom_cols="$3"
  local bottom_rows="$4"

  # ── Top/bottom split ────────────────────────────────────────────────────────
  local bottom_origin=""
  if [ "$bottom_n" -gt 0 ]; then
    tmux split-window -v -t "$MONITOR_PANE" -p 50
    bottom_origin=$(active_pane)
  fi

  # ── Monitor (left) / top-right column (right) ───────────────────────────────
  tmux split-window -h -t "$MONITOR_PANE" -p 50
  local top_r; top_r=$(active_pane)

  # ── Stack top-right agents ──────────────────────────────────────────────────
  local top_panes
  split_into_n -v "$top_r" "$top_right_n" top_panes

  local j=0
  while [ "$j" -lt "$top_right_n" ]; do
    register_agent "${top_panes[$j]}" "${AGENTS[$j]}"
    j=$(( j + 1 ))
  done

  # ── Bottom grid ─────────────────────────────────────────────────────────────
  if [ "$bottom_n" -gt 0 ]; then
    # Create columns
    local col_origins
    split_into_n -h "$bottom_origin" "$bottom_cols" col_origins

    # For each column, create rows; accumulate pane IDs column-major
    # all_col_panes[col * bottom_rows + row] = pane_id
    local all_col_panes=()
    local col=0
    while [ "$col" -lt "$bottom_cols" ]; do
      local col_pane="${col_origins[$col]}"
      local row_panes
      split_into_n -v "$col_pane" "$bottom_rows" row_panes

      local r=0
      while [ "$r" -lt "$bottom_rows" ]; do
        all_col_panes+=("${row_panes[$r]}")
        r=$(( r + 1 ))
      done
      col=$(( col + 1 ))
    done

    # Register agents left-to-right, top-to-bottom
    # logical (row,col) → all_col_panes[col * bottom_rows + row]
    local row=0 agent_local=0 agent_global
    while [ "$row" -lt "$bottom_rows" ]; do
      local c=0
      while [ "$c" -lt "$bottom_cols" ]; do
        agent_global=$(( top_right_n + agent_local ))
        if [ "$agent_global" -lt "${#AGENTS[@]}" ]; then
          local pane_idx=$(( c * bottom_rows + row ))
          register_agent "${all_col_panes[$pane_idx]}" "${AGENTS[$agent_global]}"
        fi
        agent_local=$(( agent_local + 1 ))
        c=$(( c + 1 ))
      done
      row=$(( row + 1 ))
    done
  fi

  echo "MONITOR_PANE=$MONITOR_PANE" >> "$CONF_FILE"
  start_monitor "$MONITOR_PANE"
}

build_layout_agents_only() {
  # -M flag: create a simple grid of N agents, no monitor
  local n="$1"

  # Choose grid dimensions: ~2:1 aspect ratio in columns
  local cols rows
  if   [ "$n" -le 1 ]; then cols=1
  elif [ "$n" -le 2 ]; then cols=2
  elif [ "$n" -le 3 ]; then cols=3
  elif [ "$n" -le 4 ]; then cols=2
  elif [ "$n" -le 6 ]; then cols=3
  elif [ "$n" -le 8 ]; then cols=4
  else                       cols=4
  fi
  rows=$(( (n + cols - 1) / cols ))

  # Build column panes
  local col_panes
  split_into_n -h "$MONITOR_PANE" "$cols" col_panes

  # For each column, split into rows; accumulate column-major
  local all_panes=()
  local col=0
  while [ "$col" -lt "$cols" ]; do
    local row_panes
    split_into_n -v "${col_panes[$col]}" "$rows" row_panes
    local r=0
    while [ "$r" -lt "$rows" ]; do
      all_panes+=("${row_panes[$r]}")
      r=$(( r + 1 ))
    done
    col=$(( col + 1 ))
  done

  # Register agents left-to-right, top-to-bottom
  local row=0 idx=0
  while [ "$row" -lt "$rows" ]; do
    local c=0
    while [ "$c" -lt "$cols" ]; do
      if [ "$idx" -lt "$n" ]; then
        local pane_idx=$(( c * rows + row ))
        register_agent "${all_panes[$pane_idx]}" "${AGENTS[$idx]}"
        idx=$(( idx + 1 ))
      fi
      c=$(( c + 1 ))
    done
    row=$(( row + 1 ))
  done
}

# =============================================================================
# SETUP HELPERS
# =============================================================================

setup_borders() {
  tmux set-option -w -t "$SESSION:$WINDOW" pane-border-status top
  tmux set-option -w -t "$SESSION:$WINDOW" pane-border-format \
    "#[fg=colour244] #{pane_title} #[fg=default]"
  tmux set-option -w -t "$SESSION:$WINDOW" pane-active-border-style "fg=colour39"
  tmux set-option -w -t "$SESSION:$WINDOW" pane-border-style "fg=colour238"
}

start_monitor() {
  local pane="$1"
  local monitor_sh="$SCRIPT_DIR/monitor.sh"
  tmux select-pane -t "$pane" -T "● Monitor" 2>/dev/null || true
  if [ -f "$monitor_sh" ]; then
    tmux send-keys -t "$pane" \
      "bash '$monitor_sh' -s '$SESSION' -w '$WINDOW' -r '$REFRESH' -c '$CONF_FILE'" Enter
  else
    tmux send-keys -t "$pane" \
      "echo '⚠  monitor.sh not found at: $monitor_sh'" Enter
  fi
}

setup_resize() {
  local rebalance_sh="$SCRIPT_DIR/rebalance.sh"
  if [ -f "$rebalance_sh" ]; then
    tmux set-hook -t "$SESSION:$WINDOW" window-resized \
      "run-shell 'bash \"$rebalance_sh\" \"$SESSION\" \"$WINDOW\" \"$CONF_FILE\"'"
    sleep 0.3
    bash "$rebalance_sh" "$SESSION" "$WINDOW" "$CONF_FILE" 2>/dev/null || true
  fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  # ── Parse arguments ─────────────────────────────────────────────────────────
  while getopts "s:w:a:f:r:Mh" opt; do
    case "$opt" in
      s) SESSION="$OPTARG" ;;
      w) WINDOW="$OPTARG" ;;
      a) read -r -a AGENTS <<< "$OPTARG" ;;
      f) while IFS= read -r line || [ -n "$line" ]; do
           [[ "$line" =~ ^[[:space:]]*\# || -z "${line// }" ]] && continue
           AGENTS+=("$line")
         done < "$OPTARG" ;;
      r) REFRESH="$OPTARG" ;;
      M) SKIP_MONITOR=true ;;
      h) usage ;;
      *) usage ;;
    esac
  done
  shift $((OPTIND - 1))

  # Positional args as agent names
  if [ "${#AGENTS[@]}" -eq 0 ] && [ "$#" -gt 0 ]; then
    AGENTS=("$@")
  fi

  # ── Validation ──────────────────────────────────────────────────────────────
  [ -z "$SESSION" ] && die "-s SESSION is required"
  tmux has-session -t "$SESSION" 2>/dev/null \
    || die "Session '$SESSION' not found. Create it: tmux new-session -d -s $SESSION"

  local N="${#AGENTS[@]}"

  # ── Window setup ────────────────────────────────────────────────────────────
  if tmux list-windows -t "$SESSION" -F "#{window_name}" 2>/dev/null \
      | grep -q "^${WINDOW}$"; then
    echo -e "${C_YEL}Window '$WINDOW' already exists. Recreate? [y/N]${C_RST}"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 0
    tmux kill-window -t "$SESSION:$WINDOW"
  fi

  rm -f "$CONF_FILE"
  printf "# claude-tmux-grid  session=%s  window=%s\n" "$SESSION" "$WINDOW" > "$CONF_FILE"

  echo ""
  echo -e "${C_BLD}▶  claude-tmux-grid${C_RST}  session=${C_BLD}${SESSION}${C_RST}  window=${C_BLD}${WINDOW}${C_RST}"

  local top_right_n bottom_n bottom_cols bottom_rows
  read -r top_right_n bottom_n bottom_cols bottom_rows <<< "$(calc_grid "$N")"
  echo "   Agents: ${N}  │  Top-right: ${top_right_n}  │  Bottom: ${bottom_n} (${bottom_cols}×${bottom_rows})"
  echo ""

  # ── Create window ────────────────────────────────────────────────────────────
  tmux new-window -t "$SESSION" -n "$WINDOW" -d
  MONITOR_PANE=$(tmux list-panes -t "$SESSION:$WINDOW" -F "#{pane_id}" | head -1)

  # ── Build layout ─────────────────────────────────────────────────────────────
  if [ "$SKIP_MONITOR" = true ]; then
    build_layout_agents_only "$N"
  elif [ "$N" -eq 0 ]; then
    build_layout_monitor_only
  elif [ "$N" -eq 1 ]; then
    build_layout_1
  elif [ "$N" -eq 2 ]; then
    build_layout_2
  else
    build_layout_n "$top_right_n" "$bottom_n" "$bottom_cols" "$bottom_rows"
  fi

  # ── Finalize ─────────────────────────────────────────────────────────────────
  setup_borders
  setup_resize

  # ── Move overview window to position 0 (always first) ───────────────────────
  if tmux list-windows -t "$SESSION" -F "#{window_index}" 2>/dev/null | grep -q "^0$"; then
    local zero_name
    zero_name=$(tmux list-windows -t "$SESSION" -F "#{window_index} #{window_name}" \
      | awk '$1==0 {print $2}')
    if [ "$zero_name" != "$WINDOW" ]; then
      tmux move-window -s "${SESSION}:0" -t "${SESSION}:99" 2>/dev/null || true
      tmux move-window -s "${SESSION}:${WINDOW}" -t "${SESSION}:0"
    fi
  else
    tmux move-window -s "${SESSION}:${WINDOW}" -t "${SESSION}:0"
  fi

  tmux select-window -t "$SESSION:$WINDOW"

  echo ""
  echo -e "${C_GRN}✅  Layout ready!${C_RST}"
  echo "   Attach : tmux attach-session -t $SESSION"
  echo "   Config : $CONF_FILE"
  echo "   Refresh: ${REFRESH}s"
}

main "$@"
