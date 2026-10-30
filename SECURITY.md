# Security policy

## Reporting a vulnerability

Report a vulnerability privately through GitHub: the repository's **Security**
tab, then **Report a vulnerability**. Please do not open a public issue.
Include the commit you tested, your setup (distribution, Podman and libkrun
versions, `--net`, and `--vm`), and the steps to reproduce. Do not include
real tokens or samples you may not share.

This is a single-maintainer project. Expect a first answer within a week.
Fixes land on `main`, the only supported version.

## In scope

The README threat model applies: the analysed sample compromises the agent
and REA. A report is in scope if the sample can:

- reach a host path neither mounted nor copied, or write to a read-only
  mount;
- get `sbx check` or `sbx up` to accept a mount the policy should refuse;
- reach the LAN, the host, or cloud metadata; in `api` mode, reach any
  host other than `api.anthropic.com`; leak data through DNS; or get the
  egress proxy to allow a destination it should refuse;
- leave, in `lab/out`, a symlink or special file `sbx down` did not
  delete, or a risky entry it did not quarantine;
- leave, on an rw mount, a changed file `sbx down` did not list, or a
  risky name, symlink, or new git repository it did not flag;
- run code on the host through what `sbx` prints, or when a host tool
  that `sbx` names acts on files left in `lab/out` or on an rw mount
  (git hooks, `core.fsmonitor`, `.envrc` via direnv, or Claude Code
  project settings);
- get past the VMM's container confinement, or get a microVM to run or
  write after `sbx down` scanned `lab/out` and rw mounts.

## Out of scope

README limits are out of scope.

- Kernel exploits in container mode.
- Data can leave through `api.anthropic.com`, including the API's
  server-side tools reached with the token.
- The build-time supply chain (unpinned Fedora packages, npm and pip
  resolution at build time).
- Hostile file contents in `lab/out` are not a finding by themselves.
  There, `sbx down` only deletes symlinks and special files, and
  quarantines risky entries.
- Deletions and directory-only changes on an rw mount are unreported by
  design.
- Guest root can reach the VMM inside container confinement.
- A compromised egress proxy can reach the LAN from its normal network
  namespace.

Vulnerabilities in Claude Code, REA, Ghidra, Podman, crun, libkrun, or squid
themselves (please report those upstream) are out of scope, unless `sbx`
uses them unsafely.

Setups such as mount roots that contain sensitive data, or `--net open`
with live malware, deliberately weaken the defaults and are out of scope.
