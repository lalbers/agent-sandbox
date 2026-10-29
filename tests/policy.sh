#!/bin/bash
# Mount-policy tests: run `sbx check` against a scratch mount root. No Podman,
# no images and no network needed, so this runs anywhere bash and GNU
# coreutils/findutils do (CI included). Usage: tests/policy.sh
set -uo pipefail

SBX=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/bin/sbx
T=$(mktemp -d "${TMPDIR:-/tmp}/sbx-policy.XXXXXX")
trap 'chmod -R u+rwX -- "$T" 2>/dev/null; rm -rf -- "$T"' EXIT
R=$T/root
mkdir -p "$R" "$T/outside" "$T/config"
# The data directory sits inside the mount root here, so that the test can
# check that it is protected.
export SBX_MOUNT_ROOTS=$R SBX_CONFIG_DIR=$T/config SBX_DATA_DIR=$R/sbx-data
unset SBX_IMAGE
mkdir -p "$SBX_DATA_DIR/lab/out"

pass=0 fail=0

# expect ok|refused SPEC [TEXT]: `sbx check SPEC` must give that verdict and,
# if TEXT is given, mention it.
expect() {
    local want=$1 spec=$2 text=${3:-} out verdict
    out=$("$SBX" check "$spec" 2>&1)
    case $want in
        ok)      verdict="OK       $spec" ;;
        refused) verdict="REFUSED  $spec" ;;
    esac
    if [[ $out != *"$verdict"* ]] || { [ -n "$text" ] && [[ $out != *"$text"* ]]; }; then
        printf 'FAIL  %s %q%s\n%s\n' "$want" "$spec" "${text:+ (expected: $text)}" "$out" | sed 's/^/      /;1s/^      //'
        fail=$((fail + 1))
    else
        printf 'ok    %s %q\n' "$want" "$spec"
        pass=$((pass + 1))
    fi
}

# Plain directories, inside and outside the mount root.
mkdir -p "$R/plain"
expect ok "$R/plain:ro"
expect ok "$R/plain:rw"
expect refused "$T/outside:ro" "only paths below"

# A symlink is resolved before the check.
ln -s "$T/outside" "$R/link"
expect refused "$R/link:ro" "only paths below"

# Characters podman's -v syntax cannot carry.
mkdir -p "$R/a:b"
expect refused "$R/a:b:ro" "not supported"

# A trailing newline must not be dropped: "nl<LF>" is a directory below the
# root, "nl" a symlink to somewhere else that podman would end up mounting.
mkdir -p "$R/nl"$'\n'
ln -s "$T/outside" "$R/nl"
expect refused "$R/nl"$'\n'":ro" "not supported"

# Git metadata in a worktree: never rw itself, overlaid read-only otherwise.
mkdir -p "$R/repo/.git/hooks"
echo 'ref: refs/heads/main' > "$R/repo/.git/HEAD"
expect refused "$R/repo/.git/hooks:rw" "git metadata"
expect ok "$R/repo:rw" "mount ro $R/repo/.git (stays read-only)"

# A bare repository has no .git component: nothing below it may be rw, since
# its hooks and config run when git is used there. Read-only is fine.
mkdir -p "$R/proj.git/hooks" "$R/proj.git/objects" "$R/proj.git/refs"
echo 'ref: refs/heads/main' > "$R/proj.git/HEAD"
touch "$R/proj.git/config"
expect refused "$R/proj.git:rw" "git metadata"
expect refused "$R/proj.git/hooks:rw" "git metadata"
expect refused "$R/proj.git/config:rw" "git metadata"
expect ok "$R/proj.git/hooks:ro"

# Other agents' instruction files and other VCS directories are risky too:
# overlaid read-only inside an rw mount, never rw themselves.
mkdir -p "$R/agents/.gemini" "$R/agents/.hg"
touch "$R/agents/AGENTS.md" "$R/agents/.gitmodules"
expect ok "$R/agents:rw" "mount ro $R/agents/AGENTS.md (stays read-only)"
expect ok "$R/agents:rw" "mount ro $R/agents/.hg (stays read-only)"
expect ok "$R/agents:rw" "mount ro $R/agents/.gitmodules (stays read-only)"
expect refused "$R/agents/.gemini:rw" "tool configuration"

# Relabelling a hard-linked file would relabel its other links too.
mkdir -p "$R/hardlink"
echo x > "$R/hardlink/a"
ln "$R/hardlink/a" "$R/hardlink/b"
expect refused "$R/hardlink:ro" "hard-linked"

# Runtime data (agent home, lab/out, transcripts) is never shared again.
expect refused "$SBX_DATA_DIR:ro" "protected path"
expect refused "$SBX_DATA_DIR/lab/out:rw" "protected path"

# Fail closed: a directory the scan cannot read could hide a hard link or a
# .git, so the whole mount is refused (ro and rw), never silently accepted.
if [ "$(id -u)" -ne 0 ]; then
    mkdir -p "$R/locked/inner/.git"
    chmod 000 "$R/locked/inner"
    expect refused "$R/locked:ro" "cannot read"
    expect refused "$R/locked:rw" "cannot read"
    chmod 700 "$R/locked/inner"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
