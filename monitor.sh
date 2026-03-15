#!/usr/bin/env bash
# =============================================================================
# claude-tmux-grid: monitor.sh
# Runs in the Monitor pane — displays agent status table every N seconds
#
# Usage (invoked automatically by auto-layout.sh):
#   monitor.sh -s SESSION -w WINDOW -r REFRESH -c CONF_FILE
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────
SESSION=""
WINDOW="grid"
REFRESH=20
CONF_FILE="/tmp/claude-tmux-grid.conf"
SNAP_DIR="/tmp/claude-tmux-grid-snaps"

# ─── Colors ───────────────────────────────────────────────────────────────────
C_RST='\033[0m'
C_BLD='\033[1m'
C_DIM='\033[2m'
C_GRN='\033[32m'
C_YEL='\033[33m'
C_BLU='\033[34m'
C_CYN='\033[36m'
C_RED='\033[31m'
C_WHT='\033[37m'
C_GRY='\033[90m'

mkdir -p "$SNAP_DIR"

# ─── Parse arguments ──────────────────────────────────────────────────────────
while getopts "s:w:r:c:" opt; do
  case "$opt" in
    s) SESSION="$OPTARG" ;;
    w) WINDOW="$OPTARG" ;;
    r) REFRESH="$OPTARG" ;;
    c) CONF_FILE="$OPTARG" ;;
    *) ;;
  esac
done

# ─── Number formatter ─────────────────────────────────────────────────────────
fmt_num() {
  local n="${1:-0}"
  if   [ "$n" -ge 1000000 ] 2>/dev/null; then printf "%.1fM" "$(echo "$n / 1000000" | bc -l)"
  elif [ "$n" -ge 1000    ] 2>/dev/null; then printf "%.1fk" "$(echo "$n / 1000"    | bc -l)"
  else echo "$n"
  fi
}

# ─── Elapsed time formatter ───────────────────────────────────────────────────
fmt_age() {
  local s="${1:-0}"
  if   [ "$s" -lt 60   ]; then echo "${s}s"
  elif [ "$s" -lt 3600 ]; then echo "$(( s / 60 ))m"
  else                          echo "$(( s / 3600 ))h"
  fi
}

# ─── Claude token usage (last 24 h, from JSONL session files) ─────────────────
get_token_stats() {
  python3 - <<'PY' 2>/dev/null || echo "in:—  out:—  cache:—"
import json, os, glob, time

cutoff = time.time() - 86400
totals = {"input": 0, "output": 0, "cache_r": 0}

for path in glob.glob(os.path.expanduser("~/.claude/projects/**/*.jsonl"), recursive=True):
    try:
        if os.path.getmtime(path) < cutoff:
            continue
        with open(path) as f:
            for line in f:
                try:
                    d = json.loads(line)
                    u = d.get("message", {}).get("usage", {})
                    if u:
                        totals["input"]   += u.get("input_tokens", 0)
                        totals["output"]  += u.get("output_tokens", 0)
                        totals["cache_r"] += u.get("cache_read_input_tokens", 0)
                except Exception:
                    pass
    except Exception:
        pass

def fmt(n):
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000:     return f"{n/1_000:.1f}k"
    return str(n)

print(f"in:{fmt(totals['input'])}  out:{fmt(totals['output'])}  cache:{fmt(totals['cache_r'])}")
PY
}

# ─── Active session count (JSONL files modified in last 30 min) ───────────────
get_session_count() {
  local now count=0
  now=$(date +%s)
  while IFS= read -r -d '' f; do
    local mtime age
    mtime=$(stat -f %m "$f" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    [ "$age" -lt 1800 ] && (( count++ )) || true
  done < <(find ~/.claude/projects -name "*.jsonl" -print0 2>/dev/null)
  echo "$count"
}

# ─── Claude process count ─────────────────────────────────────────────────────
get_claude_procs() {
  ps aux 2>/dev/null \
    | awk '/claude/ && !/grep/ && !/monitor/ && !/update-borders/ { c++ } END { print c+0 }'
}

# ─── Agent status (hash-based activity detection) ─────────────────────────────
get_agent_status() {
  local pane_id="$1" now="$2"

  # Capture last 30 lines, strip ANSI
  local content
  content=$(tmux capture-pane -t "$pane_id" -p -S -30 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b[()][AB012]//g')

  # Track changes via content hash
  local hash_file="$SNAP_DIR/${pane_id}.hash"
  local ts_file="$SNAP_DIR/${pane_id}.ts"
  local cur_hash age_str="?"

  cur_hash=$(printf '%s' "$content" | md5)
  local prev_hash=""
  [ -f "$hash_file" ] && prev_hash=$(cat "$hash_file")

  if [ "$cur_hash" != "$prev_hash" ]; then
    printf '%s' "$cur_hash" > "$hash_file"
    printf '%s' "$now"      > "$ts_file"
  fi

  if [ -f "$ts_file" ]; then
    local last_ts; last_ts=$(cat "$ts_file")
    age_str=$(fmt_age $(( now - last_ts )))
  fi

  # Determine status
  local icon status
  if printf '%s' "$content" | grep -qE '⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏'; then
    icon="${C_CYN}●${C_RST}"; status="thinking"
  elif printf '%s' "$content" | grep -qE 'esc.*cancel|Press.*cancel'; then
    icon="${C_CYN}●${C_RST}"; status="running"
  elif printf '%s' "$content" | grep -qE '✓ (Bash|Edit|Write|Read|Glob|Grep|Agent|WebFetch)'; then
    local tool
    tool=$(printf '%s' "$content" \
      | grep -oE '✓ (Bash|Edit|Write|Read|Glob|Grep|Agent|WebFetch)' \
      | tail -1 | awk '{print $2}')
    icon="${C_GRN}●${C_RST}"; status="✓ $tool"
  elif printf '%s' "$content" | grep -qE '[Ee]rror|[Ff]ailed|✗'; then
    icon="${C_RED}●${C_RST}"; status="error"
  elif printf '%s' "$content" | tail -2 | grep -qE '(❯|>|\$)\s*$'; then
    local last_ts_val=0
    [ -f "$ts_file" ] && last_ts_val=$(cat "$ts_file")
    if [ $(( now - last_ts_val )) -lt 10 ]; then
      icon="${C_YEL}●${C_RST}"; status="waiting"
    else
      icon="${C_GRY}●${C_RST}"; status="idle"
    fi
  else
    icon="${C_GRY}●${C_RST}"; status="idle"
  fi

  # Last meaningful line
  local last_msg
  last_msg=$(printf '%s' "$content" \
    | grep -vE '^\s*(╰─❯|❯|>|\$)?\s*$' \
    | tail -1 \
    | cut -c1-30)

  printf "%s|%s|%s|%s" "$icon" "$status" "$age_str" "$last_msg"
}

# ─── Header ───────────────────────────────────────────────────────────────────
print_header() {
  local cols; cols=$(tput cols 2>/dev/null || echo 60)
  local sep; sep=$(printf '─%.0s' $(seq 1 "$cols"))
  local now_str; now_str=$(date '+%Y-%m-%d  %H:%M:%S')
  local procs; procs=$(get_claude_procs)
  local sessions; sessions=$(get_session_count)
  local tokens; tokens=$(get_token_stats)
  local project; project=$(basename "$(tmux display-message \
    -t "$SESSION:$WINDOW" -p "#{pane_current_path}" 2>/dev/null || echo unknown)")

  printf "${C_BLD}${C_BLU}  🎼  claude-tmux-grid${C_RST}${C_GRY}  %s\n${C_RST}" "$now_str"
  printf "${C_GRY}%s${C_RST}\n" "$sep"
  printf "  ${C_DIM}Project:${C_RST} ${C_WHT}%-18s${C_RST}" "$project"
  printf "  ${C_DIM}Procs:${C_RST} ${C_WHT}%s${C_RST}" "$procs"
  printf "  ${C_DIM}Sessions:${C_RST} ${C_WHT}%s${C_RST}\n" "$sessions"
  printf "  ${C_DIM}Tokens (24h):${C_RST}  ${C_CYN}%s${C_RST}\n" "$tokens"
  printf "${C_GRY}%s${C_RST}\n" "$sep"
}

# ─── Agent table ──────────────────────────────────────────────────────────────
print_agents() {
  local now="$1"

  printf "  ${C_BLD}%-16s %-4s %-12s %-6s  %s${C_RST}\n" \
    "AGENT" "  " "STATUS" "AGO" "LAST OUTPUT"
  printf "${C_GRY}  %-16s %-4s %-12s %-6s  %s${C_RST}\n" \
    "────────────────" "────" "────────────" "──────" "──────────────────────────────"

  if [ ! -f "$CONF_FILE" ]; then
    printf "  ${C_YEL}Config not found: %s${C_RST}\n" "$CONF_FILE"
    return
  fi

  while IFS='=' read -r pane_id agent; do
    [[ "$pane_id" == "MONITOR_PANE" || "$pane_id" =~ ^# || -z "$agent" ]] && continue

    local info icon status age last_msg
    info=$(get_agent_status "$pane_id" "$now")
    IFS='|' read -r icon status age last_msg <<< "$info"

    printf "  %-16s %b  %-12s %-6s  ${C_DIM}%s${C_RST}\n" \
      "$agent" "$icon" "$status" "$age" "$last_msg"
  done < "$CONF_FILE"
}

# ─── Footer ───────────────────────────────────────────────────────────────────
print_footer() {
  local cols; cols=$(tput cols 2>/dev/null || echo 60)
  local sep; sep=$(printf '─%.0s' $(seq 1 "$cols"))
  printf "${C_GRY}%s${C_RST}\n" "$sep"
  printf "  ${C_DIM}Refresh: ${REFRESH}s  │  Ctrl-C to quit  │  "
  printf "${C_CYN}●${C_RST}${C_DIM} thinking  "
  printf "${C_GRN}●${C_RST}${C_DIM} working  "
  printf "${C_YEL}●${C_RST}${C_DIM} waiting  "
  printf "${C_GRY}●${C_RST}${C_DIM} idle${C_RST}\n"
}

# ─── Main loop ────────────────────────────────────────────────────────────────
trap 'tput cnorm; echo; exit 0' INT TERM
tput civis

tmux set-option -t "$SESSION" monitor-activity on 2>/dev/null || true
tmux set-option -t "$SESSION" activity-action none 2>/dev/null || true

while true; do
  local_now=$(date +%s)
  clear
  print_header
  echo
  print_agents "$local_now"
  echo
  print_footer

  # Update pane border titles with todo progress
  if [ -f "$SCRIPT_DIR/update-borders.sh" ]; then
    bash "$SCRIPT_DIR/update-borders.sh" \
      -s "$SESSION" -w "$WINDOW" -c "$CONF_FILE" 2>/dev/null || true
  fi

  sleep "$REFRESH"
done
