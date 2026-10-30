# agent-sandbox

[![CI](https://github.com/lalbers/agent-sandbox/actions/workflows/ci.yml/badge.svg)](https://github.com/lalbers/agent-sandbox/actions/workflows/ci.yml)

`sbx` runs Claude Code and [REA](https://github.com/morluto/rea) in rootless
Podman, for analysing untrusted binaries with an AI agent. `--vm` selects
vm mode, which uses libkrun microVMs. One person maintains it, and it
started on 23 October 2026 as a private project.

It exists because Claude Code's Bash sandbox covers shell commands and does
not cover MCP servers, hooks or other helper processes. On the host those
run as you, so they can read `~/.ssh` and the claude.ai login and its
connectors, and they can reach the LAN.

REA is where that gap becomes concrete. It is an MCP server for reverse
engineering: it parses untrusted binaries with Ghidra, it can run a target
under Frida, and the strings it extracts land in the agent's context.

The tested setup is Fedora 44 (x86_64), rootless Podman 5 and SELinux
enforcing. Other setups are untested, and versions in `versions.env` are
bumped by hand.

## Threat model

Assume the agent and REA are compromised by the sample. That sample is a
binary, a string or a page that prompt-injects the agent, or a target that
misbehaves when it runs.

A host path is visible to them only if you mounted or copied it. They have
no route and no DNS of their own. `/lab/out` is backed by a host directory
in the data directory, and an rw mount (`--mount PATH:rw`) is a host
directory too. Those are the two trees `sbx down` scans after the sandbox
has stopped.

Kernel exploits in container mode, data leaving through
`api.anthropic.com`, keeping the sample away from the model provider, and
the build-time supply chain are out of scope.

## Quick start

You need rootless Podman 5, SELinux enforcing, `jq`, and a Claude
Pro or Max subscription. `perl` (with Encode) is needed for the full
stripping of control and bidi characters. `claude setup-token` runs on
the host, so Claude Code has to be installed there. vm mode also needs
`/dev/kvm` and libkrun. `pkexec /usr/bin/bash host/install-krun.sh`
installs it. `/usr/bin/bash host/install-krun.sh --dry-run` shows the
transaction and needs no root.

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

Use `sbx up --vm` when the target itself will run.

From a Claude Code session on the host, every `sbx` call has to run outside
that session's own sandbox. Rootless Podman does not work inside it. Treat
what `sbx ask`, `sbx screen`, `sbx cat`, `sbx sh`, `sbx tui` and
`sbx attach` show as untrusted. The agent has just read the sample.

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

`ask`, `cat`, `tui`, `sh` and `selftest` run inside the sandbox. In vm
mode, libkrun cannot exec into a running microVM, so each of `ask`, `cat`,
`tui` and `sh` starts a fresh
[libkrun](https://github.com/containers/libkrun) microVM (about 0.4 s).
`selftest` starts more than one, for in-guest checks and host-side checks
of the VMM. In container mode, `screen`, `keys` and `attach` also exec into
the container (tmux).

In container mode the sandbox is one long-running container, so `/tmp` and
background processes persist between asks. In vm mode they do not carry
over from one microVM to the next.

### Credentials

`claude setup-token` is the only auth. It is for model requests, with no
claude.ai connectors and no Remote Control. The token is a Podman secret,
placed into the environment of the whole sandbox: the agent, its Bash
tool, `sbx sh` and any target the agent starts. Only REA's MCP server is
started without it. REA runs as the same user, and anything in the sandbox
running as that user can read the token from `/proc`.

### Container

The sandbox is rootless, with your UID mapped to the sandbox user. It runs
with no capabilities, `no_new_privs` set, SELinux type `container_t` and a
read-only root. There are no host sockets for Wayland, D-Bus, Podman or
ssh-agent, and no setuid or setgid binaries or file capabilities.

In container mode, `SBX_CPUS` (default 4) and `SBX_MEMORY` (default 8g) are
the CPU and memory limits, and the sandbox allows 4096 processes. The
egress proxy (squid) is capped at 512m and 256 processes. In vm mode
`SBX_CPUS` is the vCPU count, with no `--cpus` quota, and `SBX_MEMORY` is
guest RAM, with the VMM cgroup limit 1g higher. `--pids-limit 4096` caps
the host-side VMM process, not the processes inside the guest.

Seccomp starts from Podman's default, which allows `unshare` and `clone`
with `CLONE_NEWUSER` so nested containers work. The profile `sbx` writes
drops new namespaces and keyring calls, on the sandbox and on the egress
proxy. Docker's default drops new namespaces too. The guest filter is
separate; see vm mode.

### Agent

`bypassPermissions` is on, so Claude does not ask before a tool call. Only
the image's MCP configuration and hooks are loaded. `api` mode turns
Claude Code's WebFetch and WebSearch off. The API's own server-side tools
stay reachable with the token.

`sbx up` and `sbx restart` reset the agent home to the image. That reset
is what stops a planted hook, `CLAUDE.md`, a skill or a poisoned npm cache
from carrying into the next sandbox. Until then, whatever the agent wrote
into the home stays for later `sbx ask` calls. Transcripts live at
`state/home/.claude/projects` and survive the reset. Per-run files from
`sbx ask` (`prompt.txt`, `stream.jsonl`, `stderr.log`) go to `runs/`.

### Network

The sandbox has no route and no DNS of its own. Traffic goes through the
egress proxy.

`api` is the default and allows only `api.anthropic.com`. The allowlist is
`dstdomain -n`, and it runs before any rule that resolves a name. An
earlier config evaluated squid's `dst` ACL first, and that lookup let
`secret.attacker.example` reach the attacker's nameserver in `api` mode.
`sbx selftest` compares the egress proxy's UDP counters around requests
for random names.

`open` allows public destinations on ports 80 and 443. Both `api` and
`open` refuse private ranges, loopback, link-local (cloud metadata), CGNAT,
multicast, NAT64 and the IPv6 ranges that embed an IPv4 address (6to4,
Teredo, IPv4-compatible). `sbx selftest` probes loopback (also other
spellings), private and link-local addresses, cloud metadata, NAT64, 6to4,
Teredo, IPv4-compatible addresses, ULA and link-local IPv6. It does not
probe multicast or CGNAT.

`none` has no network. Claude cannot run, and `sbx sh` still works.

### Mounts

Mounts are read-only by default, and only below `mount-roots`. Paths
outside the roots can only be copied in. On an rw mount, existing risky
entries are bind-mounted read-only, and those paths cannot themselves be
mounted writable. The names are `.git` and other git directories,
`.gitmodules`, `.gitattributes`, Mercurial and Jujutsu directories,
`.claude`, `CLAUDE.md`, `CLAUDE.local.md`, other coding agents'
instructions (`AGENTS.md`, `GEMINI.md`, `.cursor` and more), `.mcp.json`,
`.envrc`, and editor, git-hook-manager, package-manager and toolchain
configuration. The full list is `RISKY_NAMES` in `bin/sbx`.

The sandbox cannot change a hook that is already in a mounted repo, because
that path stays read-only, but a new file it creates next to a hook on an
rw mount lands on the host.

### Outputs

`sbx down` stops the sandbox, then scans.

In `/lab/out` it deletes every symlink and special file and moves every
risky entry to `state/quarantine` in the data directory, with all
permissions removed, regardless of ctime.

On an rw mount it lists every file (not directory) whose ctime is newer
than the start of the sandbox, and flags risky names and new git
repositories. Deletions and directory-only changes are not reported.
`sbx` relabels mounts with `:Z` only, which bumps ctime, so the scan stamp
is written after that relabel. Every microVM run reuses the MCS level
`s0:c701,c702`, distinct from other containers, and does not relabel again.

`sbx ask`, `cat`, `screen`, `egress` and `selftest` strip control
characters and bidi controls before printing. `perl` (with Encode) is
needed for the full stripping of control and bidi characters. Without
`perl`, only C0 controls and DEL are stripped. `sbx sh` does not strip.
`tui` and `attach` are a live terminal and are not filtered.

## Limits

Container mode shares the host kernel, so a runtime escape lands as your
user and a kernel exploit takes the host. That is acceptable for static
analysis; use `--vm` when the target executes.

vm mode is a guest kernel on KVM, via libkrun, with the VMM still inside
the container confinement. The surface that remains is KVM and libkrun
device emulation in that process. virtio-fs shows the VMM's `/proc` to
guest root, so guest root can reach the VMM from there. Leaving the guest
takes a guest-kernel exploit, and the host is then still behind the VMM's
container confinement. Keep `crun-krun`, `libkrun` and `libkrunfw` updated.

On an rw mount the scan cannot tell whether a changed script or Makefile
is hostile, so prefer `lab/out`. Set `git config --global
safe.bareRepository explicit`; `sbx up` prints this tip. The setting only
stops git from implicitly using a planted bare repository, and a planted
`.git` directory is still a repository. Hooks run on git commands, and
`core.fsmonitor` runs on commands such as `git status`. Shell prompts that
show git status may run those when you enter the directory. direnv runs
`.envrc` once you have allowed it, and a `.claude/settings.json` hook runs
when Claude Code starts there.

`api.anthropic.com` also accepts someone else's API key, so a
prompt-injected agent can send data, including the token, to another
Anthropic organisation. In `open` mode anything can leave. Revoke the token
if you are unsure. Podman's secret store keeps the token unencrypted, mode
0600, in your container storage.

`api` mode limits where the sandbox connects, not what the API does on its
behalf. With the token or any API key, a request can use Anthropic's
server-side tools, such as web search, and those reach the internet from
Anthropic's side. Treat `api` mode as "data can leave through Anthropic",
not as offline.

Do not open the agent home with host tools. `sbx down` does not clear it.

The egress proxy's ACLs keep the sandbox's requests off private addresses.
It runs in a normal network namespace, so if it is compromised it can
reach the LAN.

Mounted host paths are relabelled to `container_file_t` with private
categories and keep that label after `sbx down`. Do not mount a path that
a confined system service reads.

The build-time supply chain is not covered. Node.js, Claude Code, REA,
mitmproxy, Ghidra, the JDK and the Fedora base image are pinned (all but
Claude Code and REA by digest or SHA-256). npm and pip still resolve
transitive dependencies at build time. Fedora packages, Chromium and squid
among them, come unpinned from the live repositories. npm install scripts
run in the build container with an open network (npm 11 only warns about
`allowScripts`).

## Commands

`sbx help` prints the full list.

- `sbx up [--net api|open|none] [--vm] [--mount PATH[:ro|:rw]]... [--copy PATH]...`
  starts the egress proxy and the sandbox. `--net` defaults to `api`.
  Mounts stay fixed for the session. `sbx up --replace` changes them.
- `sbx restart` recreates the sandbox with the last `--net`, `--vm` and
  `--mount` options, for example after `sbx token set`.
- `sbx in PATH...` copies more inputs into `/lab/in`. `sbx check
  PATH[:ro|:rw]...` dry-runs the mount policy.
- `sbx ask [--resume ID|--continue] PROMPT` is headless `claude -p`. It
  prints the session ID, the tools used and the result. Per-run files go
  to `runs/`. Resume only into the same `--net`, `--vm` and mounts, or a
  tighter set: a transcript can carry planted turns.
- `sbx cat FILE` prints a result. `FILE` is relative to `/lab/out`, or an
  absolute path inside the sandbox. The read happens inside the sandbox,
  so a planted symlink cannot point it at a host file.
- `sbx tui` starts interactive Claude. In container mode it runs in tmux,
  and `attach` connects your terminal to that session. In vm mode `tui`
  runs in your terminal. `screen` and `keys` let a host session read the
  session and type into it. `attach`, `screen` and `keys` need container
  mode.
- `sbx sh [-- CMD]` is a shell, or one command, inside the sandbox, for
  example `sbx sh -- rea doctor --json`. Output is not filtered.
- `sbx egress [-f]` shows destinations the sandbox asked the egress proxy
  for. `-f` follows the log.
- `sbx selftest` runs isolation checks from inside, plus the egress
  proxy's DNS behaviour from the host and, in vm mode, the VMM process.
- `sbx down` stops the sandbox and checks outputs. `sbx reset` deletes the
  agent home, including the conversation transcripts.

## vm mode

Frida, process capture and Chromium work in both modes with no extra
privileges: no `SYS_PTRACE`, and no relaxed seccomp. They do execute the
target.

The guest has its own kernel on KVM. libkrun's init sets neither
`no_new_privs` nor seccomp, so `sbx-guard` sets `no_new_privs` before every
command and loads a seccomp denylist: new namespaces, the x32 ABI, bpf,
perf events, userfaultfd, keyrings, io_uring and mount syscalls. That
denylist is weaker than the container's seccomp profile.

The VMM process keeps the container confinement: no capabilities,
`no_new_privs`, the seccomp profile, SELinux `container_kvm_t` with its own
MCS categories, the internal network namespace, and only the mounts you
chose. Guest sockets are proxied into that namespace, so the egress rules
do not change.

`--resume` works from one command's microVM to the next. The prompt is
passed as a read-only file because piped stdin into a microVM was
unreliable. An interrupted `sbx` removes its microVM; `SIGKILL` leaves one
running until `sbx down`.

## Configuration

Personal settings are outside the repo, in `~/.config/agent-sandbox/`
(see `config/*.example`). An entry is an absolute path or starts with `~/`.
Runtime data is outside the repo too, in `~/.local/state/agent-sandbox/`
(`SBX_DATA_DIR`): the agent home, `lab/in`, `lab/out`, per-run files in
`runs/`, logs and the quarantine. Nothing the sandbox writes lands in a
directory where git or a Claude Code session on the host works on this
repository, and the data directory itself can never be mounted.

`mount-roots` lists directories a mount has to sit under. The default is
`~/Downloads`. `/`, your home or anything above it, a hidden entry in your
home, this repository, the config and the data directory are refused.
`deny-paths` lists extra host paths that are never mounted or copied.

`versions.env` holds the pins. Before a bump, check REA's changelog for a
new Node.js or Ghidra requirement, edit the file, then `sbx build` and
`sbx restart`. Node.js is not a Fedora package in this image, so a Node
security release means a pin bump.

`SBX_IMAGE`, `SBX_MOUNT_ROOTS`, `SBX_CONFIG_DIR` and `SBX_DATA_DIR` change
what runs, what may be shared or where results land. `sbx up`, `sbx check`
and `sbx in` print them when they apply. `SBX_MEMORY` and `SBX_CPUS` set
the limits described under Container.

## Testing

- `tests/policy.sh` checks the mount policy through `sbx check` against a
  scratch directory: symlinks, git directories (bare, symlinked `HEAD`,
  linked worktrees), risky names, unreadable directories, hard links,
  control characters and the data directory. No Podman is needed.
- `tests/guard.sh` runs probes under `sbx-guard` and compares the kernel's
  answers with and without the seccomp filter.
- `sbx selftest` checks a running sandbox from inside and from the host:
  confinement, network refusals, the DNS-leak counter, mounts and, in vm
  mode, the VMM process.
- CI runs ShellCheck, both test scripts, hadolint and a squid parse of
  both egress configurations on pushes to main and on pull requests.

## Responsible use

- Analyse only software you are allowed to analyse and to share with the
  model provider: everything the agent reads goes to Anthropic, and
  Anthropic's Usage Policy applies to what you ask it to do.
- Keep `--net api` or `none` for live malware. `open` lets the sample's
  traffic reach the internet.
- Use `--vm` whenever the target executes. Container mode shares the host
  kernel.
- This is a research tool, not a malware-analysis service. It comes
  without warranty (see the license). Report vulnerabilities as described
  in [SECURITY.md](SECURITY.md).

## How this was built

The first three commits come from the private repository the project
started in, with personal paths redacted. The rest is the rework and
hardening for publication. Every commit in this repository names Claude as
co-author in a `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
trailer.

## License

MIT, see [LICENSE](LICENSE). The images install third-party software at
build time: Claude Code (Anthropic's terms; needs your own subscription),
REA (MIT), Ghidra (Apache-2.0), Eclipse Temurin (GPLv2 with Classpath
Exception), mitmproxy (MIT), Node.js (MIT), Chromium, squid and Fedora
packages under their own licenses. This repository contains none of them,
and no images are published.

Not affiliated with Anthropic or the REA project.
