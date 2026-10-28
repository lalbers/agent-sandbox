# agent-sandbox

Run an AI coding agent and its tool servers on a Linux workstation without
letting either of them touch the host.

The concrete case is [REA](https://github.com/morluto/rea), an MCP server for
reverse engineering, driven by Claude Code. That combination is a good stress
test. REA parses untrusted binaries with Ghidra and can execute targets under
Frida, and every string it extracts lands in the agent's context. Claude
Code's own Bash sandbox does not help here, because it does not cover MCP
servers: they run with your full user rights. On an ordinary workstation the
agent could then reach `~/.ssh`, your Claude login with its claude.ai
connectors, and the LAN.

This lab puts Claude Code and REA into rootless Podman, optionally with a
libkrun microVM per command. It lets them reach the model API and nothing
else, and it checks its own isolation. A small host CLI, `sbx`, starts the lab,
moves files in and out under a mount policy and drives the agent inside, by
hand or from a Claude Code session on the host.

Status: a personal lab, tested on Fedora 44 (x86_64) with rootless Podman 5
and SELinux enforcing. Versions are pinned and updated by hand.

## Architecture

```
host (rootless Podman, SELinux enforcing)
│
├─ you, or a Claude Code session on the host ──► bin/sbx
│
│  ┌─ network sbx-int: --internal, no DNS, no default route ───────────┐
│  │                                                                     │
│  │  claude-sbx   container, or one libkrun microVM per command (--vm) │
│  │   ├ Claude Code (setup-token auth, bypassPermissions)               │
│  │   ├ REA MCP server, Ghidra 12.1, JDK 21, Chromium, Frida, mitmdump  │
│  │   └ /lab/in (ro) · /lab/out (rw) · /host/<path> (your mounts)       │
│  │                   │ HTTP(S)_PROXY                                   │
│  │  sbx-egress ──────┘ squid ── network sbx-ext ──► internet           │
│  └─────────────────────────────────────────────────────────────────────┘
```

| Layer | What it does |
| --- | --- |
| Credentials | Claude Code authenticates with a token from `claude setup-token`. It can only make model requests: no claude.ai connectors, no Remote Control. It is stored as a Podman secret and never mounted or passed on the command line. `disableClaudeAiConnectors` is set as well. |
| Container | Rootless, user namespace mapped to your UID, no capabilities, `no_new_privs`, SELinux `container_t`, read-only root filesystem, CPU, memory and PID limits, no host sockets (Wayland, D-Bus, Podman, ssh-agent). The images contain no setuid/setgid binaries and no file capabilities. Seccomp: Podman's default profile without new namespaces, regenerated on every `sbx up`. |
| Agent | Claude Code runs with `bypassPermissions`. I made that choice on purpose: the container is the boundary, not a permission prompt inside it. Only the image's MCP configuration is loaded (`--strict-mcp-config`). |
| Network | The sandbox has no route and no DNS. Everything goes through a squid proxy. In `api` mode it allows only `api.anthropic.com` and refuses every other name *before* resolving it. In `open` mode it allows the public internet. Both modes refuse private, loopback, link-local (cloud metadata), multicast and NAT64 addresses, so the LAN and the host stay out of reach. `none` gives no network at all. |
| Mounts | Read-only by default, only below configured roots, never your home directory as a whole or any hidden entry in it. Every existing `.git` inside a writable mount is mounted read-only. Anything else can only be copied in. |
| Outputs | `sbx down` stops the sandbox first and then checks what it left behind. In `lab/out` it removes symlinks and special files and renames `.git` and `.envrc`. In writable mounts it lists new `.git`, `.envrc` and symlinks. Text that comes back from the agent has its control characters stripped. |

## Quick start

Requirements: rootless Podman 5, SELinux enforcing, `jq`, a Claude Pro or Max
subscription. For `--vm`, also `/dev/kvm` and the libkrun runtime
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

`sbx up --vm` runs the same workflow with a microVM per command. Use it for
anything that executes the target. `sbx tui` starts an interactive Claude in
tmux; `sbx attach` connects your terminal to it.

## Commands

`sbx help` prints the full list.

| Command | Purpose |
| --- | --- |
| `sbx up [--net api\|open\|none] [--vm] [--mount PATH[:ro\|:rw]]... [--copy PATH]...` | Start the proxy and the sandbox. Mounts are fixed per session; `sbx up --replace` changes them. |
| `sbx restart` | Recreate with the last `--net`, `--vm` and `--mount` options, e.g. after `sbx token set`. |
| `sbx in PATH...` / `sbx check PATH[:rw]...` | Copy more inputs into `/lab/in`; dry-run the mount policy. |
| `sbx ask [--resume ID\|--continue] PROMPT` | Headless run (`claude -p`). Prints the session ID, the tools used and the result; the full transcript goes to `runs/`. |
| `sbx cat FILE` | Print a result. The file is read inside the sandbox, so a planted symlink cannot point it at a host file. |
| `sbx tui` / `attach` / `screen` / `keys` | Interactive Claude in tmux. `screen` and `keys` let a host session read and type (container mode). |
| `sbx sh [-- CMD]` | A shell or command inside, e.g. `sbx sh -- rea doctor --json`. |
| `sbx egress [-f]` | Every destination the sandbox asked the proxy for. |
| `sbx selftest` | Isolation checks from inside, plus host-side checks of the proxy's DNS behaviour and, in vm mode, of the VMM process. |
| `sbx down` / `sbx reset` | Stop the session and check its outputs; wipe the sandbox home. |

## microVM mode

Frida, process capture and Chromium work in both modes without extra
privileges (no `SYS_PTRACE`, no relaxed seccomp). They execute the target,
though, and in container mode that code shares the host kernel. `sbx up --vm`
runs every command in a fresh [libkrun](https://github.com/containers/libkrun)
microVM instead:

- The workload runs on its own guest kernel on KVM. libkrun's guest init
  applies none of the container's restrictions. `sbx-guard` therefore sets
  `no_new_privs` inside the guest before every command and loads a seccomp
  filter. The filter blocks new namespaces, the x32 ABI, bpf, perf events,
  userfaultfd, keyrings, io_uring and the mount syscalls.
- The VMM process on the host keeps the full container confinement: no
  capabilities, `no_new_privs`, the seccomp profile, SELinux `container_kvm_t`
  with its own MCS categories, the internal network namespace and only the
  chosen mounts. Guest sockets are proxied into that namespace, so the egress
  policy applies unchanged.
- A microVM cannot be `exec`'d into. Each `sbx ask`, `sh`, `cat` and
  `selftest` therefore starts a new one (about 0.4 s). Claude sessions persist
  in `state/home`, so `--resume` works across them. The prompt is handed over
  as a read-only file, because piped stdin into a microVM proved unreliable.

## Findings

These are the things I learned while building it. Each one turned into code
or a check in `sbx selftest`.

- **Tool servers are the weak spot.** Claude Code's Bash sandbox covers shell
  commands, not MCP servers, hooks or other helper processes. A powerful MCP
  server needs its own boundary.
- **Scope the credential, not just the process.** A `setup-token` can only
  make model requests. If it leaks, the attacker gets inference on your
  subscription, but not your connected Gmail, calendar or drives.
- **A proxy can leak through DNS.** In the first version, squid evaluated the
  "no private destinations" rule (a `dst` ACL) before the allowlist. That rule
  makes squid resolve every requested hostname, so `secret.attacker.example`
  reached the attacker's nameserver even in "API only" mode. The selftest now
  compares the proxy's UDP counters before and after requests for random
  names.
- **Podman's default seccomp profile allows user namespaces.** It allows
  `unshare` and `clone` with `CLONE_NEWUSER` so that nested containers work,
  and that gives the agent "root" in a namespace, with a much larger kernel
  attack surface. `sbx` derives a profile without new namespaces, the same
  thing Docker's default profile does.
- **A microVM is not automatically a second boundary.** libkrun has no
  `exec`, its guest init sets neither `no_new_privs` nor seccomp, and the
  VMM's own `/proc` is visible in the guest through virtio-fs. Guest root
  could use that to reach the VMM. The VM adds a guest-kernel exploit in front
  of the container-grade boundary, but the two do not combine into
  independent layers.
- **Outputs are a way back in.** A symlink in the results folder makes host
  tools read host files. A `.git` with hooks or `core.fsmonitor`, or an
  `.envrc`, in a writable mount runs code the next time you `cd` there with a
  git-aware prompt. Escape sequences in the agent's answer reach your terminal.
  `sbx` stops the sandbox before it inspects the outputs, so a background
  process cannot plant files after the check.
- **Relabelling changes ctime.** Podman's `:z`/`:Z` relabel bumps the inode
  ctime of every mounted file. That broke change detection based on ctime
  until the stamp was set after the start, and the microVM runs got a fixed
  MCS level.

## Limits

- **Container mode shares the host kernel.** A kernel exploit escapes as your
  user. That is fine for static analysis. For running hostile code, use `--vm`.
- **vm mode** moves the attack surface to KVM and libkrun's device emulation in
  a confined process; see the findings above. Keep `crun-krun`, `libkrun` and
  `libkrunfw` updated.
- **Writable mounts are the real way out.** `sbx` reports new `.git`, `.envrc`
  and symlinks there but cannot judge scripts or Makefiles the agent changed.
  Prefer `lab/out`.
- **`api` mode means "api.anthropic.com only", not "your account only".** The
  endpoint also accepts someone else's API key, so code planted by a
  prompt-injected agent could upload data, including the token, to a different
  Anthropic organisation. In `open` mode anything can leave. Revoke the token
  if in doubt.
- **SELinux labels stay.** Mounted host paths are relabelled to
  `container_file_t` and keep that label after `sbx down`. Do not mount paths
  that confined system services read.
- **Build-time supply chain.** Node.js, Claude Code, REA, mitmproxy, Ghidra and
  the JDK are pinned (Node.js, mitmproxy, Ghidra and the JDK by SHA-256). npm
  and pip still resolve transitive dependencies at build time, and npm install
  scripts run in the build container with unfiltered network.

## Configuration

Personal settings live outside the repository in `~/.config/agent-sandbox/`
(see `config/*.example`):

- `mount-roots`: directories below which paths may be mounted. The default is
  `~/Downloads`.
- `deny-paths`: extra host paths that are never mounted or copied.

`versions.env` pins every version. To update one, check REA's changelog for new
Node.js or Ghidra requirements, edit the file, run `sbx build` and then
`sbx restart`. Node.js is not a Fedora package here, so its security releases
need a pin bump. Environment overrides: `SBX_MEMORY` (default `8g`),
`SBX_CPUS` (`4`), `SBX_IMAGE`, `SBX_MOUNT_ROOTS`, `SBX_CONFIG_DIR`.

Driving the lab from a Claude Code session on the host needs every `sbx` call
to run outside that session's own sandbox, because rootless Podman does not
work inside it. Treat everything `sbx ask`, `sbx screen` and `sbx cat` return
as untrusted data. It comes from an agent that has just read the material
under analysis.

## How this was built

I built this from 23 to 25 October 2026 in a private repository and imported
it here once it had settled; this history starts with that import. I set the
goal and the requirements, chose between the options that came up and made the
security trade-offs, such as `bypassPermissions` behind the container boundary
and the two-phase plan with a microVM mode. Claude Code (Claude Opus) wrote
most of the code and documentation in sessions I steered. After each phase,
separate Claude agents reviewed the result with instructions to break it, and
they ran live tests. Most of the findings above came out of those reviews.
Commits name Claude as co-author where it wrote the content.

## License

MIT, see [LICENSE](LICENSE). The images install third-party software at build
time: Claude Code (Anthropic's terms; needs your own subscription), REA (MIT),
Ghidra (Apache-2.0), Eclipse Temurin (GPLv2 with Classpath Exception),
mitmproxy (MIT), Node.js (MIT), Chromium, squid and Fedora packages under their
own licenses. This repository contains none of them, and no images are
published.

This is not affiliated with Anthropic or the REA project. Only analyse
software you are allowed to analyse.
