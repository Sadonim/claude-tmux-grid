#!/usr/bin/env bash
# =============================================================================
# claude-tmux-grid: update-borders.sh
# Updates pane border titles with agent name + todo progress bar
#
# Border format:
#   No todos:   ARCHITECT
#   With todos: ARCHITECT  ████████░░ 4/5 (80%)
#
# Parses Claude TodoWrite output:
#   Unicode: ☑ (done)  ☐ (pending)
#   ASCII:   [x]/[X]   [ ]
#
# Usage: update-borders.sh -s SESSION -w WINDOW -c CONF_FILE
# =============================================================================

set -euo pipefail

SESSION=""
WINDOW="grid"
CONF_FILE="/tmp/claude-tmux-grid.conf"

while getopts "s:w:c:" opt; do
  case "$opt" in
    s) SESSION="$OPTARG" ;;
    w) WINDOW="$OPTARG" ;;
    c) CONF_FILE="$OPTARG" ;;
    *) ;;
  esac
done

[ -f "$CONF_FILE" ] || exit 0

# Verify window exists
tmux list-windows -t "$SESSION" -F "#{window_name}" 2>/dev/null \
  | grep -q "^${WINDOW}$" || exit 0

# ─── Parse todo checkboxes from pane content ──────────────────────────────────
parse_todos() {
  local content="$1"
  local done_count todo_count

  # Unicode (Claude default)
  # Use grep|wc -l instead of grep -c: on macOS, grep -c exits 1 with "0" output
  # when there are no matches, and the || echo 0 then appends another "0",
  # resulting in "0\n0" which breaks arithmetic expansion.
  done_count=$(printf '%s' "$content" | grep '☑' 2>/dev/null | wc -l | tr -d ' ')
  todo_count=$(printf '%s' "$content" | grep '☐' 2>/dev/null | wc -l | tr -d ' ')

  # ASCII fallback
  if [ "$(( done_count + todo_count ))" -eq 0 ]; then
    done_count=$(printf '%s' "$content" | grep -E '\[x\]|\[X\]' 2>/dev/null | wc -l | tr -d ' ')
    todo_count=$(printf '%s' "$content" | grep -E '\[ \]' 2>/dev/null | wc -l | tr -d ' ')
  fi

  echo "$done_count $todo_count"
}

# ─── 10-char progress bar ────────────────────────────────────────────────────
make_bar() {
  local done="$1" total="$2"
  local filled=0 bar="" i

  [ "$total" -gt 0 ] && filled=$(( done * 10 / total )) || filled=0

  for i in $(seq 1 10); do
    [ "$i" -le "$filled" ] && bar="${bar}█" || bar="${bar}░"
  done
  echo "$bar"
}

# ─── Update each agent pane ───────────────────────────────────────────────────
while IFS='=' read -r pane_id agent; do
  [[ "$pane_id" == "MONITOR_PANE" || "$pane_id" =~ ^# || -z "$agent" ]] && continue

  # Verify pane still exists
  tmux list-panes -t "$SESSION:$WINDOW" -F "#{pane_id}" 2>/dev/null \
    | grep -q "^${pane_id}$" || continue

  # Capture last 100 lines, strip ANSI sequences
  content=$(tmux capture-pane -t "$pane_id" -p -S -100 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b[()][AB012]//g')

  read -r done_n todo_n <<< "$(parse_todos "$content")"
  total_n=$(( done_n + todo_n ))

  if [ "$total_n" -gt 0 ]; then
    bar=$(make_bar "$done_n" "$total_n")
    pct=$(( done_n * 100 / total_n ))
    title="${agent}  ${bar} ${done_n}/${total_n} (${pct}%)"
  else
    title="${agent}"
  fi

  tmux select-pane -t "$pane_id" -T "$title" 2>/dev/null || true

done < "$CONF_FILE"

# ─── Monitor pane title ───────────────────────────────────────────────────────
monitor_id=$(grep "^MONITOR_PANE=" "$CONF_FILE" 2>/dev/null | cut -d= -f2 || true)
[ -n "$monitor_id" ] && tmux select-pane -t "$monitor_id" -T "● Monitor" 2>/dev/null || true
