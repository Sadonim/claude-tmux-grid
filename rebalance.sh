#!/usr/bin/env bash
# =============================================================================
# claude-tmux-grid: rebalance.sh
# Restores layout proportions after terminal resize
#
# Called automatically via tmux window-resized hook, or manually:
#   rebalance.sh SESSION WINDOW [CONF_FILE]
# =============================================================================

set -euo pipefail

SESSION="${1:-}"
WINDOW="${2:-grid}"
CONF_FILE="${3:-/tmp/claude-tmux-grid.conf}"

[ -z "$SESSION" ] && { echo "Usage: rebalance.sh SESSION [WINDOW] [CONF_FILE]" >&2; exit 1; }
[ -f "$CONF_FILE" ] || exit 0

tmux list-windows -t "$SESSION" -F "#{window_name}" 2>/dev/null \
  | grep -q "^${WINDOW}$" || exit 0

# ─── Helper: look up pane ID by agent name ────────────────────────────────────
get_pane() { grep "=${1}$" "$CONF_FILE" 2>/dev/null | cut -d= -f1 | head -1; }

# ─── Read known panes ─────────────────────────────────────────────────────────
MONITOR=$(grep "^MONITOR_PANE=" "$CONF_FILE" 2>/dev/null | cut -d= -f2 || true)

# Count agents (non-comment, non-MONITOR lines)
AGENT_COUNT=$(grep -cE '^%[0-9]' "$CONF_FILE" 2>/dev/null || echo 0)

# Collect all agent pane IDs in order
AGENT_PANES=()
while IFS='=' read -r pane_id agent; do
  [[ "$pane_id" == "MONITOR_PANE" || "$pane_id" =~ ^# || -z "$agent" ]] && continue
  AGENT_PANES+=("$pane_id")
done < "$CONF_FILE"

# ─── Window dimensions ────────────────────────────────────────────────────────
W=$(tmux display-message -t "$SESSION:$WINDOW" -p "#{window_width}"  2>/dev/null || echo 200)
H=$(tmux display-message -t "$SESSION:$WINDOW" -p "#{window_height}" 2>/dev/null || echo 50)

# ─── Target sizes ─────────────────────────────────────────────────────────────
MH=$(( H / 2 ))           # Monitor pane height (top half)
MW=$(( W / 2 ))           # Monitor pane width  (left half)

# ─── Apply resizes ────────────────────────────────────────────────────────────
# Resize monitor pane to occupy top-left quadrant
if [ -n "$MONITOR" ]; then
  tmux resize-pane -t "$MONITOR" -y "$MH" 2>/dev/null || true
  tmux resize-pane -t "$MONITOR" -x "$MW" 2>/dev/null || true
fi

# Resize the first top-right agent (sets height for entire right column)
if [ "${#AGENT_PANES[@]}" -ge 1 ]; then
  AH=$(( MH / 2 ))
  tmux resize-pane -t "${AGENT_PANES[0]}" -y "$AH" 2>/dev/null || true
fi

# Detect bottom grid columns by counting unique x-positions of bottom panes
# Simpler approach: resize first bottom-row pane to equal columns
if [ "${#AGENT_PANES[@]}" -ge 3 ]; then
  # AGENT_PANES[2] is always first bottom agent
  local_count=$(( ${#AGENT_PANES[@]} - 2 ))
  local cols
  if   [ "$local_count" -le 2 ]; then cols="$local_count"
  elif [ "$local_count" -le 3 ]; then cols=3
  elif [ "$local_count" -le 4 ]; then cols=2
  elif [ "$local_count" -le 6 ]; then cols=3
  else                                  cols=4
  fi

  TW=$(( (W - cols + 1) / cols ))

  # Resize each column's top pane to set width
  # Agents are stored left-to-right: AGENT_PANES[2] = col0, [2+rows] = col1, etc.
  rows=$(( (local_count + cols - 1) / cols ))
  local c
  for c in $(seq 0 $(( cols - 1 ))); do
    local pane_idx=$(( 2 + c * rows ))
    if [ "$pane_idx" -lt "${#AGENT_PANES[@]}" ]; then
      tmux resize-pane -t "${AGENT_PANES[$pane_idx]}" -x "$TW" 2>/dev/null || true
    fi
  done
fi
