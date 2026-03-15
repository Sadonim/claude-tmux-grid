#!/usr/bin/env bash
# =============================================================================
# claude-tmux-grid example: quickstart
# Creates a tmux session with 4 Claude agents and a monitor pane
# =============================================================================

SESSION="demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Create session if it doesn't exist
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION"
  echo "Created session: $SESSION"
fi

# Create agent windows (each agent runs in its own window, then gets
# pulled into the overview layout by auto-layout.sh)
for AGENT in ARCHITECT DESIGNER TESTER REVIEWER; do
  if ! tmux list-windows -t "$SESSION" -F "#{window_name}" | grep -q "^${AGENT}$"; then
    tmux new-window -t "$SESSION" -n "$AGENT" -d
    # In real usage, you'd launch Claude here:
    # tmux send-keys -t "$SESSION:$AGENT" "claude --model claude-sonnet-4-6" Enter
    tmux send-keys -t "$SESSION:$AGENT" "echo 'Agent $AGENT ready'" Enter
  fi
done

# Build the overview layout
bash "$SCRIPT_DIR/auto-layout.sh" \
  -s "$SESSION" \
  -w overview \
  ARCHITECT DESIGNER TESTER REVIEWER

echo ""
echo "Attach to session:"
echo "  tmux attach-session -t $SESSION"
