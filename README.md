# devproxy

Devproxy intercepts `go` (and `npm`/`npx`) invocations and transparently runs them inside
ephemeral containers. Package installation code never executes on the host, isolating it from
supply-chain attacks such as malicious install scripts or post-install hooks.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/TykTechnologies/devproxy/refs/heads/main/install.sh | bash
```

Then activate in the current shell:

```sh
source ~/.zshrc   # or ~/.bashrc
```

---

## Go proxy

### How it works

The install script places a proxy script at `~/.local/bin/devproxy/go` and prepends that
directory to `PATH`. Every `go` command is intercepted by the proxy, which:

1. Sources `~/.devproxy` for configuration.
2. Runs the command inside an ephemeral container using the image defined by `GODEV_IMAGE`.
3. Mounts the working directory and the host GOPATH at the same absolute paths so all module
   cache, replace directives, and IDE-generated absolute paths resolve identically inside and
   outside the container.
4. Forwards the relevant Go environment variables (`GOPROXY`, `GOPRIVATE`, `GONOSUMDB`, etc.)
   from the host's real Go installation.

`go env` and `go help` are always passed through to the real binary without starting a
container.

---

### Configuration (`~/.devproxy`)

| Variable | Default | Description |
|---|---|---|
| `GO_BINARY` | *(set by installer)* | Path to the real `go` binary on the host |
| `CONTAINER_RUNTIME` | auto-detect | `podman` or `docker` |
| `GODEV_IMAGE` | `golang:1.25` | Container image used for all go commands |
| `GODEV_EXTRA_VOLUMES` | *(unset)* | Colon-separated list of extra host paths to mount |
| `GODEV_PORTS` | *(unset)* | Comma-separated ports to publish (e.g. `8080:8080,9090:9090`) |
| `GODEV_NETRC` | *(unset)* | Set to `1` to enable private module credentials |
| `DEVPROXY_UNSECURE` | *(unset)* | Set to `1` to bypass the container entirely |

---

### Private modules

Set `GODEV_NETRC=1` in `~/.devproxy` (or per-command) to mount credentials into the
container. The proxy mounts the following files read-only when the variable is set:

| File | Container path | Purpose |
|---|---|---|
| `~/.netrc` | `/root/.netrc` | HTTPS credentials (username / PAT) |
| `~/.gitconfig` | `/root/.gitconfig` | URL rewrites, credential helper config |
| `$SSH_AUTH_SOCK` | `/tmp/ssh_auth.sock` | SSH agent socket for key-based auth |

The SSH agent socket is forwarded automatically if `SSH_AUTH_SOCK` is set in the environment,
so no private key files are ever copied into the container.

**Example `~/.netrc` entry:**

```
machine github.com
login your-github-username
password ghp_yourPersonalAccessToken
```

**Per-command override:**

```sh
GODEV_NETRC=1 go get github.com/YourOrg/private-module
```

---

### Module replace directives

If your `go.mod` uses a `replace` directive pointing to a local path, that path must also be
visible inside the container. Add it to `GODEV_EXTRA_VOLUMES` in `~/.devproxy`:

```sh
GODEV_EXTRA_VOLUMES=/Users/you/Dev/Go/mylib:/Users/you/Dev/Go/another
```

Each path is mounted at the same absolute path in the container, so replace directives require
no changes.

---

### CGO and cross-compilation

| Scenario | Behaviour |
|---|---|
| `go build` with CGO disabled | `GOOS`/`GOARCH` forwarded — cross-compiles for the host OS |
| `go build` with CGO enabled | `GOOS`/`GOARCH` **not** forwarded — produces a Linux binary |
| `go run` | Always builds and runs inside the Linux container |

Cross-compiling a CGO binary from a Linux container to macOS is not supported (the macOS SDK
is not available in the container). To build a CGO binary for the host platform, use the
real toolchain:

```sh
DEVPROXY_UNSECURE=1 go build ./...
```

---

### Custom images (with CGO / Clang)

The installer downloads a ready-made Dockerfile that adds Clang and Git to the standard Go
image. Build and activate it with:

```sh
devproxy build golang 1.25
devproxy go use devproxy-golang:1.25
```

The Dockerfile is installed at `~/.local/share/devproxy/Dockerfiles/devproxy-golang.Dockerfile`.

---

### Running Linux binaries on macOS

A binary compiled inside the container is a Linux ELF binary and cannot run natively on macOS.
Use `devproxy go exec` to run it inside the same container environment:

```sh
go build -o ./myapp .
devproxy go exec ./myapp --flag value
```

Pass environment variables with `-e` and publish ports with `-p`:

```sh
devproxy go exec -p 8080:8080 -e DB_HOST=host.docker.internal ./myapp
```

To always publish ports without passing `-p` each time, set `GODEV_PORTS` in `~/.devproxy`:

```sh
GODEV_PORTS=8080:8080
```

This also applies to all `go run` invocations through the proxy.

The container uses `--network host` so `localhost` resolves to the host network (note: on
macOS with Docker Desktop or Podman, use `host.docker.internal` / `host.containers.internal`
instead, as the container runs inside a Linux VM).

---

### GoLand integration

Set the GOROOT in GoLand to the synthetic GOROOT created by the installer:

```
Settings → Go → GOROOT → Add local → ~/.local/share/devproxy/goroot
```

The synthetic GOROOT symlinks the real Go standard library but replaces the `go` binary with
the proxy, so all GoLand-triggered `go list`, `go mod`, and module resolution calls run inside
the container automatically. Absolute paths passed by GoLand via `-modfile` are detected and
mounted automatically.

---

## npm / npx proxy

### How it works

The install script places a single proxy script at `~/.local/bin/devproxy/npm` and symlinks
`~/.local/bin/devproxy/npx` to it. The script detects which tool it was invoked as and routes
accordingly:

- **npm** — runs the npm command inside an ephemeral `node:24` container. `npm help` and
  `npm config` are always passed through to the real binary without starting a container.
- **npx** — always runs inside the container, since its purpose is to download and execute
  arbitrary packages.

The host npm cache directory (resolved via `npm config get cache`, e.g. `~/.npm`) is mounted
at the same absolute path inside the container so the cache is shared across runs and persists
between invocations.

---

### Configuration (`~/.devproxy`)

| Variable | Default | Description |
|---|---|---|
| `NPM_BINARY` | *(set by installer)* | Path to the real `npm` binary on the host |
| `NPX_BINARY` | *(set by installer)* | Path to the real `npx` binary on the host |
| `CONTAINER_RUNTIME` | auto-detect | `podman` or `docker` |
| `NODEDEV_IMAGE` | `node:24` | Container image used for all npm/npx commands |
| `NODEDEV_OS` | `linux` | Target OS for npm binary downloads; set to `host` or `auto` to detect the host OS |
| `NODEDEV_ARCH` | *(container arch)* | Target CPU for npm binary downloads; set to `host` or `auto` to detect the host CPU |
| `NODEDEV_PORTS` | *(unset)* | Comma-separated ports to publish (e.g. `3000:3000,8080:8080`) |
| `NODEDEV_NPMRC` | *(unset)* | Set to `1` to enable private registry credentials |
| `DEVPROXY_UNSECURE` | *(unset)* | Set to `1` to bypass the container entirely |

---

### Private packages

Set `NODEDEV_NPMRC=1` in `~/.devproxy` (or per-command) to mount registry credentials into
the container. The proxy mounts the following files read-only when the variable is set:

| File | Container path | Purpose |
|---|---|---|
| `~/.npmrc` | `/root/.npmrc` | Registry auth tokens for private/scoped packages |
| `~/.gitconfig` | `/root/.gitconfig` | URL rewrites, credential helper config |
| `$SSH_AUTH_SOCK` | `/tmp/ssh_auth.sock` | SSH agent socket for SSH-based git dependencies |

The SSH agent socket is forwarded automatically if `SSH_AUTH_SOCK` is set in the environment.

**Example `~/.npmrc` entry:**

```
//registry.npmjs.org/:_authToken=npm_yourAuthToken
@yourorg:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=ghp_yourPersonalAccessToken
```

**Per-command override:**

```sh
NODEDEV_NPMRC=1 npm install
```

---

## devproxy commands

### Bypassing the container

`DEVPROXY_UNSECURE` is respected by all proxies. To run a single command on the host without
a container:

```sh
DEVPROXY_UNSECURE=1 go mod tidy
DEVPROXY_UNSECURE=1 npm install
```

To disable the proxy globally until re-enabled:

```sh
devproxy disable   # uncomments DEVPROXY_UNSECURE in ~/.devproxy
devproxy enable    # comments it back out
```

---

### Listing proxies

```sh
devproxy list
```

Shows which proxies are installed and the key variables from `~/.devproxy`.

---

### Updating

```sh
devproxy update
```

Re-downloads and reinstalls all proxy scripts in-place without touching `~/.devproxy`.

---

### Running commands inside the Node container

Use `devproxy node exec` to run any command inside the `NODEDEV_IMAGE` container with the
current working directory mounted:

```sh
devproxy node exec npm run build
devproxy node exec npx tsc --noEmit
```

Pass environment variables with `-e` and publish ports with `-p`:

```sh
devproxy node exec -p 3000:3000 -e API_URL=http://localhost npm run dev
```

To always publish ports when running `npm` or `npx` directly (e.g. `npm run dev`), set
`NODEDEV_PORTS` in `~/.devproxy`:

```sh
NODEDEV_PORTS=3000:3000
```

---

### Uninstall

```sh
devproxy uninstall   # removes proxies and shell profile block, keeps ~/.devproxy
devproxy nuke        # same as above, also deletes ~/.devproxy (prompts for confirmation)
```
