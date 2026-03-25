#!/usr/bin/env bash
# =============================================================================
# claude-tmux-grid: update-borders.sh
# Updates overview pane border titles + per-pane border colours
#
# Border format:
#   No todos:   ○ DATABASE
#   With todos: ● ARCHITECT  ████████░░ 4/5 (80%)
#
# Status icons and colours (synced from monitor.sh via /tmp/claude-agent-status/):
#   ● cyan   thinking / running
#   ● green  done / ✓ Tool
#   ● red    error
#   ○ grey   idle
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
STATUS_DIR="/tmp/claude-agent-status"

while getopts "s:w:c:" opt; do
  case "$opt" in
    s) SESSION="$OPTARG" ;;
    w) WINDOW="$OPTARG" ;;
    c) CONF_FILE="$OPTARG" ;;
    *) ;;
  esac
done

[ -f "$CONF_FILE" ] || exit 0

tmux list-windows -t "$SESSION" -F "#{window_name}" 2>/dev/null \
  | grep -q "^${WINDOW}$" || exit 0

# ─── Spinner frame (time-based, 10-frame braille) ────────────────────────────
get_spinner() {
  local idx=$(( $(date +%s) % 10 ))
  case "$idx" in
    0) printf '⠋' ;; 1) printf '⠙' ;; 2) printf '⠹' ;;
    3) printf '⠸' ;; 4) printf '⠼' ;; 5) printf '⠴' ;;
    6) printf '⠦' ;; 7) printf '⠧' ;; 8) printf '⠇' ;;
    *) printf '⠏' ;;
  esac
}

# ─── Status → icon + optional spinner ────────────────────────────────────────
# Icon prefix drives pane-border-format colour (auto-layout.sh):
#   !  orange  approval needed (highest priority — user action required)
#   ●  cyan    thinking / running
#   ✓  green   done
#   ✗  red     error
#   ○  grey    idle
get_status_icon() {
  local agent="$1"
  local s=""
  [ -f "$STATUS_DIR/$agent" ] && s=$(cat "$STATUS_DIR/$agent")
  case "$s" in
    approval)           echo "!" ;;
    thinking|running)   printf '● %s' "$(get_spinner)" ;;
    done|DONE)          echo "✓" ;;
    error)              echo "✗" ;;
    *)
      case "$s" in
        "✓"*) echo "✓" ;;
        *)    echo "○" ;;
      esac
      ;;
  esac
}

# ─── Parse todo checkboxes from pane content ─────────────────────────────────
# Claude Code actual symbols:
#   ✔ (U+2714)  completed
#   ◼ (U+25FC)  in_progress
#   ◻ (U+25FB)  pending
# Legacy / hand-written symbols (fallback):
#   ☑ (U+2611)  ☐ (U+2610)
#   [x]/[X]     [ ]
parse_todos() {
  local content="$1"
  local done_count todo_count

  # Claude Code native format (primary)
  done_count=$(printf '%s' "$content" | grep '✔' 2>/dev/null | wc -l | tr -d ' ')
  todo_count=$(printf '%s' "$content" | grep -E '◼|◻' 2>/dev/null | wc -l | tr -d ' ')

  # Legacy Unicode fallback
  if [ "$(( done_count + todo_count ))" -eq 0 ]; then
    done_count=$(printf '%s' "$content" | grep '☑' 2>/dev/null | wc -l | tr -d ' ')
    todo_count=$(printf '%s' "$content" | grep '☐' 2>/dev/null | wc -l | tr -d ' ')
  fi

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

# ─── Build agent→pane maps from conf ─────────────────────────────────────────
# Conf has two entry types:
#   %N=AGENT          real agent pane (its own window) — content capture source
#   LAYOUT_%M=AGENT   overview mirror pane             — border update target
REAL_MAP=$(mktemp)
OV_MAP=$(mktemp)
trap 'rm -f "$REAL_MAP" "$OV_MAP"' EXIT

while IFS='=' read -r key val; do
  [[ "$key" =~ ^# || -z "${val:-}" ]] && continue
  [[ "$key" == "MONITOR_PANE" ]] && continue
  if [[ "$key" =~ ^LAYOUT_ ]]; then
    ov_pane="${key#LAYOUT_}"
    printf '%s %s\n' "$val" "$ov_pane" >> "$OV_MAP"
  else
    printf '%s %s\n' "$val" "$key" >> "$REAL_MAP"
  fi
done < "$CONF_FILE"

# ─── Session-wide pane list for existence checks ─────────────────────────────
ALL_PANES=$(tmux list-panes -a -F "#{pane_id}" -t "$SESSION" 2>/dev/null || true)

# ─── Update each agent's overview pane ───────────────────────────────────────
while read -r agent ov_pane; do
  printf '%s\n' "$ALL_PANES" | grep -q "^${ov_pane}$" || continue

  # ── Title: icon + name + todo bar ───────────────────────────────────────
  # Colour is handled by pane-border-format reading the icon prefix (○/●/✓/✗).
  icon=$(get_status_icon "$agent")

  real_pane=$(grep "^${agent} " "$REAL_MAP" 2>/dev/null | awk '{print $2}' | head -1)
  capture_pane="${real_pane:-$ov_pane}"

  content=$(tmux capture-pane -t "$capture_pane" -p -S -100 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b[()][AB012]//g')

  read -r done_n todo_n <<< "$(parse_todos "$content")"
  total_n=$(( done_n + todo_n ))

  if [ "$total_n" -gt 0 ]; then
    bar=$(make_bar "$done_n" "$total_n")
    pct=$(( done_n * 100 / total_n ))
    title="${icon} ${agent}  ${bar} ${done_n}/${total_n} (${pct}%)"
  else
    title="${icon} ${agent}"
  fi

  tmux select-pane -t "$ov_pane" -T "$title" 2>/dev/null || true

done < "$OV_MAP"

# ─── Monitor pane title ───────────────────────────────────────────────────────
monitor_id=$(grep "^MONITOR_PANE=" "$CONF_FILE" 2>/dev/null | cut -d= -f2 || true)
[ -n "$monitor_id" ] && tmux select-pane -t "$monitor_id" -T "● Monitor" 2>/dev/null || true
