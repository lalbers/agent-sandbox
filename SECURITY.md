# Security policy

## Reporting a vulnerability

Report it privately through GitHub: the repository's **Security** tab, then
**Report a vulnerability**. Please do not open a public issue. Include the
commit you tested, your setup (distribution, Podman and libkrun versions,
`--net` and `--vm` options) and the steps to reproduce. Do not include real
tokens or samples you may not share.

This is a single-maintainer project. Expect a first answer within a week; fixes
land on `main`, which is the only supported version.

## In scope

The threat model is the one in the README: the analysed sample compromises the
agent and REA. A report is in scope if, from that position, it can:

- reach a host path that was neither mounted nor copied, or write to a path
  mounted read-only;
- get `sbx check` or `sbx up` to accept a mount the policy should refuse;
- reach the LAN, the host, cloud metadata or, in `api` mode, any host other
  than `api.anthropic.com`, or leak data through DNS;
- leave a symlink, a risky entry or a change in `lab/out` or an rw mount that
  `sbx down` does not report or defuse;
- run code on the host through what `sbx` prints or what the host tools it
  names act on;
- escape a microVM, or get a microVM to run or write after `sbx down` scanned.

## Out of scope

These are listed as limits in the README:

- kernel exploits in container mode;
- data leaving through `api.anthropic.com`, including the API's server-side
  tools reached with the token;
- the build-time supply chain (unpinned Fedora packages, npm and pip
  resolution at build time);
- vulnerabilities in Claude Code, REA, Ghidra, Podman, crun, libkrun or squid
  themselves (please report those upstream), unless `sbx` uses them unsafely;
- setups that deliberately weaken the defaults, such as mount roots that
  contain sensitive data or `--net open` with live malware.
