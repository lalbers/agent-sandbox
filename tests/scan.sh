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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
