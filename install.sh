#!/usr/bin/env bash
# =============================================================================
# claude-tmux-grid: install.sh
# Installs scripts to ~/.config/tmux/claude-tmux-grid/
# and optionally adds a keybinding to ~/.tmux.conf
# =============================================================================

set -euo pipefail

INSTALL_DIR="$HOME/.config/tmux/claude-tmux-grid"
TMUX_CONF="$HOME/.tmux.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C_GRN='\033[32m'; C_YEL='\033[33m'; C_RST='\033[0m'; C_BLD='\033[1m'

echo ""
echo -e "${C_BLD}claude-tmux-grid installer${C_RST}"
echo "────────────────────────────────"
echo "Install directory: $INSTALL_DIR"
echo ""

# ─── Create install directory ─────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"

# ─── Copy scripts ─────────────────────────────────────────────────────────────
for script in auto-layout.sh monitor.sh update-borders.sh rebalance.sh; do
  if [ -f "$SCRIPT_DIR/$script" ]; then
    cp "$SCRIPT_DIR/$script" "$INSTALL_DIR/$script"
    chmod +x "$INSTALL_DIR/$script"
    echo -e "   ${C_GRN}✓${C_RST}  $script"
  else
    echo -e "   ${C_YEL}⚠${C_RST}  $script not found, skipping"
  fi
done

# ─── Create convenience wrapper in PATH ───────────────────────────────────────
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/claude-tmux-grid" <<EOF
#!/usr/bin/env bash
exec bash "$INSTALL_DIR/auto-layout.sh" "\$@"
EOF
chmod +x "$BIN_DIR/claude-tmux-grid"
echo -e "   ${C_GRN}✓${C_RST}  Wrapper → $BIN_DIR/claude-tmux-grid"

# ─── Optional: tmux.conf keybinding ───────────────────────────────────────────
echo ""
BIND_LINE="bind M-g run-shell \"bash $INSTALL_DIR/auto-layout.sh -s \\\$(tmux display-message -p '#S') -w grid\""

if [ -f "$TMUX_CONF" ] && grep -q "claude-tmux-grid" "$TMUX_CONF" 2>/dev/null; then
  echo -e "   ${C_YEL}⚠${C_RST}  tmux.conf keybinding already exists, skipping"
else
  echo "Add keybinding to $TMUX_CONF? (prefix + Alt-g) [y/N]"
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    cat >> "$TMUX_CONF" <<TMUXEOF

# claude-tmux-grid keybinding
$BIND_LINE
TMUXEOF
    echo -e "   ${C_GRN}✓${C_RST}  Added keybinding to $TMUX_CONF"
    echo "   Reload tmux config: tmux source-file ~/.tmux.conf"
  fi
fi

# ─── PATH hint ────────────────────────────────────────────────────────────────
if ! echo "$PATH" | grep -q "$BIN_DIR"; then
  echo ""
  echo -e "${C_YEL}Note:${C_RST} Add $BIN_DIR to your PATH if not already:"
  echo "   echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
fi

echo ""
echo -e "${C_GRN}✅  Installation complete!${C_RST}"
echo ""
echo "Usage:"
echo "  claude-tmux-grid -s SESSION AGENT1 AGENT2 AGENT3 ..."
echo "  claude-tmux-grid -s SESSION -f agents.txt"
echo "  bash $INSTALL_DIR/auto-layout.sh -h"
echo ""
