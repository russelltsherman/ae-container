# ae-container

A portable devcontainer for running Claude Code with `bypassPermissions` safely enabled. 

Running Claude with `bypassPermissions` on your host machine is risky. It can execute any command without confirmation. This devcontainer provides three layers of containment so you get the productivity benefits of unrestricted Claude without risking your host system:

- **Filesystem isolation** — the agent works inside the container, not your host.
- **Egress restriction** — outbound network traffic is forced through an allowlist proxy; everything else is dropped (see [Network Egress](#network-egress)).
- **Secret shadowing** — `.env` files in the workspace are masked with empty files inside the container (see `protected-paths`).

**Designed for:**

- **Security audits**: Review client code without risking your host
- **Untrusted repositories**: Explore unknown codebases safely
- **Experimental work**: Let Claude modify code freely in isolation
- **Multi-repo engagements**: Work on multiple related repositories

## Prerequisites

- **Docker runtime** (one of):
  - [Docker Desktop](https://docker.com/products/docker-desktop)
  - [OrbStack](https://orbstack.dev/)

- **For terminal workflows** (one-time install):

```bash
npm install -g @devcontainers/cli
git clone https://github.com/russelltsherman/ae-container ~/.agentcontainer
~/.agentcontainer/install.sh self-install
```

## Quick Start

Choose the pattern that fits your workflow:

### Pattern A: Per-Project Container (Isolated)

Each project gets its own container with independent volumes. Best for one-off reviews, untrusted repos, or when you need isolation between projects.

**Terminal:**

```bash
git clone <untrusted-repo>
cd untrusted-repo
devc .          # Installs template + starts container
devc shell      # Opens shell in container
```

**VS Code / Cursor:**

1. Install the Dev Containers extension:
   - VS Code: `ms-vscode-remote.remote-containers`
   - Cursor: `anysphere.remote-containers`

2. Set up the devcontainer (choose one):

   ```bash
   # Option A: Use devc (recommended)
   devc .

   # Option B: Clone manually
   git clone https://github.com/russelltsherman/ae-container .agentcontainer/
   ```

3. Open **your project folder** in VS Code, then:
   - Press `Cmd+Shift+P` (Mac) or `Ctrl+Shift+P` (Windows/Linux)
   - Type "Reopen in Container" and select **Dev Containers: Reopen in Container**

### Pattern B: Shared Workspace Container (Grouped)

A parent directory contains the devcontainer config, and you clone multiple repos inside. Shared volumes across all repos. Best for client engagements, related repositories, or ongoing work.

```bash
# Create workspace for a client engagement
mkdir -p ~/sandbox/client-name
cd ~/sandbox/client-name
devc .          # Install template + start container
devc shell      # Opens shell in container

# Inside container:
git clone <client-repo-1>
git clone <client-repo-2>
cd client-repo-1
claude          # Ready to work
```

## Bot User identity

The container runs as a dedicated **bot identity** rather than your personal credentials, so anything the agent does (commits, PRs, API calls) is attributable to the bot and your host credentials are never exposed to it. All bot credentials live under `~/.bot` on the host and are bind-mounted **read-only** into the container:

| Host path | Container target | Used for |
| --- | --- | --- |
| `~/.bot/claude/oauth-token` | `~/.bot/claude/oauth-token` | Claude Code auth (`CLAUDE_CODE_OAUTH_TOKEN`) |
| `~/.bot/gitconfig` | `~/.gitconfig` | Git author identity |
| `~/.bot/gh` | `~/.config/gh` | GitHub CLI token |
| `~/.bot/graphite` | `~/.config/graphite` | Graphite CLI token |
| `~/.bot/ssh` | `~/.ssh` | SSH key |

### Claude Code authentication

Claude Code authenticates in the container with a **long-lived OAuth token** (`CLAUDE_CODE_OAUTH_TOKEN`, valid ~1 year). The `cc-oauth-token.sh` profile snippet reads the bind-mounted token and exports it, so `devc shell`, `devc exec claude -p`, and the VS Code terminal all pick it up. This avoids Claude Code's interactive onboarding wizard, which always re-appears in containers even with valid credentials ([#8938](https://github.com/anthropics/claude-code/issues/8938)).

Generate the token once on the host and save it under `~/.bot`:

```bash
claude setup-token                              # prints a long-lived token
mkdir -p ~/.bot/claude
printf '%s' '<paste-token>' > ~/.bot/claude/oauth-token
chmod 600 ~/.bot/claude/oauth-token
```

If no token is present, the interactive login flow works as before.

### Git, GitHub, and Graphite

On each container start, `post-start.sh` authenticates the `gh` and `gt` CLIs from their bind-mounted tokens — **after** the egress proxy is up, since auth validates over the network. Auth failures warn rather than abort, so a missing or expired token never bricks container startup.

## Network Egress

All outbound traffic is locked down at container start so the agent cannot reach arbitrary hosts (exfiltrate code, pull untrusted payloads). Two mechanisms enforce this:

1. **`protect-egress`** applies `iptables`/`ip6tables` `OUTPUT` rules that **drop all outbound traffic** except: loopback, the Docker host gateway (`host.docker.internal`, for local model servers), and traffic from the `proxy` user (Squid).
2. **Squid** runs as the `proxy` user on port `3128` and is the only process permitted to reach the internet. It enforces a committed **domain allowlist** (`etc/squid/allowlist.conf`); HTTPS `CONNECT` is allowed only to allowlisted domains on port 443. The container's `http_proxy`/`https_proxy` env vars route all tooling through it.

Egress is locked down *before* Squid starts, so there is no window of unrestricted access. The proxy launcher (`start-squid`) is pinned via a tightly-scoped sudoers entry, so the agent cannot start a second, permissive Squid that would bypass the allowlist.

### Allowed domains

The allowlist is committed to the repo and reviewed with code changes. Currently permitted (a leading `.` matches the domain and all subdomains):

| Domain | Reason |
| --- | --- |
| `.anthropic.com`, `.claude.ai`, `.claude.com` | Claude Code / Anthropic API |
| `.github.com`, `.githubusercontent.com` | GitHub (git over HTTPS, `gh`/`gt`) |
| `.graphite.dev`, `.graphite.com` | Graphite CLI |
| `.chatgpt.com`, `.openai.com` | OpenAI Codex MCP client + docs |
| `.linear.app` | Linear MCP |
| `.schemastore.org` | Published JSON schemas |
| `host.docker.internal` | Local model servers on the host (oMLX/Ollama) |

To permit another host, add its domain to `etc/squid/allowlist.conf` and rebuild. Anything not on the list is denied.

**Per-project additions.** `etc/squid/allowlist.conf` is the shared, reviewed list and is **always refreshed** by `aec template`. For domains specific to one project, add them to `etc/squid/local.allowlist.conf` instead: the template **seeds it once and never overwrites it**, so per-project entries survive template updates (same seed-once model as `local.Dockerfile`). Squid merges both files, so a local entry can only *add* access, never remove a shared one. Changes take effect on the next `aec rebuild` (squid reads the copy baked into the image).

## CLI Helper Commands

```
devc .              Install template + start container in current directory
devc up             Start the devcontainer
devc rebuild        Rebuild container (preserves persistent volumes)
devc destroy [-f]   Remove container, volumes, and image for current project
devc down           Stop the container
devc shell          Open zsh shell in container
devc exec CMD       Execute command inside the container
devc upgrade        Upgrade Claude Code in the container
devc mount SRC DST  Add a bind mount (host → container)
devc sync [NAME]    Sync Claude Code sessions from devcontainers to host
devc template DIR   Copy devcontainer files to directory
devc self-install   Install devc to ~/.local/bin
```

> **Note:** Use `devc destroy` to clean up a project's Docker resources. Removing containers manually (e.g., `docker rm`) will leave orphaned volumes and images behind that `devc destroy` won't be able to find.

## Image build (local base image)

The image is built in two layers:

- **`base.Dockerfile`** — the slow, rarely-changing toolchain (apt deps, Node, the
  agent CLIs incl. Claude Code).
- **`local.Dockerfile`** — `FROM ae-container-base:local` plus the small
  security/config layers (squid, sudoers, protect-\* scripts, motd, config).
  This is the per-project customization point: `devc template` seeds it into a
  project once and never overwrites it, so per-project edits survive re-running
  the template. (`base.Dockerfile` is always refreshed.)

The base image is built **on demand on the host** by `scripts/initialize.sh`
(the `initializeCommand`), before `devcontainer up` builds the top image. It is
tagged with a content hash of `base.Dockerfile`:

- If an image for the current hash already exists, it is **reused** (no build).
- If `base.Dockerfile` changes, the hash changes and the base is **rebuilt
  automatically**.
- The stable `ae-container-base:local` alias the `local.Dockerfile` references is
  always repointed at the current hash, so `FROM` never has to change.

Docker resolves `FROM ae-container-base:local` from the **local image store** (no
registry pull), so nothing needs to be published.

> **Forcing a base rebuild:** `devc rebuild --no-cache` rebuilds the **top** image
> only — it does **not** rebuild the base. Because the Claude CLI in
> `base.Dockerfile` pins to "latest" at build time, that pin only refreshes when
> the base rebuilds. To force a fresh base without editing `base.Dockerfile`,
> remove the cached image and rebuild:
>
> ```
> docker rmi ae-container-base:local ae-container-base:<hash>
> devc rebuild
> ```

