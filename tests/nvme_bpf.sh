#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: BPF arena SQ submission + MMIO doorbell against ublk.nvme_vfio (fio verify)
# vmtest-requires: root ublksrv hugetlb fio nvme-pci vfio
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_require_module ublk_drv vfio_pci
vt_require_ublksrv
vt_require_cmd fio
vt_install_trap

UBLK_BPF="$UBLKSRV_DIR/.libs/ublk.nvme_vfio"
[ -x "$UBLK_BPF" ] || vt_skip "ublk.nvme_vfio not built"

PCI=$(vt_find_nvme_pci) || true
[ -n "$PCI" ] || vt_skip "no NVMe PCI device in this VM"
vt_log "found NVMe at $PCI"

vt_setup_hugetlb 2248
HTLB_BUF="$VT_HUGETLB_MNT/ublk_shmem_buf"
vt_atexit "'$VT_UBLK' del -a 2>/dev/null || true"
vt_atexit "rm -f '$HTLB_BUF'"
fallocate -l 4G "$HTLB_BUF"

DLOG=$(mktemp /tmp/nvme_bpf_daemon.XXXXXX)
vt_atexit "rm -f '$DLOG'"

# BPF fast path serves UBLK_IO_F_SHMEM_ZC I/O: back fio with the same
# hugetlb buffer the daemon registers (--shmem_zc --htlb + --mem=mmaphuge).
run_dev() {
	"$UBLK_BPF" add --pci "$PCI" -q 2 -d 128 --bpf --shmem_zc \
		--htlb "$HTLB_BUF" >"$DLOG" 2>&1 &
	KPID=$!
	sleep 3
	vt_wait_for_block /dev/ublkb0 5 || {
		tail -30 "$DLOG"
		dmesg | tail -30 | grep -iE "ublk|bpf|vfio|arena" || true
		vt_die "/dev/ublkb0 not created"
	}
}

stop_dev() {
	"$VT_UBLK" del -n 0 2>/dev/null || true
	wait $KPID 2>/dev/null || true
}

vt_log "test 1: BPF submission randrw (4k, fast path)"
run_dev
vt_log "probe: single 4k direct write+read"
timeout 20 dd if=/dev/zero of=/dev/ublkb0 bs=4k count=1 oflag=direct || vt_die "single-write probe hung/failed"
timeout 20 dd if=/dev/ublkb0 of=/dev/null bs=4k count=1 iflag=direct || vt_die "single-read probe hung/failed"
vt_log "probe OK"
fio --name=test --filename=/dev/ublkb0 --ioengine=libaio --direct=1 \
    --bs=4k --iodepth=32 --numjobs=1 \
    --rw=randrw --runtime=10 --time_based \
    --mem=mmaphuge:"$HTLB_BUF" --group_reporting
stop_dev
vt_pass "bpf randrw"

vt_log "test 2: BPF submission write + crc32c verify"
run_dev
fio --name=write --filename=/dev/ublkb0 --ioengine=libaio --direct=1 \
    --bs=4k --iodepth=32 --numjobs=1 --rw=write --size=64M \
    --mem=mmaphuge:"$HTLB_BUF" --do_verify=0 --verify=crc32c
fio --name=verify --filename=/dev/ublkb0 --ioengine=libaio --direct=1 \
    --bs=4k --iodepth=32 --numjobs=1 --rw=read --size=64M \
    --mem=mmaphuge:"$HTLB_BUF" --verify=crc32c --verify_only
stop_dev
vt_pass "bpf write+verify"

# The daemon prints BPF stats at teardown; prove the fast path engaged.
vt_log "daemon BPF stats:"
grep -iE "bpf" "$DLOG" | tail -5 || true
SUBMITTED=$(grep -oE "submitted=[0-9]+" "$DLOG" | grep -oE "[0-9]+" | tail -1)
if [ "${SUBMITTED:-0}" -le 0 ]; then
	vt_die "BPF fast path never engaged (nr_bpf_submitted=${SUBMITTED:-0})"
fi
vt_pass "bpf fast path submitted $SUBMITTED I/Os"
