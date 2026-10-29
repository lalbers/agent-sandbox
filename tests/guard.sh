#!/bin/bash
# sbx-guard tests: run small probes under the seccomp filter and compare the
# kernel's answers. Each probe also runs without the filter first, so that a
# test cannot pass only because the host refuses the call anyway. Needs Linux
# on x86_64 (the filter is x86_64-only); no podman. Usage: tests/guard.sh
set -uo pipefail

GUARD=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/container/sbx-guard
if [ "$(uname -m)" != x86_64 ]; then echo "skipped: sbx-guard filters x86_64 only"; exit 0; fi

pass=0 fail=0

# Python run under the guard: prints "ok" or the errno name of the call.
PRELUDE='
import ctypes, errno, os
libc = ctypes.CDLL(None, use_errno=True)
def sc(nr, *args):
    r = libc.syscall(nr, *args)
    print("ok" if r >= 0 else errno.errorcode[ctypes.get_errno()])
'

# probe NAME EXPECTED CODE: CODE must print EXPECTED under the guard, and
# something else without it. Where the host already refuses the call (Ubuntu's
# AppArmor policy blocks unprivileged user namespaces, for example) or kills
# the probe outright (an outer seccomp filter), it proves nothing and is
# skipped.
probe() {
    local name=$1 want=$2 code=$3 plain got
    plain=$(python3 -I -c "$PRELUDE$code" 2>&1)
    got=$("$GUARD" python3 -I -c "$PRELUDE$code" 2>&1)
    if [ "$plain" = "$want" ] || [ -z "$plain" ]; then
        printf 'skip  %-34s the host gives %s without the guard too\n' "$name" "${plain:-nothing}"
    elif [ "$got" = "$want" ]; then
        printf 'ok    %-34s %s (without the guard: %s)\n' "$name" "$got" "$plain"
        pass=$((pass + 1))
    else
        printf 'FAIL  %-34s got %s, want %s (without the guard: %s)\n' "$name" "$got" "$want" "$plain"
        fail=$((fail + 1))
    fi
}

CLONE_NEWUSER=0x10000000 CLONE_NEWNET=0x40000000

probe "no_new_privs and seccomp are set" "1 2" '
f = dict(l.split(":", 1) for l in open("/proc/self/status"))
print(f["NoNewPrivs"].strip(), f["Seccomp"].strip())'
probe "unshare(CLONE_NEWUSER) refused" EPERM "sc(272, $CLONE_NEWUSER)"
probe "unshare(NEWUSER|NEWNET) refused" EPERM "sc(272, $CLONE_NEWUSER | $CLONE_NEWNET)"
probe "clone(CLONE_NEWUSER) refused" EPERM "
r = libc.syscall(56, $CLONE_NEWUSER | 17, 0, 0, 0, 0)
if r == 0: os._exit(0)
if r > 0: os.waitpid(r, 0)
print('ok' if r > 0 else errno.errorcode[ctypes.get_errno()])"
probe "clone3 answers ENOSYS" ENOSYS "sc(435, 0, 0)"
probe "setns refused" EPERM "sc(308, -1, 0)"
probe "keyctl refused" EPERM "sc(250, 0, -1, 0)"
probe "io_uring_setup answers ENOSYS" ENOSYS "sc(425, 1, 0)"
probe "x32 ABI refused" EPERM "sc(0x40000000 | 39)"

# Ordinary work still runs under the guard: fork, exec, and threads, which
# try clone3 first and must fall back to clone on ENOSYS.
if "$GUARD" python3 -I -c '
import os, sys
pid = os.fork()
if pid == 0:
    os._exit(7)
sys.exit(0 if os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]) == 7 else 1)' \
    && "$GUARD" true \
    && "$GUARD" python3 -I -c 'import threading; t = threading.Thread(target=lambda: None); t.start(); t.join()'; then
    echo "ok    fork, exec and threads work under the guard"; pass=$((pass + 1))
else
    echo "FAIL  fork, exec or threads fail under the guard"; fail=$((fail + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && [ "$pass" -gt 1 ]
