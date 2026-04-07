#!/usr/bin/env bash
# npm-npx-proxy.sh — runs npm/npx commands inside an ephemeral container
# Installed as both ~/.local/bin/devproxy/npm and ~/.local/bin/devproxy/npx
# The script detects which tool it was invoked as via basename $0.

set -euo pipefail

_TOOL="$(basename "$0")"

# Capture env overrides before sourcing config so they take precedence
_NODEDEV_NPMRC_ENV="${NODEDEV_NPMRC:-}"

# Load central config (covers non-login shells: IDEs, CI, env -i contexts)
[ -f "$HOME/.devproxy" ] && source "$HOME/.devproxy"

# Env overrides config file
[ -n "$_NODEDEV_NPMRC_ENV" ] && NODEDEV_NPMRC="$_NODEDEV_NPMRC_ENV"

# --- Validate required config ---
if [ -z "${NPM_BINARY:-}" ]; then
  echo "${_TOOL}-proxy: NPM_BINARY is not set — run the install script first" >&2
  exit 1
fi

# npx lives alongside npm; derive its path unless explicitly overridden
_NPX_BINARY="${NPX_BINARY:-$(dirname "$NPM_BINARY")/npx}"

case "$_TOOL" in
  npm) _REAL_BINARY="$NPM_BINARY" ;;
  npx) _REAL_BINARY="$_NPX_BINARY" ;;
  *)
    echo "${_TOOL}-proxy: unknown tool name '${_TOOL}'; expected npm or npx" >&2
    exit 1
    ;;
esac

# --- Unsecure mode: bypass the container entirely ---
if [ -n "${DEVPROXY_UNSECURE:-}" ]; then
  exec "$_REAL_BINARY" "$@"
fi

# --- Local passthrough for safe, read-only subcommands ---
# npm config/help: purely informational, no package code runs
# npx always runs in the container — its entire purpose is to download and execute packages
if [ "$_TOOL" = "npm" ]; then
  case "${1:-}" in
    help|config)
      exec "$_REAL_BINARY" "$@"
      ;;
  esac
fi

# --- Detect container runtime ---
RUNTIME="${CONTAINER_RUNTIME:-}"
if [ -z "$RUNTIME" ]; then
  if command -v podman &>/dev/null; then
    RUNTIME=podman
  elif command -v docker &>/dev/null; then
    RUNTIME=docker
  else
    echo "${_TOOL}-proxy: neither podman nor docker found" >&2
    exit 1
  fi
fi

# :z is a SELinux relabelling hint supported by Podman; Docker Desktop rejects it
RUNTIME_VOLOPT=""
[ "$RUNTIME" = "podman" ] && RUNTIME_VOLOPT=":z"

NODE_IMAGE="${NODEDEV_IMAGE:-node:24}"
HOST_NPM_CACHE="$("$NPM_BINARY" config get cache)"

TTY_FLAG=""
[ -t 0 ] && TTY_FLAG="--tty"

# Mount credentials when NODEDEV_NETRC is set.
# .npmrc     — registry auth tokens (private npm registries, scoped packages)
# .gitconfig — URL rewrites and credential helper config (git-based dependencies)
# SSH agent  — handles SSH-based git dependencies without exposing key files
NPMRC_FLAG=()
if [ -n "${NODEDEV_NPMRC:-}" ]; then
  _cred_opts="ro"
  [ "$RUNTIME" = "podman" ] && _cred_opts="ro,z"
  [ -f "$HOME/.npmrc" ]     && NPMRC_FLAG+=(--volume "$HOME/.npmrc:/root/.npmrc:${_cred_opts}")
  [ -f "$HOME/.gitconfig" ] && NPMRC_FLAG+=(--volume "$HOME/.gitconfig:/root/.gitconfig:${_cred_opts}")
  if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    NPMRC_FLAG+=(
      --volume "${SSH_AUTH_SOCK}:/tmp/ssh_auth.sock"
      --env SSH_AUTH_SOCK=/tmp/ssh_auth.sock
    )
  fi
fi

# Forward NODE_ENV and CI only when set on the host — these affect build behaviour
# (e.g. NODE_ENV=production skips devDependencies; CI suppresses interactive prompts)
ENV_FLAGS=()
[ -n "${NODE_ENV:-}" ] && ENV_FLAGS+=(--env "NODE_ENV=${NODE_ENV}")
[ -n "${CI:-}" ]       && ENV_FLAGS+=(--env "CI=${CI}")

exec "$RUNTIME" run --rm \
  --interactive \
  ${TTY_FLAG} \
  --workdir "$(pwd)" \
  --volume "$(pwd):$(pwd)${RUNTIME_VOLOPT}" \
  --volume "${HOST_NPM_CACHE}:${HOST_NPM_CACHE}${RUNTIME_VOLOPT}" \
  "${NPMRC_FLAG[@]+"${NPMRC_FLAG[@]}"}" \
  "${ENV_FLAGS[@]+"${ENV_FLAGS[@]}"}" \
  --env NPM_CONFIG_CACHE="${HOST_NPM_CACHE}" \
  --security-opt no-new-privileges \
  "$NODE_IMAGE" \
  "$_TOOL" "$@"
