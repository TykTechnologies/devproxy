#!/usr/bin/env bash
# go-proxy.sh — runs go commands inside an ephemeral container
# Install as ~/.local/bin/devproxy/go

set -euo pipefail

# Capture env overrides before sourcing config so they take precedence
_GODEV_NETRC_ENV="${GODEV_NETRC:-}"

# Load central config (covers non-login shells: GoLand, CI, env -i contexts)
[ -f "$HOME/.devproxy" ] && source "$HOME/.devproxy"

# Env overrides config file
[ -n "$_GODEV_NETRC_ENV" ] && GODEV_NETRC="$_GODEV_NETRC_ENV"

# --- Validate required config ---
if [ -z "${GO_BINARY:-}" ]; then
  echo "go-proxy: GO_BINARY is not set — run the install script first" >&2
  exit 1
fi

# --- Unsecure mode: bypass the container entirely ---
if [ -n "${DEVPROXY_UNSECURE:-}" ]; then
  exec "$GO_BINARY" "$@"
fi

# --- Local passthrough for safe, read-only subcommands ---
case "${1:-}" in
  env|help)
    exec "$GO_BINARY" "$@"
    ;;
esac

# --- Detect container runtime ---
RUNTIME="${CONTAINER_RUNTIME:-}"
if [ -z "$RUNTIME" ]; then
  if command -v podman &>/dev/null; then
    RUNTIME=podman
  elif command -v docker &>/dev/null; then
    RUNTIME=docker
  else
    echo "go-proxy: neither podman nor docker found" >&2
    exit 1
  fi
fi

# :z is a SELinux relabelling hint supported by Podman; Docker Desktop rejects it
RUNTIME_VOLOPT=""
[ "$RUNTIME" = "podman" ] && RUNTIME_VOLOPT=":z"

GO_IMAGE="${GODEV_IMAGE:-golang:1.25}"
HOST_GOPATH="$("$GO_BINARY" env GOPATH)"

TTY_FLAG=""
[ -t 0 ] && TTY_FLAG="--tty"

# GOOS/GOARCH are forwarded for go build only, and only when CGO is disabled.
# With CGO enabled the binary is OS-specific and must be compiled natively —
# cross-compiling with CGO from a Linux container to darwin is not supported
# (clang would receive macOS-only flags like -arch and fail). Use DEVPROXY_UNSECURE=1
# to build CGO binaries for the host platform via the real toolchain.
_CROSS_ENV_FLAGS=()
case "${1:-}" in
  build)
    if [ "$("$GO_BINARY" env CGO_ENABLED)" = "0" ]; then
      _CROSS_ENV_FLAGS+=(
        --env GOOS="$("$GO_BINARY" env GOOS)"
        --env GOARCH="$("$GO_BINARY" env GOARCH)"
      )
    fi
    ;;
esac

# Mount credentials and forward the SSH agent when GODEV_NETRC is set.
# .netrc  — HTTPS credentials
# .gitconfig — URL rewrites (e.g. HTTPS→SSH) and credential helper config
# SSH agent — handles SSH-based auth without exposing key files to the container
NETRC_FLAG=()
if [ -n "${GODEV_NETRC:-}" ]; then
  _cred_opts="ro"
  [ "$RUNTIME" = "podman" ] && _cred_opts="ro,z"
  [ -f "$HOME/.netrc" ]     && NETRC_FLAG+=(--volume "$HOME/.netrc:/root/.netrc:${_cred_opts}")
  [ -f "$HOME/.gitconfig" ] && NETRC_FLAG+=(--volume "$HOME/.gitconfig:/root/.gitconfig:${_cred_opts}")
  if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    NETRC_FLAG+=(
      --volume "${SSH_AUTH_SOCK}:/tmp/ssh_auth.sock"
      --env SSH_AUTH_SOCK=/tmp/ssh_auth.sock
    )
  fi
fi

# Build extra volume flags from GODEV_EXTRA_VOLUMES (colon-separated host paths,
# each mounted at the same absolute path inside the container — needed for replace directives)
EXTRA_VOL_FLAGS=()
if [ -n "${GODEV_EXTRA_VOLUMES:-}" ]; then
  IFS=: read -ra _extra_vols <<< "$GODEV_EXTRA_VOLUMES"
  for _vol in "${_extra_vols[@]}"; do
    [ -n "$_vol" ] && EXTRA_VOL_FLAGS+=(--volume "${_vol}:${_vol}${RUNTIME_VOLOPT}")
  done
fi

# Build port publish flags from GODEV_PORTS (comma-separated, e.g. 8080:8080,9090:9090)
PORT_FLAGS=()
if [ -n "${GODEV_PORTS:-}" ]; then
  IFS=',' read -ra _ports <<< "$GODEV_PORTS"
  for _port in "${_ports[@]}"; do
    PORT_FLAGS+=(--publish "$_port")
  done
fi

# Auto-mount directories referenced by -modfile so IDEs (e.g. GoLand) that pass
# an absolute project path without running from the project directory still work.
for _arg in "$@"; do
  case "$_arg" in
    -modfile=*)
      _moddir="$(dirname "${_arg#-modfile=}")"
      EXTRA_VOL_FLAGS+=(--volume "${_moddir}:${_moddir}${RUNTIME_VOLOPT}")
      ;;
  esac
done

exec "$RUNTIME" run --rm \
  --interactive \
  ${TTY_FLAG} \
  --workdir "$(pwd)" \
  --volume "$(pwd):$(pwd)${RUNTIME_VOLOPT}" \
  --volume "${HOST_GOPATH}:${HOST_GOPATH}${RUNTIME_VOLOPT}" \
  "${NETRC_FLAG[@]+"${NETRC_FLAG[@]}"}" \
  "${EXTRA_VOL_FLAGS[@]+"${EXTRA_VOL_FLAGS[@]}"}" \
  "${PORT_FLAGS[@]+"${PORT_FLAGS[@]}"}" \
  --env GOPATH="${HOST_GOPATH}" \
  --env GOFLAGS="$("$GO_BINARY" env GOFLAGS) -buildvcs=false" \
  --env CGO_ENABLED="$("$GO_BINARY" env CGO_ENABLED)" \
  ${_CROSS_ENV_FLAGS[@]+"${_CROSS_ENV_FLAGS[@]}"} \
  --env GONOSUMCHECK="$("$GO_BINARY" env GONOSUMCHECK)" \
  --env GONOSUMDB="$("$GO_BINARY" env GONOSUMDB)" \
  --env GOPRIVATE="$("$GO_BINARY" env GOPRIVATE)" \
  --env GOPROXY="$("$GO_BINARY" env GOPROXY)" \
  --security-opt no-new-privileges \
  "$GO_IMAGE" \
  go "$@"
