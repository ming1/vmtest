#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: Stress losetup -d against in-flight writeback; check for GPF in lo_rw_aio
# vmtest-requires: root
#
# Regression test for the GPF fixed by sync_blockdev() in __loop_clr_fd().
# Usage: ./vmtest run loop_autoclear [iterations]
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_install_trap

ITERS="${1:-20}"
BACKING="$VMTEST_TMPDIR/loop_autoclear.img"

vt_atexit "rm -f '$BACKING'"
vt_atexit "for d in /dev/loop[0-9]*; do losetup -d \"\$d\" 2>/dev/null || true; done"

vt_dmesg_clear
truncate -s 256M "$BACKING"

vt_log "loop autoclear stress: $ITERS iterations"
for i in $(seq 1 "$ITERS"); do
	loop=$(losetup --show -f "$BACKING" 2>/dev/null) || continue
	dd if=/dev/zero of="$loop" bs=4k count=2000 conv=notrunc 2>/dev/null &
	dd_pid=$!
	sleep 0.05
	losetup -d "$loop" 2>/dev/null || true
	wait $dd_pid 2>/dev/null || true
done

if vt_dmesg_has "general protection fault" "BUG:" "Oops:" "RIP:.*lo_rw_aio"; then
	vt_log "kernel Oops detected:"
	dmesg | tail -30 >&2
	exit 1
fi

vt_pass "no kernel Oops detected"
