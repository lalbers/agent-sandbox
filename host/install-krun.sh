#!/usr/bin/bash
# Install the libkrun microVM runtime for rootless Podman (crun-krun pulls in
# libkrun and libkrunfw from the Fedora repositories). Host-side, needs root.
#
#   /usr/bin/bash host/install-krun.sh --dry-run    # show what would change
#   pkexec /usr/bin/bash host/install-krun.sh       # install
#
# Undo: pkexec dnf remove crun-krun libkrun libkrunfw
set -euo pipefail

PKGS=(crun-krun)

if [ "${1:-}" = --dry-run ]; then
    # dnf5 shows the transaction and changes nothing with --assumeno.
    dnf -q install --assumeno "${PKGS[@]}" || true
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "install-krun: run it via pkexec (or --dry-run)" >&2; exit 1; }
dnf install -y "${PKGS[@]}"
rpm -q crun-krun libkrun libkrunfw
