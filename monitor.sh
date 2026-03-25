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

# ─── System resources (macOS / Apple Silicon) ─────────────────────────────────
get_cpu_pct() {
  local cores; cores=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)
  ps -A -o %cpu 2>/dev/null \
    | awk -v c="$cores" 'NR>1 {s+=$1} END {v=s/c; printf "%.0f", (v>100?100:v)}'
}

get_ram_info() {
  # Returns "used_gb total_gb pct"
  local total_bytes page_size
  total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
  vm_stat 2>/dev/null | awk \
    -v total="$total_bytes" -v ps="$page_size" '
    /Pages active/     { active=$3+0 }
    /Pages wired down/ { wired=$4+0 }
    END {
      used = (active+wired)*ps
      total_gb = total/1073741824
      used_gb  = used/1073741824
      pct      = (total>0) ? used/total*100 : 0
      printf "%.1f %.0f %.0f", used_gb, total_gb, pct
    }'
}

get_gpu_pct() {
  # Apple Silicon: IOAccelerator Device Utilization (no sudo needed)
  local v
  v=$(ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null \
      | grep '"Device Utilization %"' \
      | awk -F'= ' '{print $2+0}' | head -1)
  printf '%s' "${v:-0}"
}

# ─── Percentage → mini progress bar ───────────────────────────────────────────
make_pct_bar() {
  local pct="${1:-0}" width="${2:-8}" bar="" i
  local filled=$(( pct * width / 100 ))
  [ "$filled" -gt "$width" ] && filled="$width"
  for i in $(seq 1 "$width"); do
    [ "$i" -le "$filled" ] && bar="${bar}█" || bar="${bar}░"
  done
  echo "$bar"
}

# ─── Claude process count ─────────────────────────────────────────────────────
get_claude_procs() {
  ps aux 2>/dev/null \
    | awk '/claude/ && !/grep/ && !/monitor/ && !/update-borders/ { c++ } END { print c+0 }'
}

# ─── Display-width-aware truncation (handles CJK double-width characters) ────
# Usage: trunc_display "string" max_display_cols
trunc_display() {
  printf '%s' "$1" | python3 -c "
import sys, unicodedata
s = sys.stdin.read().rstrip('\n')
limit = int(sys.argv[1])
w, total = [], 0
for c in s:
    cw = 2 if unicodedata.east_asian_width(c) in ('W','F') else 1
    if total + cw > limit: break
    w.append(c); total += cw
sys.stdout.write(''.join(w))
" "$2" 2>/dev/null || printf '%s' "$1" | cut -c1-"$2"
}

# ─── Project directory (detected once, cached) ───────────────────────────────
PROJ_DIR=""

detect_proj_dir() {
  local cache="$SNAP_DIR/proj_dir.cache"
  if [ -f "$cache" ]; then PROJ_DIR=$(cat "$cache"); return; fi
  local pane_id
  pane_id=$(grep '^%' "$CONF_FILE" 2>/dev/null | head -1 | cut -d= -f1)
  local cwd=""
  [ -n "$pane_id" ] && cwd=$(tmux display-message -t "$pane_id" -p "#{pane_current_path}" 2>/dev/null || true)
  printf '%s' "$cwd" > "$cache"
  PROJ_DIR="$cwd"
}

# ─── Current feature from Level 3 handoff ─────────────────────────────────────
get_current_feature() {
  local handoffs_dir="${PROJ_DIR}/docs/handoffs"
  [ -d "$handoffs_dir" ] || { echo ""; return; }
  local latest_file
  latest_file=$(ls -t "${handoffs_dir}"/*.md 2>/dev/null | grep -v signals | head -1)
  [ -z "$latest_file" ] && { echo ""; return; }
  grep "^FEATURE:" "$latest_file" 2>/dev/null | head -1 | cut -d: -f2- | sed 's/^ //'
}

# ─── Level 2: .done signal check ─────────────────────────────────────────────
# Returns "SUMMARY_TEXT" if a .done file exists for this agent, else ""
get_level2_done() {
  local agent="$1"
  local signals_dir="${PROJ_DIR}/docs/handoffs/signals"
  [ -d "$signals_dir" ] || return

  local current_feature done_file
  current_feature=$(get_current_feature)

  if [ -n "$current_feature" ]; then
    # Only accept .done for the current active feature
    done_file="${signals_dir}/${agent}_${current_feature}.done"
    [ -f "$done_file" ] || return
  else
    # Fallback: use latest .done if feature can't be determined
    done_file=$(ls "${signals_dir}/${agent}_"*.done 2>/dev/null | tail -1)
    [ -z "$done_file" ] && return
  fi

  local summary feature
  feature=$(grep "^FEATURE:" "$done_file" 2>/dev/null | cut -d: -f2- | sed 's/^ //')
  summary=$(grep "^SUMMARY:" "$done_file" 2>/dev/null | cut -d: -f2- | sed 's/^ //' | cut -c1-35)
  printf "%s (%s)" "$summary" "$feature"
}

# ─── Level 3: latest pipeline status from handoff files ──────────────────────
get_level3_status() {
  local handoffs_dir="${PROJ_DIR}/docs/handoffs"
  [ -d "$handoffs_dir" ] || { echo ""; return; }
  local latest_file status feature
  latest_file=$(ls -t "${handoffs_dir}"/*.md 2>/dev/null | grep -v signals | head -1)
  [ -z "$latest_file" ] && { echo ""; return; }
  status=$(grep "^STATUS:" "$latest_file" 2>/dev/null | head -1 | cut -d: -f2- | sed 's/^ //')
  feature=$(basename "$latest_file" .md | sed 's/_[0-9-]*$//')
  [ -n "$status" ] && printf "%s  [%s]" "$status" "$feature" || echo ""
}

# ─── Level 1: TodoWrite + last tool from JSONL (timestamp-matched, cached) ───
# Runs once per refresh cycle — writes SNAP_DIR/todo_cache.txt
refresh_todo_cache() {
  python3 - "$PROJ_DIR" "$SNAP_DIR" <<'PY' 2>/dev/null || true
import json, os, glob, sys

proj_dir, snap_dir = sys.argv[1], sys.argv[2]
cwd_encoded = proj_dir.replace('/', '-').lstrip('-')
claude_proj = os.path.expanduser(f"~/.claude/projects/{cwd_encoded}")

files = sorted(glob.glob(claude_proj + "/*.jsonl"), key=os.path.getmtime, reverse=True)[:16]

lines_out = []
for f in files:
    mtime = os.path.getmtime(f)
    todos, last_tool = None, ""
    try:
        with open(f) as fp:
            lines = fp.readlines()
        for line in reversed(lines):
            try:
                d = json.loads(line)
                for block in d.get("message", {}).get("content", []):
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    name = block.get("name", "")
                    inp  = block.get("input", {})
                    if name == "TodoWrite" and todos is None:
                        todos = inp.get("todos", [])
                    if not last_tool and name in ("Edit", "Write", "Bash", "Read"):
                        if name in ("Edit", "Write"):
                            last_tool = f"{name}:{os.path.basename(inp.get('file_path',''))}"
                        elif name == "Bash":
                            last_tool = f"Bash:{inp.get('command','')[:28]}"
                        elif name == "Read":
                            last_tool = f"Read:{os.path.basename(inp.get('file_path',''))}"
            except: pass
    except: pass

    if todos:
        done  = sum(1 for t in todos if t.get("status") == "completed")
        total = len(todos)
        inprog = next((t.get("title", "")[:28]
                       for t in todos if t.get("status") == "in_progress"), "")
        todo_str = f"{done}/{total}✓ {inprog}"
    else:
        todo_str = ""
    lines_out.append(f"{mtime:.0f}|{todo_str}|{last_tool}")

with open(os.path.join(snap_dir, "todo_cache.txt"), "w") as fp:
    fp.write("\n".join(lines_out))
PY
}

# Match a pane's last-change timestamp to the closest JSONL entry in the cache.
# Returns todo_str if available, else last_tool.
get_cached_action() {
  local ts_file="$SNAP_DIR/${1}.ts"
  local cache="$SNAP_DIR/todo_cache.txt"
  [ -f "$cache" ] && [ -f "$ts_file" ] || return
  python3 - "$cache" "$(cat "$ts_file")" <<'PY' 2>/dev/null || true
import sys
cache_path, pane_ts = sys.argv[1], float(sys.argv[2])
best_diff, best = float('inf'), ""
try:
    for line in open(cache_path):
        parts = line.strip().split("|", 2)
        if len(parts) < 3: continue
        diff = abs(float(parts[0]) - pane_ts)
        if diff < best_diff:
            best_diff, best = diff, parts[1] if parts[1] else parts[2]
except: pass
if best: print(best[:40])
PY
}

# ─── Claude UI chrome patterns to strip ───────────────────────────────────────
# These lines appear in Claude Code's TUI but carry no meaningful content.
CLAUDE_CHROME_RE='^\s*$|^\s*(╰─❯|❯|>|\$)\s*$|esc to interrupt|\? for shortcuts|[0-9]+% until auto-compact|^\s*[*✻✼] *[A-Za-z]+ for [0-9]|ctrl\+[a-z] to |running in the background|──────'

# ─── Agent status (hash-based activity detection) ─────────────────────────────
get_agent_status() {
  local pane_id="$1" now="$2" agent_name="${3:-}"

  # Capture recent scroll buffer (100 lines) — more history for better last-msg
  local content
  content=$(tmux capture-pane -t "$pane_id" -p -S -100 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b[()][AB012]//g; s/\x1b\[[0-9;]*[ABCD]//g')

  # Track changes via content hash (use full buffer so even small changes register)
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

  # Status detection uses only the current visible screen (last 30 lines).
  # Priority: approval > thinking > running (esc to interrupt) > tool done > error > idle
  local visible
  visible=$(printf '%s' "$content" | tail -30)

  local icon status
  if printf '%s' "$visible" | grep -qE '^\s*Allow\s*$' && \
     printf '%s' "$visible" | grep -qE '^\s*Deny\s*$'; then
    # Claude Code permission dialog: "Allow" and "Deny" appear as separate selectable lines
    icon="${C_YEL}!${C_RST}"; status="approval"
  elif printf '%s' "$visible" | grep -qE '⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏'; then
    icon="${C_CYN}●${C_RST}"; status="thinking"
  elif printf '%s' "$visible" | grep -qE 'esc to interrupt|esc.*cancel|Press.*cancel'; then
    # "esc to interrupt" is Claude Code's definitive "I am running" signal
    icon="${C_CYN}●${C_RST}"; status="running"
  elif printf '%s' "$visible" | grep -qE '✓ (Bash|Edit|Write|Read|Glob|Grep|Agent|WebFetch|Task)'; then
    local tool
    tool=$(printf '%s' "$visible" \
      | grep -oE '✓ (Bash|Edit|Write|Read|Glob|Grep|Agent|WebFetch|Task)' \
      | tail -1 | awk '{print $2}')
    icon="${C_GRN}●${C_RST}"; status="✓ $tool"
  elif printf '%s' "$visible" | grep -qE '[Ee]rror|[Ff]ailed|✗'; then
    icon="${C_RED}●${C_RST}"; status="error"
  elif printf '%s' "$visible" | tail -3 | grep -qE '(❯|╰─❯|>|\$)\s*$'; then
    local last_ts_val=0
    [ -f "$ts_file" ] && last_ts_val=$(cat "$ts_file")
    if [ $(( now - last_ts_val )) -lt 30 ]; then
      icon="${C_YEL}●${C_RST}"; status="done"
    else
      icon="${C_GRY}●${C_RST}"; status="idle"
    fi
  else
    local last_ts_val=0
    [ -f "$ts_file" ] && last_ts_val=$(cat "$ts_file")
    if [ $(( now - last_ts_val )) -lt 15 ]; then
      icon="${C_CYN}●${C_RST}"; status="running"
    else
      icon="${C_GRY}●${C_RST}"; status="idle"
    fi
  fi

  # ── Level 2: .done signal — only when agent is not actively working ────────
  local done_summary
  done_summary=$(get_level2_done "$agent_name" 2>/dev/null || true)
  if [ -n "$done_summary" ] && [[ "$status" != "thinking" && "$status" != "running" ]]; then
    printf "%b|%s|%s|%s" "${C_GRN}●${C_RST}" "DONE" "$age_str" "$done_summary"
    return
  fi

  # ── Level 1 / JSONL: todo progress or last tool (timestamp-matched cache) ──
  local cached_action
  cached_action=$(get_cached_action "$pane_id" 2>/dev/null || true)

  # ── Pane-based fallback: last tool call visible in scroll buffer ────────────
  local last_msg="$cached_action"
  if [ -z "$last_msg" ]; then
    last_msg=$(printf '%s' "$content" \
      | grep -oE '(● |✓ )(Bash|Edit|Write|Read|Glob|Grep|Agent|WebFetch|Task)\([^)]{1,50}\)' \
      | tail -1 \
      | sed 's/^● //; s/^✓ /✓ /' \
      | cut -c1-40)
  fi
  if [ -z "$last_msg" ]; then
    last_msg=$(printf '%s' "$content" \
      | grep -vE "$CLAUDE_CHROME_RE" \
      | sed 's/^[[:space:]]*//' \
      | grep -v '^[[:space:]]*$' \
      | tail -1 \
      | cut -c1-40)
  fi

  printf "%s|%s|%s|%s" "$icon" "$status" "$age_str" "$last_msg"
}

# ─── Header ───────────────────────────────────────────────────────────────────
print_header() {
  local monitor_pane; monitor_pane=$(grep "^MONITOR_PANE=" "$CONF_FILE" 2>/dev/null | cut -d= -f2)
  local cols; cols=$(tmux display-message -t "${monitor_pane}" -p "#{pane_width}" 2>/dev/null || tput cols 2>/dev/null || echo 60)
  local sep; sep=$(printf '─%.0s' $(seq 1 "$cols"))
  local now_str; now_str=$(date '+%Y-%m-%d  %H:%M:%S')
  local procs; procs=$(get_claude_procs)
  local sessions; sessions=$(get_session_count)
  local tokens; tokens=$(get_token_stats)
  local project; project=$(basename "$(tmux display-message \
    -t "$SESSION:$WINDOW" -p "#{pane_current_path}" 2>/dev/null || echo unknown)")

  printf "${C_BLD}${C_BLU}  claude-tmux-grid${C_RST}${C_GRY}  %s\n${C_RST}" "$now_str"
  printf "${C_GRY}%s${C_RST}\n" "$sep"
  printf "  ${C_DIM}Project:${C_RST} ${C_WHT}%-18s${C_RST}" "$project"
  printf "  ${C_DIM}Procs:${C_RST} ${C_WHT}%s${C_RST}" "$procs"
  printf "  ${C_DIM}Sessions:${C_RST} ${C_WHT}%s${C_RST}\n" "$sessions"
  printf "  ${C_DIM}Tokens (24h):${C_RST}  ${C_CYN}%s${C_RST}\n" "$tokens"

  # ── System resources ──────────────────────────────────────────────────────
  local cpu cpu_bar ram_info used_gb total_gb ram_pct ram_bar gpu gpu_bar
  cpu=$(get_cpu_pct)
  cpu_bar=$(make_pct_bar "$cpu" 8)
  read -r used_gb total_gb ram_pct <<< "$(get_ram_info)"
  ram_bar=$(make_pct_bar "$ram_pct" 8)
  gpu=$(get_gpu_pct)
  gpu_bar=$(make_pct_bar "$gpu" 8)
  printf "  ${C_DIM}CPU${C_RST} ${C_CYN}%s${C_RST} ${C_WHT}%3s%%${C_RST}  " "$cpu_bar" "$cpu"
  printf "${C_DIM}RAM${C_RST} ${C_CYN}%s${C_RST} ${C_WHT}%s/%sGB${C_RST}  " "$ram_bar" "$used_gb" "$total_gb"
  printf "${C_DIM}GPU${C_RST} ${C_CYN}%s${C_RST} ${C_WHT}%3s%%${C_RST}\n"   "$gpu_bar" "$gpu"

  local pipeline; pipeline=$(get_level3_status 2>/dev/null || true)
  if [ -n "$pipeline" ]; then
    printf "  ${C_DIM}Pipeline:${C_RST}      ${C_YEL}%s${C_RST}\n" "$pipeline"
  fi
  printf "${C_GRY}%s${C_RST}\n" "$sep"
}

# ─── Format LAST ACTION column (tool icons + colour) ─────────────────────────
# Usage: format_last_action "msg" "status" width
# Outputs coloured string (no trailing newline)
format_last_action() {
  local msg="$1" status="$2" width="${3:-30}"

  # Approval state: override with urgent prompt
  if [ "$status" = "approval" ]; then
    printf '%b! awaiting approval%b' "$C_YEL" "$C_RST"
    return
  fi

  # icon_w: display width consumed by the prefix badge (icon + label + padding)
  local prefix text icon_w=9
  case "$msg" in
    Edit:*)   prefix="${C_BLU}✎ Edit${C_RST}  "; text="${msg#Edit:}"  ;;
    Write:*)  prefix="${C_GRN}✎ Write${C_RST} "; text="${msg#Write:}" ;;
    Bash:*)   prefix="${C_YEL}⚡ Bash${C_RST} ";  text="${msg#Bash:}"  ;;
    Read:*)   prefix="${C_GRY}≡ Read${C_RST}  "; text="${msg#Read:}"  ;;
    *"✓"*)    prefix="${C_GRN}✓ ${C_RST}"; icon_w=2; text="$msg"      ;;
    *)        prefix="${C_DIM}";           icon_w=0; text="$msg"       ;;
  esac

  local text_w=$(( width - icon_w ))
  [ "$text_w" -lt 4 ] && text_w=4
  local t; t=$(trunc_display "$text" "$text_w")
  printf '%b%s%b' "$prefix" "$t" "$C_RST"
}

# ─── Agent table ──────────────────────────────────────────────────────────────
print_agents() {
  local now="$1"
  local monitor_pane; monitor_pane=$(grep "^MONITOR_PANE=" "$CONF_FILE" 2>/dev/null | cut -d= -f2)
  # Fixed columns take 45 chars ("  %-16s %-4s %-12s %-6s  "), rest goes to LAST ACTION
  local pane_w; pane_w=$(tmux display-message -t "${monitor_pane}" -p "#{pane_width}" 2>/dev/null || echo 80)
  local action_w=$(( pane_w - 45 ))
  [ "$action_w" -lt 10 ] && action_w=10
  local action_sep; action_sep=$(printf '─%.0s' $(seq 1 "$action_w"))

  printf "  ${C_BLD}%-16s %-4s %-12s %-6s  %s${C_RST}\n" \
    "AGENT" "  " "STATUS" "AGO" "LAST ACTION"
  printf "${C_GRY}  %-16s %-4s %-12s %-6s  %s${C_RST}\n" \
    "────────────────" "────" "────────────" "──────" "$action_sep"

  if [ ! -f "$CONF_FILE" ]; then
    printf "  ${C_YEL}Config not found: %s${C_RST}\n" "$CONF_FILE"
    return
  fi

  while IFS='=' read -r pane_id agent; do
    [[ "$pane_id" == "MONITOR_PANE" || "$pane_id" =~ ^# || -z "$agent" || "$pane_id" =~ ^LAYOUT_ ]] && continue

    local info icon status age last_msg
    info=$(get_agent_status "$pane_id" "$now" "$agent")
    IFS='|' read -r icon status age last_msg <<< "$info"

    # Persist status for update-borders.sh (border colour sync)
    printf '%s' "$status" > "/tmp/claude-agent-status/$agent" 2>/dev/null || true

    printf "  %-16s %b  %-12s %-6s  " "$agent" "$icon" "$status" "$age"
    format_last_action "$last_msg" "$status" "$action_w"
    printf '\n'
  done < "$CONF_FILE"
}

# ─── Pipeline flow (one-line agent status summary) ────────────────────────────
print_pipeline_flow() {
  local status_dir="/tmp/claude-agent-status"
  local parts=() s icon short agent pane_id

  while IFS='=' read -r pane_id agent; do
    [[ "$pane_id" == "MONITOR_PANE" || "$pane_id" =~ ^# || -z "$agent" || "$pane_id" =~ ^LAYOUT_ ]] && continue
    s=""
    [ -f "$status_dir/$agent" ] && s=$(cat "$status_dir/$agent")
    case "$s" in
      thinking|running) icon="${C_CYN}●${C_RST}" ;;
      approval)         icon="${C_YEL}!${C_RST}" ;;
      done|DONE)        icon="${C_GRN}✓${C_RST}" ;;
      error)            icon="${C_RED}✗${C_RST}" ;;
      "✓"*)             icon="${C_GRN}✓${C_RST}" ;;
      *)                icon="${C_GRY}○${C_RST}" ;;
    esac
    short=$(printf '%.4s' "$agent")
    parts+=("${icon}${C_DIM}${short}${C_RST}")
  done < "$CONF_FILE"

  local flow="" part
  for part in "${parts[@]}"; do
    [ -n "$flow" ] && flow="${flow}${C_GRY}→${C_RST}"
    flow="${flow}${part} "
  done
  [ -n "$flow" ] && printf "  %b\n" "$flow"
}

# ─── Footer ───────────────────────────────────────────────────────────────────
print_footer() {
  local monitor_pane; monitor_pane=$(grep "^MONITOR_PANE=" "$CONF_FILE" 2>/dev/null | cut -d= -f2)
  local cols; cols=$(tmux display-message -t "${monitor_pane}" -p "#{pane_width}" 2>/dev/null || tput cols 2>/dev/null || echo 60)
  local sep; sep=$(printf '─%.0s' $(seq 1 "$cols"))
  printf "${C_GRY}%s${C_RST}\n" "$sep"
  printf "  ${C_DIM}R:${REFRESH}s  C-c quit  │  "
  printf "${C_CYN}●${C_RST}${C_DIM} think  "
  printf "${C_GRN}●${C_RST}${C_DIM} run  "
  printf "${C_YEL}●${C_RST}${C_DIM} done  "
  printf "${C_GRY}●${C_RST}${C_DIM} idle  "
  printf "${C_RED}●${C_RST}${C_DIM} err${C_RST}\n"
}

# ─── Main loop ────────────────────────────────────────────────────────────────
trap 'tput cnorm; echo; exit 0' INT TERM
tput civis

tmux set-option -t "$SESSION" monitor-activity on 2>/dev/null || true
tmux set-option -t "$SESSION" activity-action none 2>/dev/null || true

# Detect project directory once at startup
detect_proj_dir

while true; do
  local_now=$(date +%s)
  # Refresh JSONL todo cache once per cycle (Level 1 signal)
  refresh_todo_cache
  clear
  print_header
  echo
  print_agents "$local_now"
  echo
  print_pipeline_flow
  print_footer

  # Update pane border titles with todo progress
  if [ -f "$SCRIPT_DIR/update-borders.sh" ]; then
    bash "$SCRIPT_DIR/update-borders.sh" \
      -s "$SESSION" -w "$WINDOW" -c "$CONF_FILE" 2>/dev/null || true
  fi

  sleep "$REFRESH"
done
