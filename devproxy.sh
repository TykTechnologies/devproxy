#!/usr/bin/env bash
# devproxy.sh — manages the containerised toolchain proxies
# Usage: devproxy <command>
#   list       Show installed proxies and their status
#   update     Re-download and reinstall all proxy scripts
#   uninstall  Remove all proxies and clean up the shell profile
#   nuke       uninstall + delete ~/.devproxy (prompts for confirmation)
#   enable     Comment out DEVPROXY_UNSECURE in ~/.devproxy (proxy active)
#   disable    Uncomment DEVPROXY_UNSECURE in ~/.devproxy (bypass proxy)

set -euo pipefail

INSTALL_URL="${REPO_BASE_URL:-https://raw.githubusercontent.com/TykTechnologies/devproxy/refs/heads/main}/install.sh"
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
  echo "  GODEV_SYNTHETIC_GOROOT=${GODEV_SYNTHETIC_GOROOT:- (not set)}"
}

cmd_update() {
  echo "Updating proxies..."
  curl -fsSL "$INSTALL_URL" | bash
}

cmd_uninstall() {
  echo "Removing proxy scripts..."
  rm -f "$INSTALL_DIR/go" "$INSTALL_DIR/npm" "$INSTALL_DIR/npx" "$INSTALL_DIR/devproxy"
  rmdir "$INSTALL_DIR" 2>/dev/null && echo "Removed $INSTALL_DIR" || true

  SYNTHETIC_GOROOT="${GODEV_SYNTHETIC_GOROOT:-$HOME/.local/share/devproxy/goroot}"
  if [ -d "$SYNTHETIC_GOROOT" ]; then
    rm -rf "$SYNTHETIC_GOROOT"
    echo "Removed synthetic GOROOT at $SYNTHETIC_GOROOT"
  fi

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

cmd_nuke() {
  echo "This will uninstall devproxy AND permanently delete $HOME/.devproxy."
  printf "Type 'yes' to confirm: "
  read -r _answer
  if [ "$_answer" != "yes" ]; then
    echo "Aborted."
    exit 1
  fi

  cmd_uninstall

  if [ -f "$HOME/.devproxy" ]; then
    rm -f "$HOME/.devproxy"
    echo "Removed $HOME/.devproxy"
  fi
}

cmd_enable() {
  local cfg="$HOME/.devproxy"
  if [ ! -f "$cfg" ]; then
    echo "devproxy: $cfg not found" >&2; exit 1
  fi
  if grep -qE '^# DEVPROXY_UNSECURE=' "$cfg"; then
    echo "Proxy already enabled (DEVPROXY_UNSECURE is commented out)."
    return
  fi
  sed -i.bak 's|^DEVPROXY_UNSECURE=|# DEVPROXY_UNSECURE=|' "$cfg" && rm -f "$cfg.bak"
  echo "Proxy enabled — DEVPROXY_UNSECURE commented out in $cfg"
}

cmd_disable() {
  local cfg="$HOME/.devproxy"
  if [ ! -f "$cfg" ]; then
    echo "devproxy: $cfg not found" >&2; exit 1
  fi
  if grep -qE '^DEVPROXY_UNSECURE=' "$cfg"; then
    echo "Proxy already disabled (DEVPROXY_UNSECURE is active)."
    return
  fi
  sed -i.bak 's|^# DEVPROXY_UNSECURE=|DEVPROXY_UNSECURE=|' "$cfg" && rm -f "$cfg.bak"
  echo "Proxy disabled — DEVPROXY_UNSECURE activated in $cfg"
}

case "${1:-}" in
  list)      cmd_list ;;
  update)    cmd_update ;;
  uninstall) cmd_uninstall ;;
  nuke)      cmd_nuke ;;
  enable)    cmd_enable ;;
  disable)   cmd_disable ;;
  *)
    echo "Usage: devproxy <command>"
    echo ""
    echo "Commands:"
    echo "  list       Show installed proxies and their status"
    echo "  update     Re-download and reinstall all proxy scripts"
    echo "  uninstall  Remove all proxies and clean up the shell profile"
    echo "  nuke       uninstall + delete ~/.devproxy (prompts for confirmation)"
    echo "  enable     Comment out DEVPROXY_UNSECURE (proxy active)"
    echo "  disable    Uncomment DEVPROXY_UNSECURE (bypass proxy)"
    exit 1
    ;;
esac
