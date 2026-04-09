#!/usr/bin/env bash
# install.sh — installs the containerised toolchain proxies
# Usage: curl -fsSL <url>/install.sh | bash
#        Can be re-run to update the proxy scripts in-place.

set -euo pipefail

# --- Configuration ---
REPO_BASE_URL="${REPO_BASE_URL:-https://raw.githubusercontent.com/TykTechnologies/devproxy/refs/heads/main}"
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
rm -f "$INSTALL_DIR/go" "$INSTALL_DIR/npm" "$INSTALL_DIR/npx" "$INSTALL_DIR/devproxy"

# --- Find the real binaries ---
GO_BINARY="$(command -v go 2>/dev/null || true)"
if [ -z "$GO_BINARY" ]; then
  echo "install: 'go' not found on PATH - install Go first" >&2
  exit 1
fi

NPM_BINARY="$(command -v npm 2>/dev/null || true)"
if [ -z "$NPM_BINARY" ]; then
  echo "install: 'npm' not found on PATH - install Node.js first" >&2
  exit 1
fi

NPX_BINARY="$(command -v npx 2>/dev/null || true)"
if [ -z "$NPX_BINARY" ]; then
  echo "install: 'npx' not found on PATH - install Node.js first" >&2
  exit 1
fi

echo "Using go binary:  $GO_BINARY"
echo "Using npm binary: $NPM_BINARY"
echo "Using npx binary: $NPX_BINARY"

# --- Create synthetic GOROOT for IDE integration (e.g. GoLand) ---
REAL_GOROOT="$("$GO_BINARY" env GOROOT)"
SYNTHETIC_GOROOT="$HOME/.local/share/devproxy/goroot"
mkdir -p "$SYNTHETIC_GOROOT/bin"
ln -sf "$INSTALL_DIR/go" "$SYNTHETIC_GOROOT/bin/go"
for dir in src pkg api; do
  [ -d "$REAL_GOROOT/$dir" ] && ln -sfn "$REAL_GOROOT/$dir" "$SYNTHETIC_GOROOT/$dir"
done
echo "Created synthetic GOROOT at $SYNTHETIC_GOROOT"

# --- Write ~/.devproxy config file (only on first install) ---
DEVPROXY_CONFIG="$HOME/.devproxy"
if [ -f "$DEVPROXY_CONFIG" ]; then
  echo "Config already exists at $DEVPROXY_CONFIG - leaving it unchanged"
else
  cat > "$DEVPROXY_CONFIG" <<EOF
# devproxy configuration - managed by install.sh
# Edit this file to change tool versions or override runtime settings.

# DEVPROXY_UNSECURE=1 # uncomment to always use the native tool binaries

CONTAINER_RUNTIME=

GO_BINARY="${GO_BINARY}"
NPM_BINARY="${NPM_BINARY}"
NPX_BINARY="${NPX_BINARY}"

GODEV_IMAGE=golang:1.25
GODEV_SYNTHETIC_GOROOT="${SYNTHETIC_GOROOT}"
# GODEV_EXTRA_VOLUMES= # uncomment to provide a list of directories to be mounted (colon-separated)
# GODEV_NETRC=1  # uncomment to mount ~/.netrc into the container (private modules)

NODEDEV_IMAGE=node:24
# NODEDEV_OS=     # target OS for npm binary downloads: empty=linux, host/auto=detect host OS
# NODEDEV_ARCH=   # target CPU for npm binary downloads: empty=container arch, host/auto=detect host CPU
# NODEDEV_NPMRC=1  # uncomment to mount ~/.npmrc into the container (private registries)
EOF
  echo "Wrote config to $DEVPROXY_CONFIG"
fi

# --- Download proxy scripts ---
mkdir -p "$INSTALL_DIR"

echo "Downloading go proxy..."
curl -fsSL "$REPO_BASE_URL/go-proxy.sh" -o "$INSTALL_DIR/go"
chmod +x "$INSTALL_DIR/go"

echo "Downloading npm/npx proxy..."
curl -fsSL "$REPO_BASE_URL/npm-npx-proxy.sh" -o "$INSTALL_DIR/npm"
chmod +x "$INSTALL_DIR/npm"
ln -sf "$INSTALL_DIR/npm" "$INSTALL_DIR/npx"

echo "Downloading devproxy manager..."
curl -fsSL "$REPO_BASE_URL/devproxy.sh" -o "$INSTALL_DIR/devproxy"
chmod +x "$INSTALL_DIR/devproxy"

# --- Download Dockerfiles ---
DOCKERFILES_DIR="$HOME/.local/share/devproxy/Dockerfiles"
mkdir -p "$DOCKERFILES_DIR"

echo "Downloading Dockerfiles..."
for dockerfile in devproxy-golang.Dockerfile; do
  curl -fsSL "$REPO_BASE_URL/Dockerfiles/$dockerfile" -o "$DOCKERFILES_DIR/$dockerfile"
  echo "  → $DOCKERFILES_DIR/$dockerfile"
done

# --- Write shell profile block (idempotent via markers) ---
BLOCK="${MARKER_START}
export PATH=\"${INSTALL_DIR}:\$PATH\"
[ -f \"\$HOME/.devproxy\" ] && source \"\$HOME/.devproxy\"
${MARKER_END}"

if grep -qF "$MARKER_START" "$PROFILE" 2>/dev/null; then
  # Replace the existing block in-place
  # Write block to a temp file — awk -v doesn't support newlines in variable values
  BLOCK_FILE="$(mktemp)"
  printf '%s\n' "$BLOCK" > "$BLOCK_FILE"
  awk -v start="$MARKER_START" -v end="$MARKER_END" -v blockfile="$BLOCK_FILE" '
    $0 == start { while ((getline line < blockfile) > 0) print line; skip=1; next }
    $0 == end   { skip=0; next }
    !skip        { print }
  ' "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
  rm -f "$BLOCK_FILE"
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
echo ""
echo "GoLand integration:"
echo "  Settings → Go → GOROOT → Add local → $SYNTHETIC_GOROOT"
