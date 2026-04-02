#!/usr/bin/env bash
# install.sh — installs the containerised toolchain proxies
# Usage: curl -fsSL <url>/install.sh | bash
#        Can be re-run to update the proxy scripts in-place.

set -euo pipefail

# --- Configuration ---
REPO_BASE_URL="https://raw.githubusercontent.com/OWNER/REPO/main"
INSTALL_DIR="$HOME/.local/bin/devproxy"

# --- Detect shell profile ---
detect_profile() {
  case "${SHELL:-}" in
    */zsh)  echo "$HOME/.zshrc" ;;
    */bash) echo "$HOME/.bashrc" ;;
    *)      echo "$HOME/.profile" ;;
  esac
}

PROFILE="$(detect_profile)"
MARKER_START="# >>> devproxy >>>"
MARKER_END="# <<< devproxy <<<"

# --- Remove existing proxies so they don't shadow the real binaries during detection ---
rm -f "$INSTALL_DIR/go" "$INSTALL_DIR/npm" "$INSTALL_DIR/devproxy"

# --- Find the real binaries ---
GO_BINARY="$(command -v go 2>/dev/null || true)"
if [ -z "$GO_BINARY" ]; then
  echo "install: 'go' not found on PATH — install Go first" >&2
  exit 1
fi

NPM_BINARY="$(command -v npm 2>/dev/null || true)"
if [ -z "$NPM_BINARY" ]; then
  echo "install: 'npm' not found on PATH — install Node.js first" >&2
  exit 1
fi

echo "Using go binary:  $GO_BINARY"
echo "Using npm binary: $NPM_BINARY"

# --- Download proxy scripts ---
mkdir -p "$INSTALL_DIR"

echo "Downloading go proxy..."
curl -fsSL "$REPO_BASE_URL/goproxy.sh" -o "$INSTALL_DIR/go"
chmod +x "$INSTALL_DIR/go"

echo "Downloading npm proxy..."
curl -fsSL "$REPO_BASE_URL/npmproxy.sh" -o "$INSTALL_DIR/npm"
chmod +x "$INSTALL_DIR/npm"

echo "Downloading devproxy manager..."
curl -fsSL "$REPO_BASE_URL/devproxy.sh" -o "$INSTALL_DIR/devproxy"
chmod +x "$INSTALL_DIR/devproxy"

# --- Write shell profile block (idempotent via markers) ---
BLOCK="${MARKER_START}
export GO_BINARY=\"${GO_BINARY}\"
export NPM_BINARY=\"${NPM_BINARY}\"
export PATH=\"${INSTALL_DIR}:\$PATH\"
${MARKER_END}"

if grep -qF "$MARKER_START" "$PROFILE" 2>/dev/null; then
  # Replace the existing block in-place
  awk -v start="$MARKER_START" -v end="$MARKER_END" -v block="$BLOCK" '
    $0 == start { print block; skip=1; next }
    $0 == end   { skip=0; next }
    !skip        { print }
  ' "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
  echo "Updated existing devproxy config in $PROFILE"
else
  printf '\n%s\n' "$BLOCK" >> "$PROFILE"
  echo "Added devproxy config to $PROFILE"
fi

echo ""
echo "Done. To activate:"
echo "  source $PROFILE"
echo ""
echo "Then verify:"
echo "  go version"
echo "  npm --version"
