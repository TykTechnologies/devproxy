#!/usr/bin/env bash
# go-proxy.sh — runs go commands inside an ephemeral container
# Install as ~/.local/bin/devproxy/go

set -euo pipefail

# Load central config (covers non-login shells: GoLand, CI, env -i contexts)
[ -f "$HOME/.devproxy" ] && source "$HOME/.devproxy"

# --- Local passthrough for safe, read-only subcommands ---
case "${1:-}" in
  env|help)
    if [ -z "${GO_BINARY:-}" ]; then
      echo "go-proxy: GO_BINARY is not set — run the install script first" >&2
      exit 1
    fi
    exec "$GO_BINARY" "$@"
    ;;
esac

# --- Validate required config ---
if [ -z "${GO_BINARY:-}" ]; then
  echo "go-proxy: GO_BINARY is not set — run the install script first" >&2
  exit 1
fi

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

exec "$RUNTIME" run --rm \
  --interactive \
  ${TTY_FLAG} \
  --workdir /workspace \
  --volume "$(pwd):/workspace${RUNTIME_VOLOPT}" \
  --volume "${CACHE_VOLUME}:/root/go/pkg/mod${RUNTIME_VOLOPT}" \
  --env GOPATH=/root/go \
  --env GOFLAGS="$("$GO_BINARY" env GOFLAGS)" \
  --env CGO_ENABLED="$("$GO_BINARY" env CGO_ENABLED)" \
  --env GOOS="$("$GO_BINARY" env GOOS)" \
  --env GOARCH="$("$GO_BINARY" env GOARCH)" \
  --env GONOSUMCHECK="$("$GO_BINARY" env GONOSUMCHECK)" \
  --env GONOSUMDB="$("$GO_BINARY" env GONOSUMDB)" \
  --env GOPRIVATE="$("$GO_BINARY" env GOPRIVATE)" \
  --env GOPROXY="$("$GO_BINARY" env GOPROXY)" \
  --security-opt no-new-privileges \
  "$GO_IMAGE" \
  go "$@"
