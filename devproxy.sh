#!/usr/bin/env bash
# devproxy.sh — manages the containerised toolchain proxies
# Usage: devproxy <command>
#   list       Show installed proxies and their status
#   update     Re-download and reinstall all proxy scripts
#   uninstall  Remove all proxies and clean up the shell profile

set -euo pipefail

INSTALL_URL="${REPO_BASE_URL:-https://raw.githubusercontent.com/OWNER/REPO/main}/install.sh"
INSTALL_DIR="$HOME/.local/bin/devproxy"
MARKER_START="# >>> devproxy >>>"
MARKER_END="# <<< devproxy <<<"

# Load central config
[ -f "$HOME/.devproxy" ] && source "$HOME/.devproxy"

detect_profile() {
  case "${SHELL:-}" in
    */zsh)  echo "$HOME/.zshrc" ;;
    */bash) echo "$HOME/.bashrc" ;;
    *)      echo "$HOME/.profile" ;;
  esac
}

cmd_list() {
  echo "Installed proxies in $INSTALL_DIR:"
  echo ""
  for name in go npm; do
    path="$INSTALL_DIR/$name"
    if [ -x "$path" ]; then
      echo "  ✓ $name  →  $path"
    else
      echo "  ✗ $name  (not installed)"
    fi
  done
  echo ""
  echo "Environment:"
  echo "  GO_BINARY=${GO_BINARY:-  (not set)}"
  echo "  NPM_BINARY=${NPM_BINARY:- (not set)}"
  echo "  CONTAINER_RUNTIME=${CONTAINER_RUNTIME:- (auto-detect)}"
}

cmd_update() {
  echo "Updating proxies..."
  curl -fsSL "$INSTALL_URL" | bash
}

cmd_uninstall() {
  echo "Removing proxy scripts..."
  rm -f "$INSTALL_DIR/go" "$INSTALL_DIR/npm" "$INSTALL_DIR/npx" "$INSTALL_DIR/devproxy"
  rmdir "$INSTALL_DIR" 2>/dev/null && echo "Removed $INSTALL_DIR" || true

  PROFILE="$(detect_profile)"
  if grep -qF "$MARKER_START" "$PROFILE" 2>/dev/null; then
    echo "Cleaning up $PROFILE..."
    awk -v start="$MARKER_START" -v end="$MARKER_END" '
      $0 == start { skip=1; next }
      $0 == end   { skip=0; next }
      !skip        { print }
    ' "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
    echo "Removed devproxy block from $PROFILE"
  fi

  echo ""
  echo "Done. Run: source $PROFILE"
}

case "${1:-}" in
  list)      cmd_list ;;
  update)    cmd_update ;;
  uninstall) cmd_uninstall ;;
  *)
    echo "Usage: devproxy <command>"
    echo ""
    echo "Commands:"
    echo "  list       Show installed proxies and their status"
    echo "  update     Re-download and reinstall all proxy scripts"
    echo "  uninstall  Remove all proxies and clean up the shell profile"
    exit 1
    ;;
esac
