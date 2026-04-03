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

GO_IMAGE="${GODEV_IMAGE:-golang:1.24-alpine}"
CACHE_VOLUME="${GODEV_CACHE_VOLUME:-godev-modcache}"

# Ensure the cache volume exists (idempotent)
"$RUNTIME" volume inspect "$CACHE_VOLUME" &>/dev/null \
  || "$RUNTIME" volume create "$CACHE_VOLUME" &>/dev/null

TTY_FLAG=""
[ -t 0 ] && TTY_FLAG="--tty"

# GOOS/GOARCH are only meaningful for cross-compilation (go build).
# For go run the binary executes inside the Linux container, so the host
# values would produce the wrong target and are intentionally omitted.
_CROSS_ENV_FLAGS=()
case "${1:-}" in
  build)
    _CROSS_ENV_FLAGS+=(
      --env GOOS="$("$GO_BINARY" env GOOS)"
      --env GOARCH="$("$GO_BINARY" env GOARCH)"
    )
    ;;
esac

# Mount ~/.netrc and ~/.gitconfig read-only when GODEV_NETRC is set.
# Both are needed for private module access: .netrc provides HTTPS credentials,
# .gitconfig carries URL rewrites (e.g. HTTPS→SSH) and credential helper config.
NETRC_FLAG=()
if [ -n "${GODEV_NETRC:-}" ]; then
  _cred_opts="ro"
  [ "$RUNTIME" = "podman" ] && _cred_opts="ro,z"
  [ -f "$HOME/.netrc" ]    && NETRC_FLAG+=(--volume "$HOME/.netrc:/root/.netrc:${_cred_opts}")
  [ -f "$HOME/.gitconfig" ] && NETRC_FLAG+=(--volume "$HOME/.gitconfig:/root/.gitconfig:${_cred_opts}")
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

exec "$RUNTIME" run --rm \
  --interactive \
  ${TTY_FLAG} \
  --workdir "$(pwd)" \
  --volume "$(pwd):$(pwd)${RUNTIME_VOLOPT}" \
  --volume "${CACHE_VOLUME}:/root/go/pkg/mod${RUNTIME_VOLOPT}" \
  "${NETRC_FLAG[@]+"${NETRC_FLAG[@]}"}" \
  "${EXTRA_VOL_FLAGS[@]+"${EXTRA_VOL_FLAGS[@]}"}" \
  --env GOPATH=/root/go \
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
