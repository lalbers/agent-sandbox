# agent-sandbox

[![CI](https://github.com/lalbers/agent-sandbox/actions/workflows/ci.yml/badge.svg)](https://github.com/lalbers/agent-sandbox/actions/workflows/ci.yml)

`sbx` runs Claude Code and [REA](https://github.com/morluto/rea) in rootless
Podman. REA is an MCP server for reverse engineering: it parses untrusted
binaries with Ghidra, it can run a target under Frida, and the strings it
extracts land in the agent's context. `--vm` gives each command its own
libkrun microVM.

Claude Code's Bash sandbox covers shell commands. It does not cover MCP
servers, hooks or other helper processes. On the host those run as you, so
they can read `~/.ssh`, the claude.ai login and its connectors, and the LAN.

A hardened harness for analysing untrusted binaries with an AI agent,
maintained by one person. Tested on Fedora 44 (x86_64), rootless Podman 5 and
SELinux enforcing; other setups are untested. Versions in `versions.env` are
bumped by hand.

## Threat model

Assume the agent and REA are compromised by the sample. That sample is a
binary, a string or a page that prompt-injects the agent, or a target that
misbehaves when it runs.

A host path is visible to them only if you mounted or copied it. They have no
route and no DNS of their own. `/lab/out` is a directory on the host, and so
is a writable mount. `sbx down` scans both after the sandbox has stopped.

Out of scope: kernel exploits in container mode, data leaving through
`api.anthropic.com`, keeping the sample away from the model provider, and the
build-time supply chain.

## Quick start

Requirements: rootless Podman 5, SELinux enforcing, `jq`, a Claude Pro or Max
subscription. `--vm` also needs `/dev/kvm` and libkrun
(`pkexec /usr/bin/bash host/install-krun.sh`; `--dry-run` shows the
transaction).

```bash
ln -s "$PWD/bin/sbx" ~/.local/bin/sbx    # once
sbx build                                # base, rea and egress images
claude setup-token                       # on the host; prints the token
sbx token set                            # paste it
sbx up --copy ~/Downloads/some-binary    # --net api is the default
sbx selftest
sbx ask "Analyse /lab/in/some-binary with REA. Write a report to /lab/out/report.md"
sbx cat report.md
sbx down
```

Use `sbx up --vm` when the target itself will run. `sbx tui` is interactive
Claude. In container mode it runs in tmux, and `sbx attach` connects your
terminal. In vm mode `tui` runs in your terminal; `attach` is not available
there.

## Architecture

```
host (rootless Podman, SELinux enforcing)
│
├─ you, or a Claude Code session on the host ──► bin/sbx
│
│  ┌─ network sbx-int: --internal, no DNS, no default route ─────────────┐
│  │                                                                     │
│  │  claude-sbx   container, or one libkrun microVM per command (--vm)  │
│  │   ├ Claude Code (setup-token auth, bypassPermissions)               │
│  │   ├ REA MCP server, Ghidra 12.1, JDK 21, Chromium, Frida, mitmdump  │
│  │   └ /lab/in (ro) · /lab/out (rw) · /host/<path> (your mounts)       │
│  │                   │ HTTP(S)_PROXY                                   │
│  │  sbx-egress ──────┘ squid ── network sbx-ext ──► internet           │
│  └─────────────────────────────────────────────────────────────────────┘
```

| Layer | What it does |
| --- | --- |
| Credentials | `claude setup-token` only: model requests, no claude.ai connectors, no Remote Control. Podman secret, injected only into the agent's environment. REA does not inherit it, but runs as the same user and could read it from `/proc`. |
| Container | Rootless (your UID mapped to the sandbox user). No capabilities, `no_new_privs`, SELinux `container_t`, read-only root, no host sockets (Wayland, D-Bus, Podman, ssh-agent). No setuid/setgid binaries or file capabilities. Container mode uses `SBX_CPUS` (default 4) and `SBX_MEMORY` (default 8g). The sandbox and each microVM allow 4096 processes. A microVM's guest RAM is `SBX_MEMORY`; the VMM cgroup limit is 1g higher. The proxy is capped at 512m and 256 processes. Seccomp starts from Podman's default, which allows `unshare` and `clone` with `CLONE_NEWUSER` so nested containers work. The profile `sbx` writes drops new namespaces and keyring calls, on the sandbox and on the proxy. Docker's default drops new namespaces too. |
| Agent | `bypassPermissions` is on, so Claude does not ask before a tool call. Only the image's MCP configuration and hooks are loaded. `api` mode turns Claude Code's WebFetch and WebSearch off; the API's own server-side tools stay reachable with the token (see Limits). Each session resets the agent home to the image and keeps transcripts, so a hook, `CLAUDE.md`, a skill or a poisoned npm cache cannot carry into the next session. |
| Network | No route and no DNS in the sandbox. Traffic goes through squid. `api` is the default and allows only `api.anthropic.com`. The allowlist is `dstdomain -n` and it runs before any rule that resolves a name. An earlier config evaluated squid's `dst` ACL first, and that lookup let `secret.attacker.example` reach the attacker's nameserver in `api` mode. `sbx selftest` compares the proxy's UDP counters around requests for random names. `open` allows public destinations on ports 80 and 443. Both modes refuse private, loopback, link-local (cloud metadata), multicast and NAT64 destinations, and IPv6 ranges that embed an IPv4 address (6to4, Teredo, IPv4-compatible); `sbx selftest` probes them, including other spellings of loopback. `none` has no network: Claude cannot run, `sbx sh` still works. |
| Mounts | Read-only by default, only below `mount-roots`. Paths outside the roots can only be copied in. On a writable mount, existing risky entries are bind-mounted read-only, and those paths cannot themselves be mounted writable: `.git` and other git directories, `.gitmodules`, `.gitattributes`, Mercurial and Jujutsu directories, `.claude`, `CLAUDE.md`, `CLAUDE.local.md`, other coding agents' instructions (`AGENTS.md`, `GEMINI.md`, `.cursor` and more), `.mcp.json`, `.envrc`, editor, git-hook-manager, package-manager and toolchain configuration (the full list is `RISKY_NAMES` in `bin/sbx`). Hooks already in a mounted repo stay read-only. A new file beside them is created on the host. |
| Outputs | `sbx down` stops the sandbox, then scans. In `lab/out` it deletes symlinks and special files and moves risky entries to `state/quarantine` in the data directory, with all permissions removed. On a writable mount it lists every file the sandbox changed and flags risky names and new git repositories. The scan uses ctime. Podman's `:z`/`:Z` relabel bumps ctime, so the stamp is written after the relabel; microVM runs share a fixed MCS level and do not relabel again. `sbx ask`, `cat`, `screen`, `egress` and `selftest` strip control characters and bidi controls before printing. `sbx sh` does not. `tui` and `attach` are a live terminal and are not filtered. |

## Limits

- Container mode shares the host kernel. A runtime escape lands as your user.
  A kernel exploit takes the host. Acceptable for static analysis. Use `--vm`
  when the target executes.
- `--vm` is a guest kernel on KVM, via libkrun, with the VMM still inside the
  container policy. The surface that remains is KVM and libkrun device
  emulation in that process. libkrun has no `exec`. virtio-fs shows the VMM's
  `/proc` to guest root, and guest root can reach the VMM from there. Leaving
  the guest takes a guest-kernel exploit; the host is still behind the
  container around the VMM. Keep `crun-krun`, `libkrun` and `libkrunfw`
  updated.
- On a writable mount the scan cannot tell whether a changed script or
  Makefile is hostile. Prefer `lab/out`. Set `git config --global
  safe.bareRepository explicit` so git never treats a planted directory as a
  repository. Entering that directory on the host is what runs git hooks and
  `core.fsmonitor`, direnv on `.envrc`, and a `.claude/settings.json` hook.
- The agent can read its token from `/proc`. `api.anthropic.com` also accepts
  someone else's API key, so a prompt-injected agent can send data, including
  the token, to another Anthropic organisation. In `open` mode anything can
  leave. Revoke the token if you are unsure. Podman's secret store keeps the
  token unencrypted, mode 0600, in your container storage.
- `api` mode limits where the sandbox connects, not what the API does on its
  behalf. With the token or any API key, a request can use Anthropic's
  server-side tools, such as web search, and those reach the internet from
  Anthropic's side. Treat `api` mode as "data can leave through Anthropic",
  not as offline.
- The agent home in the data directory is reset when the next session
  starts, not at `sbx down`. Until then it holds whatever the agent wrote
  there; do not open it with host tools.
- squid's ACLs keep the sandbox's requests off private addresses. squid itself
  runs in a normal network namespace, so a compromised proxy can reach the LAN.
- Mounted host paths are relabelled to `container_file_t` with private
  categories and keep that label after `sbx down`. Do not mount a path that a
  confined system service reads.
- The build-time supply chain is not covered. Node.js, Claude Code, REA,
  mitmproxy, Ghidra, the JDK and the Fedora base image are pinned (all but
  Claude Code and REA by digest or SHA-256). npm and pip still resolve
  transitive dependencies at build time. Fedora packages, Chromium and squid
  among them, come unpinned from the live repositories. npm install scripts
  run in the build container with an open network.

## Commands

`sbx help` prints the full list.

| Command | Purpose |
| --- | --- |
| `sbx up [--net api\|open\|none] [--vm] [--mount PATH[:ro\|:rw]]... [--copy PATH]...` | Start the proxy and the sandbox. `--net` defaults to `api`. Mounts stay fixed for the session. `sbx up --replace` changes them. |
| `sbx restart` | Recreate with the last `--net`, `--vm` and `--mount` options, for example after `sbx token set`. |
| `sbx in PATH...` / `sbx check PATH[:ro\|:rw]...` | `in` copies more inputs into `/lab/in`. `check` dry-runs the mount policy. |
| `sbx ask [--resume ID\|--continue] PROMPT` | Headless `claude -p`. Prints the session ID, the tools used and the result. The transcript goes to `runs/` in the data directory. Resume only into the same `--net`, `--vm` and mounts, or a tighter set: a transcript can carry planted turns. |
| `sbx cat FILE` | Print a result. The read happens inside the sandbox, so a planted symlink cannot point it at a host file. |
| `sbx tui` / `attach` / `screen` / `keys` | Interactive Claude in tmux. `screen` and `keys` let a host session read and type. `attach`, `screen` and `keys` need container mode. In vm mode `tui` runs in your terminal. |
| `sbx sh [-- CMD]` | Shell or one command inside, for example `sbx sh -- rea doctor --json`. Output is not filtered. |
| `sbx egress [-f]` | Destinations the sandbox asked the proxy for. `-f` follows the log. |
| `sbx selftest` | Isolation checks from inside, plus the proxy's DNS behaviour from the host and, in vm mode, the VMM process. |
| `sbx down` / `sbx reset` | `down` stops the sandbox and checks outputs. `reset` deletes the stored transcripts. |

## microVM mode

Frida, process capture and Chromium work in both modes with no extra
privileges: no `SYS_PTRACE`, no relaxed seccomp. They do execute the target. `sbx up --vm` runs every command in a fresh
[libkrun](https://github.com/containers/libkrun) microVM.

- The guest has its own kernel on KVM. libkrun's init sets neither
  `no_new_privs` nor seccomp, so `sbx-guard` sets `no_new_privs` before every
  command and loads a seccomp denylist: new namespaces, the x32 ABI, bpf, perf
  events, userfaultfd, keyrings, io_uring, mount syscalls. That denylist is
  not the container's allowlist.
- The VMM process keeps the container confinement. No capabilities,
  `no_new_privs`, the seccomp profile, SELinux `container_kvm_t` with its own
  MCS categories, the internal network namespace, and only the mounts you
  chose. Guest sockets are proxied into that namespace, so the egress rules
  do not change.
- libkrun cannot `exec` into a running microVM. Each `sbx ask`, `sh`, `cat`
  and `selftest` starts a new one, about 0.4 s. `--resume` works across them.
  The prompt is a read-only file; piped stdin into a microVM was unreliable.
  An interrupted `sbx` removes its microVM. `SIGKILL` leaves one running until
  `sbx down`.

## Configuration

Personal settings are outside the repo, in `~/.config/agent-sandbox/`
(see `config/*.example`). An entry is an absolute path or starts with `~/`.
Runtime data is outside the repo too, in `~/.local/state/agent-sandbox/`
(`SBX_DATA_DIR`): the agent home, `lab/in`, `lab/out`, transcripts in `runs/`,
logs and the quarantine. Nothing the sandbox writes lands in a directory where
git or a Claude Code session works on this repository, and the directory itself
can never be mounted.

- `mount-roots`: directories a mount has to sit under. Default
  `~/Downloads`. `/`, your home or anything above it, a hidden entry in your
  home, this repository, the config and the data directory are refused.
- `deny-paths`: extra host paths that are never mounted or copied.

`versions.env` holds the pins. Before a bump, check REA's changelog for a new
Node.js or Ghidra requirement, edit the file, then `sbx build` and
`sbx restart`. Node.js is not a Fedora package in this image, so a Node
security release means a pin bump.

`SBX_IMAGE`, `SBX_MOUNT_ROOTS`, `SBX_CONFIG_DIR` and `SBX_DATA_DIR` change what
runs, what may be shared or where results land, and `sbx` prints them when they
apply. `SBX_MEMORY` and
`SBX_CPUS` override the container-row limits.

From a Claude Code session on the host, every `sbx` call has to run outside
that session's own sandbox. Rootless Podman does not work inside it. Treat
what `sbx ask`, `sbx screen`, `sbx cat`, `sbx sh`, `sbx tui` and `sbx attach`
show as untrusted. The agent has just read the sample.

## Testing

- `tests/policy.sh` checks the mount policy through `sbx check` against a
  scratch directory: symlinks, git directories (bare, symlinked `HEAD`,
  linked worktrees), risky names, unreadable directories, hard links,
  control characters and the data directory. No Podman needed.
- `tests/guard.sh` runs probes under `sbx-guard` and compares the kernel's
  answers with and without the seccomp filter.
- `sbx selftest` checks a running sandbox from inside and from the host:
  confinement, network refusals (including IPv6 and other spellings of
  loopback), the DNS-leak counter, mounts and, in vm mode, the VMM process.
- CI runs ShellCheck, both test scripts, hadolint and a squid parse of both
  egress configurations on pushes to main and on pull requests.

## Responsible use

- Analyse only software you are allowed to analyse and to share with the
  model provider: everything the agent reads goes to Anthropic, and
  Anthropic's Usage Policy applies to what you ask it to do.
- Keep `--net api` or `none` for live malware. `open` lets the sample's
  traffic reach the internet.
- Use `--vm` whenever the target executes; container mode shares the host
  kernel.
- This is a research tool, not a malware-analysis service. It comes without
  warranty (see the license). Report vulnerabilities as described in
  [SECURITY.md](SECURITY.md).

## How this was built

Started on 23 October 2026 as a private project. The first three commits come
from that repository, with personal paths redacted; the rest is the rework and
hardening for publication. Where Claude Code (Claude Opus) wrote the commit,
the commit names Claude as co-author.

## License

MIT, see [LICENSE](LICENSE). The images install third-party software at build
time: Claude Code (Anthropic's terms; needs your own subscription), REA (MIT),
Ghidra (Apache-2.0), Eclipse Temurin (GPLv2 with Classpath Exception),
mitmproxy (MIT), Node.js (MIT), Chromium, squid and Fedora packages under their
own licenses. This repository contains none of them, and no images are
published.

Not affiliated with Anthropic or the REA project. Only analyse software you
are allowed to analyse.
