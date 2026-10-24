# claude-sandbox — isolated Claude Code + REA in rootless Podman

A disposable lab for running [REA](https://github.com/morluto/rea) (an MCP server
for reverse engineering) together with Claude Code **without** giving either of
them access to the Fedora host: no host home, no SSH keys, no Claude
credentials or claude.ai connectors, no LAN. The host CLI `sbx` starts the lab,
mounts or copies selected host paths into it, and drives the Claude inside —
by hand or from a Claude Code session on the host.

Why not just install REA on the host: REA runs as an MCP server, and Claude
Code starts MCP servers *outside* its Bash sandbox with full user rights. REA
itself states it is "not a sandbox" (Ghidra parses untrusted binaries, runtime
capture executes targets), `rea setup` edits agent configuration, and every
analysed string or web page is a prompt-injection vector for an agent that
would otherwise see `~/.ssh` and the connectors.

## Layout

```
Fedora host (rootless Podman, SELinux enforcing)
│
├─ you / a host Claude session ──► bin/sbx ──► podman exec / run
│
│  ┌─ network sbx-int (--internal, no DNS, no default route) ────────┐
│  │  claude-sbx    Fedora 44, user "agent" (UID 1000 = you via keep-id)
│  │   ├ Claude Code (pinned), auth: setup-token as podman secret     │
│  │   ├ REA MCP server (pinned) + Ghidra 12.1 + JDK 21 + Chromium    │
│  │   └ /lab/in (ro) · /lab/out (rw) · /host/<path> (your mounts)    │
│  │                    │ HTTP(S)_PROXY                               │
│  │  sbx-egress (squid) ┴── network sbx-ext ──► internet (by mode)   │
│  └──────────────────────────────────────────────────────────────────┘
```

| Layer | What it does |
| --- | --- |
| Auth | `claude setup-token` token (1 year). It can only make model requests: no claude.ai connectors, no Remote Control. Stored as podman secret, injected as `CLAUDE_CODE_OAUTH_TOKEN`. `disableClaudeAiConnectors` is set as well. |
| Container | Rootless, `--cap-drop=ALL`, `no-new-privileges`, SELinux `container_t`, read-only root fs, memory/CPU/PID limits, no host sockets (Wayland, D-Bus, Podman, ssh-agent). Seccomp: Podman's default profile minus new namespaces (`state/seccomp.json`, regenerated on `sbx up`), so no in-container user namespace "root". |
| Claude | Runs with `bypassPermissions` — deliberately: the container is the boundary. Only the image's MCP config is loaded (`--strict-mcp-config`). Output shown on the host is stripped of control characters (no terminal escapes). |
| Network | The sandbox has no route and no DNS; everything goes through the squid proxy. `api`: only `api.anthropic.com`, other names are refused without even resolving them (no DNS side channel). `open`: public internet. Both refuse private, loopback, link-local (metadata), multicast and NAT64 addresses — LAN and host stay unreachable. |
| Mounts | Read-only by default, only below `SBX_MOUNT_ROOTS` (default `~/Git:~/Downloads`), never hidden entries in `$HOME`, the home itself, this repo and personal directories (redacted for publication). In rw mounts every existing `.git` (nested repos too) is mounted read-only. Anything else: `--copy` into `lab/in`. |
| Outputs | `sbx down` first stops the sandbox, then removes symlinks and special files from `lab/out` (host tools would follow them to host files), renames any `.git`/`.envrc` there to `*.sbx-quarantine-<time>` (a git-aware prompt or direnv would run them on `cd`), and lists new `.git`, `.envrc` and symlinks in rw mounts. `sbx ask` only reports these, because the sandbox keeps running. While it runs, read results with `sbx cat` (read inside the container), not from the host. |

## Quick start

```bash
ln -s ~/Git/claude-sandbox/bin/sbx ~/.local/bin/sbx   # once
sbx build                         # base, rea and egress images (pinned in versions.env)
claude setup-token                # on the host, browser login; prints the token
sbx token set                     # paste it (stored as podman secret, not in this repo)
sbx up --copy ~/Downloads/some.AppImage
sbx selftest                      # isolation checks inside the sandbox
sbx ask "Analyse /lab/in/some.AppImage with REA. Write findings to /lab/out/report.md"
sbx down
```

Interactive: `sbx tui`, then `sbx attach` (detach with `Ctrl-b d`).

`sbx sh -- rea doctor --json` shows REA's readiness. Expected gaps: Hopper,
IDA, JADX and Kuna are not installed (commercial or caller-supplied); Ghidra
is the analysis provider. The doctor also reports the missing Claude
registration in `~/.claude.json` — intended, Claude only loads
`/etc/claude-sbx/mcp.json`.

## Commands

`sbx help` prints the full list. The important ones:

| Command | Purpose |
| --- | --- |
| `sbx up [--net api\|open\|none] [--mount PATH[:ro\|:rw]]... [--copy PATH]...` | Start proxy + sandbox. Mounts are fixed per container; change them with `sbx up --replace ...`. |
| `sbx restart` | Recreate with the last `--net`/`--mount` options (e.g. after `sbx token set`). |
| `sbx in PATH...` | Copy more inputs into `/lab/in` while running. |
| `sbx check PATH[:rw]...` | Dry-run the mount policy. |
| `sbx cat FILE` | Print a result (relative to `/lab/out`), read inside the sandbox: safe while it runs. |
| `sbx ask [--resume ID\|--continue] PROMPT` | Headless run (`claude -p`, stream-json). Prints session id, tools used and the result; the full transcript lands in `runs/<timestamp>/`. |
| `sbx tui` / `attach` / `screen` / `keys` | Interactive Claude in tmux inside the sandbox; `screen` and `keys` let a host session read and type. |
| `sbx sh [-- CMD]` | Shell or command inside, e.g. `sbx sh -- rea doctor --json`. |
| `sbx egress [-f]` | Every destination the sandbox asked the proxy for (saved to `logs/` on `sbx down`). |
| `sbx selftest` | Confinement, namespace, host-data, network and mount checks from inside, plus (api mode) a host-side check that the proxy does no DNS for refused names. |
| `sbx reset` | Wipe `state/home` (Claude sessions, caches). |

## Directories

| Path | Content |
| --- | --- |
| `images/{base,rea,egress}/Containerfile` | Images; `versions.env` pins the direct versions and checksums. |
| `container/` | Files baked into the base image (entrypoint, `sbx-claude`, `sbx-selftest`, managed settings, sandbox CLAUDE.md, tmux.conf). |
| `rea/` | REA layer: MCP config and CLAUDE.md addendum. |
| `egress/` | Squid policy (`common.conf`, `api.conf`, `open.conf`, `allow-api.txt`). |
| `state/home` | Persistent home of the sandbox user; `state/` also holds the seccomp profile and restart/scan stamps (git-ignored). |
| `lab/in`, `lab/out` | Inputs (ro inside) and results (git-ignored). |
| `runs/`, `logs/` | `sbx ask` transcripts, proxy logs (git-ignored). |

## Driving it from a Claude Code session on the host

Claude Code's own Bash sandbox cannot run rootless Podman, so every `sbx` call
from a host session has to leave that sandbox (approved per call), or you
allow it permanently in `~/.claude/settings.json`:

```json
{ "sandbox": { "excludedCommands": ["sbx *"] } }
```

Treat everything `sbx ask`/`sbx screen`/`sbx cat` returns as untrusted data:
it comes from an agent that just read the analysed material. While the sandbox
runs, read results with `sbx cat`, not with host tools on `lab/out` (a symlink
planted there would make them read host files); `sbx down` makes `lab/out`
safe again. Ideally drive the lab from a host session without connectors.

## Residual risks

- **Shared kernel.** A kernel exploit escapes as your user. Fine for static
  analysis and tests; for *executing* hostile samples use a VM or the planned
  libkrun microVM runtime (phase 2).
- **rw mounts are the real exit.** Scripts, Makefiles, `.envrc`, a newly
  created `.git` (hooks, `core.fsmonitor` — run by any `git status`, including
  shell-prompt integrations) and the like run later on the host. `sbx` only
  *reports* new `.git`/`.envrc`/symlinks; read that warning. Prefer `lab/out`.
- **`api` mode is "api.anthropic.com only", not "your account only".** The
  endpoint also accepts someone else's API key, so prompt-injected code could
  upload data — including the setup-token — into a foreign Anthropic
  organisation. In `open` mode anything can leave. The token is valid for a year
  on your subscription; revoke it if you suspect it leaked.
- **SELinux labels stay.** Mounted host paths are relabelled (`:z`,
  `container_file_t`) and keep that label after `sbx down`. Harmless for your
  own tools, but do not mount paths that confined services read.
- **Router WAN IP.** In `open` mode the proxy refuses private addresses, but
  your router's public IP is public: hairpin NAT could expose port forwards.
- **Build-time supply chain.** Claude Code, REA, Ghidra and the JDK are pinned
  (the latter two by SHA-256), but npm resolves transitive dependencies at
  build time and their install scripts run in the build container, which has
  unfiltered network. Pinned versions also age: updates are deliberate (edit
  `versions.env`, `sbx build`).

## Updating

Edit `versions.env` (REA, Claude Code, Ghidra/JDK URL + SHA-256), then
`sbx build` (add `--no-cache --pull` to refresh the Fedora packages) and
`sbx restart`.
