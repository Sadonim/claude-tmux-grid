#!/usr/bin/env bash
# =============================================================================
# claude-tmux-grid example: 8 agents (full layout)
#
# Layout:
#   ┌──────────────────┬──────────┐
#   │                  │ARCHITECT │
#   │    Monitor       ├──────────┤
#   │                  │  CRITIC  │
#   ├───────┬──────────┼──────────┤
#   │DESIGN │  TESTER  │ SECURITY │
#   ├───────┼──────────┼──────────┤
#   │REFACT │  RUNNER  │ BACKEND  │
#   └───────┴──────────┴──────────┘
# =============================================================================

SESSION="${1:-uf-agents}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AGENTS=(ARCHITECT CRITIC DESIGNER TESTER SECURITY REFACTOR RUNNER BACKEND)

# Ensure session exists
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION"
  echo "Created session: $SESSION"
fi

# Create agent windows
for AGENT in "${AGENTS[@]}"; do
  if ! tmux list-windows -t "$SESSION" -F "#{window_name}" | grep -q "^${AGENT}$"; then
    tmux new-window -t "$SESSION" -n "$AGENT" -d
    # Uncomment to auto-launch Claude in each window:
    # tmux send-keys -t "$SESSION:$AGENT" \
    #   "cd /path/to/project && claude --model claude-sonnet-4-6" Enter
  fi
done

# Build overview layout
bash "$SCRIPT_DIR/auto-layout.sh" \
  -s "$SESSION" \
  -w overview \
  "${AGENTS[@]}"

echo "Attach: tmux attach-session -t $SESSION"
