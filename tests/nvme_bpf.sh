#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: BPF-arena SQ submission against ublk.nvme_vfio
# vmtest-requires: root ublksrv nvme-pci vfio fio-src
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_require_module ublk_drv vfio_pci
vt_require_ublksrv
vt_install_trap

UBLK_BPF="$UBLKSRV_DIR/.libs/ublk.nvme_vfio"
[ -x "$UBLK_BPF" ] || vt_skip "ublk.nvme_vfio not built"

PCI=$(vt_find_nvme_pci) || true
[ -n "$PCI" ] || vt_skip "no NVMe PCI device in this VM"
vt_log "found NVMe at $PCI"

vt_log "creating ublk BPF arena SQ device"
"$UBLK_BPF" add --pci "$PCI" -q 8 -d 128 "$@" &
KPID=$!
vt_atexit "kill $KPID 2>/dev/null || true; '$VT_UBLK' del -a 2>/dev/null || true"
sleep 3

vt_wait_for_block /dev/ublkb0 5 \
	|| { dmesg | tail -50 | grep -iE "ublk|bpf|vfio|arena|error|fail" || true; vt_die "/dev/ublkb0 not created"; }

vt_log "running dd"
dd of=/dev/ublkb0 if=/dev/zero bs=2M count=100 oflag=direct
RET=$?

if [ -n "${FIO_DIR:-}" ] && [ -x "$FIO_DIR/t/io_uring" ]; then
	"$FIO_DIR/t/io_uring" -p0 -r 10 /dev/ublkb0 || RET=$?
fi

"$VT_UBLK" del -n 0 2>/dev/null || true
wait $KPID 2>/dev/null || true
exit "$RET"
