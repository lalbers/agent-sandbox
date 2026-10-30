#!/bin/bash
# Output-scan tests: `sbx up --net none` with an rw mount, changes on that
# mount like the ones an agent can make, then `sbx down`. A stand-in for
# podman (no container ever exists) keeps Podman, images and network out of
# it, so this runs in CI too. Needs bash, GNU coreutils/findutils, util-linux
# (findmnt, flock), jq and Podman's default seccomp profile, which `sbx up`
# derives its own from. TMPDIR must be a local filesystem outside hidden
# entries of $HOME. Usage: tests/scan.sh
set -uo pipefail

# sbx refuses to run as root, so every check would fail for the wrong reason.
if [ "$(id -u)" -eq 0 ]; then echo "skipped: run as a regular user"; exit 0; fi
if [ ! -r /usr/share/containers/seccomp.json ]; then
    echo "skipped: /usr/share/containers/seccomp.json (containers-common) is missing"; exit 0
fi

SBX=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/bin/sbx
# sbx prints canonical paths, so the expected ones must be canonical too.
T=$(cd -P -- "$(mktemp -d "${TMPDIR:-/tmp}/sbx-scan.XXXXXX")" && pwd)
trap 'chmod -R u+rwX -- "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
R=$T/root
mkdir -p "$R" "$T/config" "$T/bin"
export SBX_MOUNT_ROOTS=$R SBX_CONFIG_DIR=$T/config SBX_DATA_DIR=$T/data
unset SBX_IMAGE

# The podman stand-in: images exist, containers and secrets never do, and
# every other call succeeds without output.
cat > "$T/bin/podman" <<'EOF'
#!/bin/bash
case "$1 ${2:-}" in
    "container exists"|"secret exists") exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/bin/podman"
export PATH=$T/bin:$PATH

pass=0 fail=0
out=""

# run CMD...: run sbx, keep its output in $out, stop the test if it fails.
run() {
    if ! out=$("$SBX" "$@" 2>&1); then
        printf 'FAIL  sbx %s\n%s\n' "$*" "$out"
        exit 1
    fi
}

# mentions TEXT: the last sbx output contains TEXT anywhere.
mentions() {
    if [[ $out == *"$1"* ]]; then
        printf 'ok    mentions %s\n' "$1"; pass=$((pass + 1))
    else
        printf 'FAIL  mentions %s\n%s\n' "$1" "$out" | sed 's/^/      /;1s/^      //'; fail=$((fail + 1))
    fi
}

# absent PATH: PATH no longer exists.
absent() {
    if [ ! -e "$1" ]; then
        printf 'ok    absent %s\n' "$1"; pass=$((pass + 1))
    else
        printf 'FAIL  absent %s\n' "$1"; fail=$((fail + 1))
    fi
}

# try CMD...: run sbx, keep its output in $out, followed by "(accepted)" if
# it succeeded.
try() {
    if out=$("$SBX" "$@" 2>&1); then out+=$'\n(accepted)'; fi
}

# has yes|no LINE: the last sbx output has LINE as a whole line, or does not.
has() {
    local want=$1 line=$2 got=no
    if [[ $'\n'$out$'\n' == *$'\n'"$line"$'\n'* ]]; then got=yes; fi
    if [ "$got" = "$want" ]; then
        printf 'ok    %s %s\n' "$want" "$line"
        pass=$((pass + 1))
    else
        printf 'FAIL  %s %s\n%s\n' "$want" "$line" "$out" | sed 's/^/      /;1s/^      //'
        fail=$((fail + 1))
    fi
}

NEW="  rw mount: RISKY new since sbx up (created, moved or renamed):"
P=$R/proj
# shellcheck disable=SC2016  # a literal $( ) in a file name
ODD=$P/'odd ]*$(x) name'
mkdir -p "$P/.git" "$P/sub/.claude" "$P/nest/.claude" "$ODD/.claude" \
    "$P/examples/claude" "$P/docs" "$P/stash"
echo 'ref: refs/heads/main' > "$P/.git/HEAD"
touch "$P/CLAUDE.md" "$P/notes.md" "$P/sub/.claude/settings.json" \
    "$P/examples/claude/settings.json" "$P/docs/settings.json" "$P/stash/HEAD.txt"

# Existing risky entries stay read-only in the sandbox (they cannot be
# renamed or written), so the agent can only add new ones: by creating them,
# by renaming or moving what it may write, which leaves the ctimes of the
# files inside a directory as they were, or by renaming a parent directory.
run up --net none --mount "$P:rw"
touch "$P/.envrc"
mv "$P/examples/claude" "$P/.claude"
mv "$P/docs" "$P/sub/.vscode"
mv "$P/notes.md" "$P/AGENTS.md"
mv "$P/stash/HEAD.txt" "$P/stash/HEAD"
mv "$P/nest" "$P/nest2"
run down
has yes "$NEW $P/.envrc"
has yes "$NEW $P/.claude"
has yes "$NEW $P/sub/.vscode"
has yes "$NEW $P/AGENTS.md"
has yes "$NEW $P/stash"
has yes "$NEW $P/nest2/.claude"
has no "$NEW $P/.git"
has no "$NEW $P/CLAUDE.md"
has no "$NEW $P/sub/.claude"
has no "$NEW $ODD/.claude"

# Without the record from sbx up, every risky entry is listed.
run up --net none --mount "$P:rw"
rm -f -- "$SBX_DATA_DIR/state/up-risky"
run down
has yes "  rw mount: no record from sbx up of what stayed read-only in $P; every risky entry is listed"
has yes "$NEW $P/.git"

# vm mode: every microVM run resolves its mounts again by path, so no mount
# may lie inside an rw mount, and read-only overlays only at its top level.
# `sbx up --vm` needs libkrun and /dev/kvm before it gets that far.
if [ -x /usr/bin/krun ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    V=$R/vm
    mkdir -p "$V/top/.git" "$V/top/lib/.git" "$V/flat/.git" "$V/flat/a/b"
    touch "$V/flat/CLAUDE.md"
    try up --net none --vm --mount "$V/top:rw"
    has yes "sbx: refusing --vm: $V/top/lib/.git is below the top level of an rw mount, where a microVM run cannot keep it read-only; mount $V/top/lib rw instead, mount read-only, or drop --vm"
    has no "(accepted)"
    try up --net none --vm --mount "$V/flat:rw" --mount "$V/flat/a/b:ro"
    has yes "sbx: refusing --vm: $V/flat/a/b is inside the rw mount $V/flat, where a microVM run could redirect it for the next; mount only one of them, or drop --vm"
    has no "(accepted)"
    run up --net none --vm --mount "$V/flat:rw"
    touch "$V/flat/.envrc"
    run down
    has yes "$NEW $V/flat/.envrc"
    has no "$NEW $V/flat/.git"
else
    echo "skipped vm mode checks: no libkrun or /dev/kvm"
fi

# A btrfs subvolume (or a snapshot) the agent makes is another filesystem,
# which the scan does not look into: flagged on an rw mount, quarantined in
# lab/out, and sbx up refuses to start while one is left there. Only where
# TMPDIR is on btrfs.
if [ "$(stat -f -c %T -- "$T")" = btrfs ] && command -v btrfs >/dev/null; then
    B=$R/sv
    mkdir -p "$B"
    run up --net none --mount "$B:rw"
    btrfs -q subvolume create "$R/src"
    mkdir -p "$R/src/repo/.git/hooks"
    btrfs -q subvolume create "$B/inner"
    btrfs -q subvolume create "$SBX_DATA_DIR/lab/out/inner"
    mkdir -p "$SBX_DATA_DIR/lab/out/inner/repo/.git"
    btrfs -q subvolume snapshot -r "$R/src" "$SBX_DATA_DIR/lab/out/rosnap"
    run down
    has yes "  rw mount: RISKY another filesystem (btrfs subvolume?), not checked inside: $B/inner"
    mentions "(another filesystem, btrfs subvolume?): inner"
    absent "$SBX_DATA_DIR/lab/out/inner"
    mentions "(another filesystem, btrfs subvolume?): rosnap"
    absent "$SBX_DATA_DIR/lab/out/rosnap"
    btrfs -q subvolume create "$SBX_DATA_DIR/lab/out/stray"
    try up --net none
    mentions "lab/out/stray is another filesystem (a btrfs subvolume?) in lab/out"
    has no "(accepted)"
    rmdir "$SBX_DATA_DIR/lab/out/stray"
else
    echo "skipped btrfs subvolume checks: TMPDIR is not on btrfs"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
