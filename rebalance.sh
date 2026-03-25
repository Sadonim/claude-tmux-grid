#!/usr/bin/env bash
# =============================================================================
# claude-tmux-grid: rebalance.sh
# Restores layout proportions after terminal resize.
# Equalises both column widths AND row heights in the bottom agent grid.
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

# ─── Read config ──────────────────────────────────────────────────────────────
MONITOR=$(grep "^MONITOR_PANE=" "$CONF_FILE" 2>/dev/null | cut -d= -f2 || true)

# Prefer LAYOUT_* entries (overview mirror panes) for resizing.
# Fall back to regular agent entries when running without mirror mode.
LAYOUT_PANES=()
while IFS='=' read -r key val; do
  [[ "$key" =~ ^# || -z "${val:-}" ]] && continue
  if [[ "$key" =~ ^LAYOUT_ ]]; then
    LAYOUT_PANES+=("${key#LAYOUT_}")
  fi
done < "$CONF_FILE"

if [ "${#LAYOUT_PANES[@]}" -eq 0 ]; then
  while IFS='=' read -r pane_id agent; do
    [[ "$pane_id" == "MONITOR_PANE" || "$pane_id" =~ ^# || -z "${agent:-}" ]] && continue
    LAYOUT_PANES+=("$pane_id")
  done < "$CONF_FILE"
fi

N="${#LAYOUT_PANES[@]}"

# ─── Window dimensions ────────────────────────────────────────────────────────
W=$(tmux display-message -t "$SESSION:$WINDOW" -p "#{window_width}"  2>/dev/null || echo 200)
H=$(tmux display-message -t "$SESSION:$WINDOW" -p "#{window_height}" 2>/dev/null || echo 50)

MH=$(( H / 2 ))   # top section height  (monitor + top-right agents)
MW=$(( W / 2 ))   # monitor width

# ─── Resize monitor ───────────────────────────────────────────────────────────
if [ -n "$MONITOR" ]; then
  tmux resize-pane -t "$MONITOR" -y "$MH" 2>/dev/null || true
  tmux resize-pane -t "$MONITOR" -x "$MW" 2>/dev/null || true
fi

[ "$N" -eq 0 ] && exit 0

# ─── Top-right column: LAYOUT_PANES[0] and [1] stacked equally ───────────────
top_right_n=2
[ "$N" -lt 2 ] && top_right_n="$N"

AH=$(( MH / top_right_n ))
for i in $(seq 0 $(( top_right_n - 1 ))); do
  tmux resize-pane -t "${LAYOUT_PANES[$i]}" -y "$AH" 2>/dev/null || true
done

[ "$N" -le 2 ] && exit 0

# ─── Bottom grid ──────────────────────────────────────────────────────────────
local_count=$(( N - 2 ))

if   [ "$local_count" -le 2 ]; then cols="$local_count"; rows=1
elif [ "$local_count" -le 3 ]; then cols=3; rows=1
elif [ "$local_count" -le 4 ]; then cols=2; rows=2
elif [ "$local_count" -le 6 ]; then cols=3; rows=2
else                                  cols=4; rows=$(( (local_count + 3) / 4 ))
fi

BH=$(( H - MH ))                    # total bottom section height
TW=$(( (W - cols + 1) / cols ))     # per-column width
RH=$(( (BH - rows + 1) / rows ))    # per-row height (subtract borders, then halve)

# Resize every bottom pane to target dimensions.
# LAYOUT_PANES[2..N-1] are stored row-major (left→right, top→bottom),
# so all panes in the same row share the same horizontal divider after
# row-first construction — resizing each to RH keeps them aligned.
for r in $(seq 0 $(( rows - 1 ))); do
  for c in $(seq 0 $(( cols - 1 ))); do
    pane_idx=$(( 2 + r * cols + c ))
    if [ "$pane_idx" -lt "$N" ]; then
      tmux resize-pane -t "${LAYOUT_PANES[$pane_idx]}" -x "$TW" -y "$RH" 2>/dev/null || true
    fi
  done
done
