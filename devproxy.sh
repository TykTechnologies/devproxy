#!/usr/bin/env bash
# devproxy.sh — manages the containerised toolchain proxies
# Usage: devproxy <command>
#   status          Show whether the proxy is ENABLED or DISABLED
#   list            Show installed proxies and their status
#   update          Re-download and reinstall all proxy scripts
#   uninstall       Remove all proxies and clean up the shell profile
#   nuke            uninstall + delete ~/.devproxy (prompts for confirmation)
#   enable          Comment out DEVPROXY_UNSECURE in ~/.devproxy (proxy active)
#   disable         Uncomment DEVPROXY_UNSECURE in ~/.devproxy (bypass proxy)
#   go use <image>   Set GODEV_IMAGE in ~/.devproxy
#   go exec <binary> Run a Linux binary inside the GODEV_IMAGE container
#   node use <image>  Set NODEDEV_IMAGE in ~/.devproxy
#   node exec <cmd>    Run a command inside the NODEDEV_IMAGE container

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

cmd_status() {
  if [ -n "${DEVPROXY_UNSECURE:-}" ]; then
    echo "devproxy: DISABLED"
  else
    echo "devproxy: ENABLED"
  fi
}

cmd_list() {
  echo "Installed proxies in $INSTALL_DIR:"
  echo ""
  for name in go npm npx; do
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

  DOCKERFILES_DIR="$HOME/.local/share/devproxy/Dockerfiles"
  if [ -d "$DOCKERFILES_DIR" ]; then
    rm -rf "$DOCKERFILES_DIR"
    echo "Removed Dockerfiles at $DOCKERFILES_DIR"
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

cmd_build() {
  local name="${1:-}"
  local version="${2:-}"

  if [ -z "$name" ] || [ -z "$version" ]; then
    echo "Usage: devproxy build <name> <version>" >&2
    echo "  e.g. devproxy build golang 1.25" >&2
    exit 1
  fi

  local dockerfile="$HOME/.local/share/devproxy/Dockerfiles/devproxy-${name}.Dockerfile"
  if [ ! -f "$dockerfile" ]; then
    echo "devproxy: Dockerfile not found: $dockerfile" >&2
    exit 1
  fi

  local arg_name
  arg_name="$(echo "$name" | tr '[:lower:]' '[:upper:]')_VERSION"
  local tag="devproxy-${name}:${version}"

  local runtime="${CONTAINER_RUNTIME:-}"
  if [ -z "$runtime" ]; then
    if command -v podman &>/dev/null; then
      runtime=podman
    elif command -v docker &>/dev/null; then
      runtime=docker
    else
      echo "devproxy: neither podman nor docker found" >&2
      exit 1
    fi
  fi

  echo "Building $tag using $runtime..."
  "$runtime" build \
    --build-arg "${arg_name}=${version}" \
    --tag "$tag" \
    --file "$dockerfile" \
    "$HOME/.local/share/devproxy/Dockerfiles"
}

cmd_go_exec() {
  # Collect -e KEY=VALUE flags before the binary argument
  local env_flags=()
  while [ "${1:-}" = "-e" ]; do
    shift
    env_flags+=(--env "${1}")
    shift
  done

  local binary="${1:-}"
  if [ -z "$binary" ]; then
    echo "Usage: devproxy go exec [-e KEY=VALUE]... <binary> [args...]" >&2
    echo "  e.g. devproxy go exec -e DB_HOST=host.docker.internal ./my_binary" >&2
    exit 1
  fi

  # Resolve to absolute path so the container mount and invocation path match
  local abs_binary
  abs_binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"

  if [ ! -f "$abs_binary" ]; then
    echo "devproxy: binary not found: $abs_binary" >&2
    exit 1
  fi

  local image="${GODEV_IMAGE:-}"
  if [ -z "$image" ]; then
    echo "devproxy: GODEV_IMAGE is not set - run the install script or set it in ~/.devproxy" >&2
    exit 1
  fi

  local runtime="${CONTAINER_RUNTIME:-}"
  if [ -z "$runtime" ]; then
    if command -v podman &>/dev/null; then
      runtime=podman
    elif command -v docker &>/dev/null; then
      runtime=docker
    else
      echo "devproxy: neither podman nor docker found" >&2
      exit 1
    fi
  fi

  local volopt=""
  [ "$runtime" = "podman" ] && volopt=":z"

  local tty_flag=""
  [ -t 0 ] && tty_flag="--tty"

  exec "$runtime" run --rm \
    --interactive \
    ${tty_flag} \
    --network host \
    --workdir "$(pwd)" \
    --volume "$(pwd):$(pwd)${volopt}" \
    --volume "${abs_binary}:${abs_binary}${volopt}" \
    "${env_flags[@]+"${env_flags[@]}"}" \
    "$image" \
    "$abs_binary" "${@:2}"
}

cmd_go_use() {
  local image="${1:-}"
  if [ -z "$image" ]; then
    echo "Usage: devproxy go use <image>" >&2
    echo "  e.g. devproxy go use devproxy-golang:1.25" >&2
    exit 1
  fi

  local cfg="$HOME/.devproxy"
  if [ ! -f "$cfg" ]; then
    echo "devproxy: $cfg not found" >&2; exit 1
  fi

  sed -i.bak "s|^GODEV_IMAGE=.*|GODEV_IMAGE=${image}|" "$cfg" && rm -f "$cfg.bak"
  echo "GODEV_IMAGE set to ${image} in $cfg"
}

cmd_node_use() {
  local image="${1:-}"
  if [ -z "$image" ]; then
    echo "Usage: devproxy node use <image>" >&2
    echo "  e.g. devproxy node use node:22" >&2
    exit 1
  fi

  local cfg="$HOME/.devproxy"
  if [ ! -f "$cfg" ]; then
    echo "devproxy: $cfg not found" >&2; exit 1
  fi

  sed -i.bak "s|^NODEDEV_IMAGE=.*|NODEDEV_IMAGE=${image}|" "$cfg" && rm -f "$cfg.bak"
  echo "NODEDEV_IMAGE set to ${image} in $cfg"
}

cmd_node_exec() {
  # Collect -e KEY=VALUE flags before the command
  local env_flags=()
  while [ "${1:-}" = "-e" ]; do
    shift
    env_flags+=(--env "${1}")
    shift
  done

  if [ "${#@}" -eq 0 ]; then
    echo "Usage: devproxy node exec [-e KEY=VALUE]... <command> [args...]" >&2
    echo "  e.g. devproxy node exec npm run build" >&2
    echo "  e.g. devproxy node exec -e API_URL=http://localhost npx tsc --noEmit" >&2
    exit 1
  fi

  local image="${NODEDEV_IMAGE:-}"
  if [ -z "$image" ]; then
    echo "devproxy: NODEDEV_IMAGE is not set - run the install script or set it in ~/.devproxy" >&2
    exit 1
  fi

  local runtime="${CONTAINER_RUNTIME:-}"
  if [ -z "$runtime" ]; then
    if command -v podman &>/dev/null; then
      runtime=podman
    elif command -v docker &>/dev/null; then
      runtime=docker
    else
      echo "devproxy: neither podman nor docker found" >&2
      exit 1
    fi
  fi

  local volopt=""
  [ "$runtime" = "podman" ] && volopt=":z"

  local tty_flag=""
  [ -t 0 ] && tty_flag="--tty"

  exec "$runtime" run --rm \
    --interactive \
    ${tty_flag} \
    --network host \
    --workdir "$(pwd)" \
    --volume "$(pwd):$(pwd)${volopt}" \
    "${env_flags[@]+"${env_flags[@]}"}" \
    "$image" \
    "$@"
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
  status)    cmd_status ;;
  list)      cmd_list ;;
  update)    cmd_update ;;
  uninstall) cmd_uninstall ;;
  nuke)      cmd_nuke ;;
  enable)    cmd_enable ;;
  disable)   cmd_disable ;;
  build)     cmd_build "${@:2}" ;;
  go)
    case "${2:-}" in
      use)  cmd_go_use "${3:-}" ;;
      exec) cmd_go_exec "${@:3}" ;;
      *)
        echo "Usage: devproxy go <command>" >&2
        echo "  use <image>          Set GODEV_IMAGE in ~/.devproxy" >&2
        echo "  exec <binary> [args] Run a Linux binary inside the container" >&2
        exit 1
        ;;
    esac
    ;;
  node)
    case "${2:-}" in
      use)  cmd_node_use "${3:-}" ;;
      exec) cmd_node_exec "${@:3}" ;;
      *)
        echo "Usage: devproxy node <command>" >&2
        echo "  use <image>             Set NODEDEV_IMAGE in ~/.devproxy" >&2
        echo "  exec <command> [args]   Run a command inside the NODEDEV_IMAGE container" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Usage: devproxy <command>"
    echo ""
    echo "Commands:"
    echo "  status             Show whether the proxy is ENABLED or DISABLED"
    echo "  list               Show installed proxies and their status"
    echo "  update             Re-download and reinstall all proxy scripts"
    echo "  uninstall          Remove all proxies and clean up the shell profile"
    echo "  nuke               uninstall + delete ~/.devproxy (prompts for confirmation)"
    echo "  enable             Comment out DEVPROXY_UNSECURE (proxy active)"
    echo "  disable            Uncomment DEVPROXY_UNSECURE (bypass proxy)"
    echo "  build <name> <ver> Build a devproxy image (e.g. build golang 1.25)"
    echo "  go use <image>     Set GODEV_IMAGE in ~/.devproxy (e.g. go use devproxy-golang:1.25)"
    echo "  go exec <binary>   Run a Linux binary inside the GODEV_IMAGE container"
    echo "  node use <image>   Set NODEDEV_IMAGE in ~/.devproxy (e.g. node use node:22)"
    echo "  node exec <cmd>    Run a command inside the NODEDEV_IMAGE container"
    exit 1
    ;;
esac
