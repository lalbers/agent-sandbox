# agent-sandbox

Run an AI coding agent and its tool servers on a Linux workstation without
letting either of them reach more of the host than you hand over.

The concrete case is [REA](https://github.com/morluto/rea), an MCP server for
reverse engineering, driven by Claude Code. The combination is a good stress
test. REA parses untrusted binaries with Ghidra and can run targets under
Frida, and every string it extracts lands in the agent's context. Claude Code's
Bash sandbox does not cover MCP servers; they run with your full user rights,
so a prompt-injected agent could use them to reach `~/.ssh`, your claude.ai
login and its connectors, and the LAN.

agent-sandbox puts Claude Code and REA into rootless Podman, optionally with a
libkrun microVM per command. By default they can reach the model API and
nothing else, and the sandbox checks its own isolation. A small host CLI,
`sbx`, starts it, moves files in and out under a mount policy and drives the
agent inside, either by hand or from a Claude Code session on the host.

Status: a personal lab, tested on Fedora 44 (x86_64) with rootless Podman 5 and
SELinux enforcing. Versions are pinned and updated by hand.

## Threat model

The adversary is the material under analysis: a binary, string or web page
that prompt-injects the agent, or a target that misbehaves when run. Assume
the agent and REA are compromised. They must not read host files you did not
hand over, reach the host, the LAN or your claude.ai account, or leave behind
anything that runs on the host later.

Out of scope: kernel exploits in container mode, data leaving through
`api.anthropic.com` (see Limits), keeping samples away from the model provider,
and the build-time supply chain.

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
| Credentials | Claude Code authenticates with a `claude setup-token` token, which can only make model requests (no claude.ai connectors, no Remote Control). It is a Podman secret, injected only into the agent's environment. REA starts without it, but any process running as the sandbox user can read it from `/proc` (see Limits). |
| Container | Rootless (your UID mapped to the sandbox user), no capabilities, `no_new_privs`, SELinux `container_t`, read-only root, CPU/memory/PID limits, no host sockets (Wayland, D-Bus, Podman, ssh-agent). No setuid/setgid binaries or file capabilities. Seccomp: Podman's default minus new namespaces and keyring calls, also applied to the proxy. |
| Agent | Claude Code runs with `bypassPermissions`. That is deliberate: the container is the boundary. Only the image's MCP configuration and hooks are loaded, and in `api` mode WebFetch and WebSearch are off. At the start of every session the agent's home is reset to the image, keeping only conversation transcripts, so one session cannot leave settings or hooks for the next; `--resume` and `--continue` still replay a stored transcript. |
| Network | No route and no DNS inside; everything goes through squid. `api` mode allows only `api.anthropic.com` and refuses every other name *before* resolving it. `open` mode allows public destinations on ports 80 and 443. Both refuse private, loopback, link-local (cloud metadata), multicast and NAT64 addresses. `none` gives no network at all: Claude cannot run, `sbx sh` still works. |
| Mounts | Read-only by default, only below configured roots, never your home as a whole or a hidden entry in it. In a writable mount, known risky entries stay read-only: `.git` and other git directories, `.claude`, `CLAUDE.md`, `.mcp.json`, `.envrc`, editor, pre-commit, package-manager and toolchain configuration. Such a path itself cannot be mounted writable. Paths outside the roots can only be copied in. |
| Outputs | `sbx down` stops the sandbox first and then checks what it left behind. In `lab/out` it deletes symlinks and special files and moves risky entries to `state/quarantine` with all permissions removed. For writable mounts it lists every file the sandbox changed and flags the risky ones. Text that comes back from the agent has control and bidi characters stripped. |

## Findings

What building this taught me. Each item became code or a `sbx selftest` check.

- **Tool servers are the weak spot.** Claude Code's Bash sandbox covers shell
  commands, not MCP servers, hooks or other helper processes. A powerful MCP
  server needs its own boundary.
- **Scope the credential, not just the process.** A `setup-token` can only make
  model requests. If it leaks, the attacker gets inference on your
  subscription, but not your connected mail, calendar or drives.
- **A proxy can leak through DNS.** squid's "no private destinations" rule is a
  `dst` ACL, and evaluating it makes squid resolve the requested name. In the
  first version that rule ran before the allowlist, so
  `secret.attacker.example` reached the attacker's nameserver even in `api`
  mode. The allowlist (`dstdomain -n`) now runs before any rule that needs DNS,
  and `sbx selftest` compares the proxy's UDP counters before and after
  requests for random names.
- **Podman's default seccomp profile allows user namespaces.** It permits
  `unshare` and `clone` with `CLONE_NEWUSER` so that nested containers work,
  which gives the agent "root" in a namespace and a much larger kernel attack
  surface. `sbx` derives a profile without new namespaces, as Docker's default
  does.
- **A microVM is not automatically a second boundary.** libkrun has no `exec`,
  its guest init sets neither `no_new_privs` nor seccomp, and the VMM's own
  `/proc` is visible in the guest through virtio-fs, where guest root could use
  it to reach the VMM. Escaping therefore takes a guest-kernel exploit plus a
  container escape, not a hypervisor escape: the VM adds a step in front of the
  container boundary, not an independent layer.
- **Outputs are a way back in.** A symlink in the results folder makes host
  tools read host files. In a writable mount, a `.git` with hooks or
  `core.fsmonitor` runs code when a git-aware prompt enters the directory, an
  `.envrc` does the same via direnv, and a `.claude/settings.json` hook runs in
  your host Claude Code. Escape sequences in the agent's answer reach your
  terminal. `sbx` stops the sandbox before it inspects the outputs, so a
  background process cannot plant files after the check.
- **A persistent agent home is a persistence mechanism.** Hooks, `CLAUDE.md`,
  skills or a poisoned npm cache left by one session would run in the next one,
  possibly with more network or mounts. Only the transcripts survive now; they
  can still carry planted turns, so resume a session only into the same or a
  tighter configuration.
- **Relabelling changes ctime.** Podman's `:z`/`:Z` relabel bumps the ctime of
  every mounted file, so every file looked new to the output scan. The stamp is
  now written after the relabel, and microVM runs share a fixed MCS level, so
  later runs do not relabel again.

## Limits

- **Container mode shares the host kernel.** A runtime escape lands as your
  user; a kernel exploit takes the whole host. That is acceptable for static
  analysis. For running hostile code, use `--vm`.
- **vm mode is only as strong as KVM and libkrun.** It moves the attack surface
  to their device emulation in a confined process; see the findings. Keep
  `crun-krun`, `libkrun` and `libkrunfw` updated.
- **Writable mounts are the real way out.** `sbx down` lists every changed file
  and flags known risky names, but it cannot judge a changed script or
  Makefile. Prefer `lab/out`, and set `git config --global
  safe.bareRepository explicit` so git never treats a planted directory as a
  repository.
- **`api` mode means "api.anthropic.com only", not "your account only".** The
  agent can read its token, and the endpoint also accepts someone else's API
  key, so a prompt-injected agent could send data, including the token, to a
  different Anthropic organisation. In `open` mode anything can leave. Revoke
  the token if in doubt.
- **The token is stored in plain text.** Podman's secret store keeps it
  unencrypted (mode 0600) in your container storage.
- **The proxy can reach the LAN.** squid's ACLs keep the sandbox's requests
  away from private addresses, but squid itself runs in a normal network
  namespace. A compromised squid could reach the LAN directly.
- **SELinux labels stay.** Mounted host paths are relabelled to
  `container_file_t` with private categories and keep that label after `sbx
  down`. Do not mount paths that confined system services read.
- **Build-time supply chain.** Node.js, Claude Code, REA, mitmproxy, Ghidra, the
  JDK and the Fedora base image are pinned (all but Claude Code and REA by
  digest or SHA-256). npm and pip still resolve transitive dependencies at build
  time, Fedora packages (Chromium and squid among them) come unpinned from the
  live repositories, and npm install scripts run in the build container with
  unfiltered network.

## Quick start

Requirements: rootless Podman 5, SELinux enforcing, `jq`, a Claude Pro or Max
subscription. For `--vm` you also need `/dev/kvm` and the libkrun runtime
(`pkexec /usr/bin/bash host/install-krun.sh`; `--dry-run` shows the
transaction).

```bash
ln -s "$PWD/bin/sbx" ~/.local/bin/sbx    # once
sbx build                                # base, rea and egress images
claude setup-token                       # on the host; prints the token
sbx token set                            # paste it
sbx up --copy ~/Downloads/some-binary
sbx selftest
sbx ask "Analyse /lab/in/some-binary with REA. Write a report to /lab/out/report.md"
sbx cat report.md
sbx down
```

`sbx up --vm` runs the same workflow with a microVM per command; use it for
anything that executes the target. `sbx tui` starts an interactive Claude in
tmux, and `sbx attach` connects your terminal to it.

## Commands

`sbx help` prints the full list.

| Command | Purpose |
| --- | --- |
| `sbx up [--net api\|open\|none] [--vm] [--mount PATH[:ro\|:rw]]... [--copy PATH]...` | Start the proxy and the sandbox. Mounts are fixed per session; `sbx up --replace` changes them. |
| `sbx restart` | Recreate with the last `--net`, `--vm` and `--mount` options, e.g. after `sbx token set`. |
| `sbx in PATH...` / `sbx check PATH[:rw]...` | Copy more inputs into `/lab/in`; dry-run the mount policy. |
| `sbx ask [--resume ID\|--continue] PROMPT` | Headless run (`claude -p`). Prints the session ID, the tools used and the result; the full transcript goes to `runs/`. |
| `sbx cat FILE` | Print a result. The file is read inside the sandbox, so a planted symlink cannot point it at a host file. |
| `sbx tui` / `attach` / `screen` / `keys` | Interactive Claude in tmux; `screen` and `keys` let a host session read and type. `attach`, `screen` and `keys` need container mode; in vm mode `tui` runs in your terminal. |
| `sbx sh [-- CMD]` | A shell or command inside, e.g. `sbx sh -- rea doctor --json`. Its output is not filtered. |
| `sbx egress [-f]` | Every destination the sandbox asked the proxy for. |
| `sbx selftest` | Isolation checks from inside, plus host-side checks of the proxy's DNS behaviour and, in vm mode, of the VMM process. |
| `sbx down` / `sbx reset` | Stop the session and check its outputs; delete the stored transcripts. |

## microVM mode

Frida, process capture and Chromium work in both modes without extra
privileges (no `SYS_PTRACE`, no relaxed seccomp). They execute the target,
though, and in container mode that code shares the host kernel. `sbx up --vm`
runs every command in a fresh [libkrun](https://github.com/containers/libkrun)
microVM instead.

- The workload runs on its own guest kernel on KVM. libkrun's guest init
  applies none of the container's restrictions, so `sbx-guard` sets
  `no_new_privs` in the guest before every command and loads a seccomp filter
  against new namespaces, the x32 ABI, bpf, perf events, userfaultfd, keyrings,
  io_uring and the mount syscalls. This is a denylist, not the container's full
  allowlist.
- The VMM process on the host keeps the full container confinement: no
  capabilities, `no_new_privs`, the seccomp profile, SELinux `container_kvm_t`
  with its own MCS categories, the internal network namespace and only the
  chosen mounts. Guest sockets are proxied into that namespace, so the egress
  policy applies unchanged.
- A microVM cannot be `exec`'d into, so each `sbx ask`, `sh`, `cat` and
  `selftest` starts a new one (about 0.4 s). `--resume` works across them. The
  prompt is handed over as a read-only file, because piped stdin into a
  microVM proved unreliable. An interrupted `sbx` removes its microVM; only
  `SIGKILL` leaves one running until `sbx down`.

## Configuration

Personal settings live outside the repository in `~/.config/agent-sandbox/`
(see `config/*.example`). Entries are absolute paths or start with `~/`.

- `mount-roots`: directories below which paths may be mounted. The default is
  `~/Downloads`. `/`, your home or anything above it, hidden entries in it,
  this repository and the config directory are refused as roots.
- `deny-paths`: extra host paths that are never mounted or copied.

`versions.env` pins every version. To update, check REA's changelog for new
Node.js or Ghidra requirements, edit the file, run `sbx build` and then
`sbx restart`. Node.js is not a Fedora package here, so its security releases
need a pin bump. Environment overrides: `SBX_MEMORY` (default `8g`) and
`SBX_CPUS` (`4`), plus `SBX_IMAGE`, `SBX_MOUNT_ROOTS` and `SBX_CONFIG_DIR`,
which change what runs or what may be shared and are reported whenever they
apply.

Driving the sandbox from a Claude Code session on the host needs every `sbx`
call to run outside that session's own sandbox, because rootless Podman does
not work inside it. Treat everything `sbx ask`, `sbx screen` and `sbx cat`
return as untrusted data: it comes from an agent that has just read the
material under analysis.

## How this was built

Built from 23 to 25 October 2026 in a private repository; the history here
starts at the import, and later commits are follow-up work. Claude Code
(Claude Opus) wrote most of the code and documentation in sessions I steered.
I set the goal and the requirements, chose between the designs that came up,
and made the security trade-offs, such as `bypassPermissions` behind the
container boundary and adding microVM mode as a second phase. After each
phase, separate Claude agents were told to break the result and ran live tests;
most of the findings above came out of those reviews. Commits name Claude as
co-author where it wrote the content.

## License

MIT, see [LICENSE](LICENSE). The images install third-party software at build
time: Claude Code (Anthropic's terms; needs your own subscription), REA (MIT),
Ghidra (Apache-2.0), Eclipse Temurin (GPLv2 with Classpath Exception),
mitmproxy (MIT), Node.js (MIT), Chromium, squid and Fedora packages under their
own licenses. This repository contains none of them, and no images are
published.

This project is not affiliated with Anthropic or the REA project. Only analyse
software you are allowed to analyse.
