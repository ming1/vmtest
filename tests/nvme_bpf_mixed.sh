#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: Mixed SHMEM_ZC / non-ZC workload against ublk.nvme_vfio --bpf (lost-doorbell regression)
# vmtest-requires: root ublksrv hugetlb fio nvme-pci vfio
#
# Regression test for the lost-doorbell window in BPF arena SQ submission:
# the program defers the SQ doorbell to bd->last / commit_io_cmd, so a
# dispatch batch that ends with a request the program does not ring for
# (its own fallback path, or a non-SHMEM_ZC request it never sees) used to
# leave published SQEs unrung and the I/O hung.
#
#  - phase 1 mixes BPF-path (4k/8k) and fallback-path (16k, >2 PRP pages)
#    SHMEM_ZC I/O inside single io_submit plugs (prog-side `last` fix)
#  - phase 2 runs SHMEM_ZC and non-SHMEM_ZC jobs concurrently, so batches
#    can end with a request that bypasses the program (daemon doorbell
#    backstop)
#  - phase 3 repeats the mix with crc32c write+verify on disjoint ranges
#
# All fio runs are wrapped in `timeout` so the failure mode of the race (a
# stranded, never-rung SQE) shows up as a test failure, not a hang.
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

DLOG=$(mktemp /tmp/nvme_bpf_mixed_daemon.XXXXXX)
vt_atexit "rm -f '$DLOG'"

run_dev() {
	"$UBLK_BPF" add --pci "$PCI" -q 2 -d 128 --bpf --shmem_zc \
		--htlb "$HTLB_BUF" >>"$DLOG" 2>&1 &
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

# Only one job may use mem=mmaphuge:$HTLB_BUF at a time: every mapping of
# the file shares the same pages (which is also what makes it SHMEM_ZC).

vt_log "phase 1: SHMEM_ZC bssplit 4k/8k/16k randrw (in-batch prog fallback)"
run_dev
timeout 90 fio --name=zcsplit --filename=/dev/ublkb0 --ioengine=libaio \
	--direct=1 --bssplit=4k/40:8k/30:16k/30 --iodepth=32 --numjobs=1 \
	--rw=randrw --runtime=15 --time_based \
	--mem=mmaphuge:"$HTLB_BUF" --group_reporting \
	|| vt_die "phase 1 fio failed or hung"
stop_dev
vt_pass "zc bssplit randrw"

vt_log "phase 2: concurrent SHMEM_ZC + non-ZC 4k randrw"
run_dev
timeout 120 fio --filename=/dev/ublkb0 --ioengine=libaio --direct=1 \
	--iodepth=32 --bs=4k --rw=randrw --runtime=20 --time_based \
	--group_reporting \
	--name=zc --mem=mmaphuge:"$HTLB_BUF" \
	--name=nonzc --mem=malloc \
	|| vt_die "phase 2 fio failed or hung"
stop_dev
vt_pass "mixed concurrent randrw"

vt_log "phase 3a: mixed write + crc32c verify (zc 4k BPF path + non-zc 4k)"
run_dev
timeout 180 fio --filename=/dev/ublkb0 --ioengine=libaio --direct=1 \
	--iodepth=32 --rw=write --size=64M --group_reporting \
	--verify=crc32c --do_verify=0 \
	--name=zc4k --bs=4k --offset=0 --mem=mmaphuge:"$HTLB_BUF" \
	--name=nz4k --bs=4k --offset=1G --mem=malloc \
	|| vt_die "phase 3a write failed or hung"
timeout 180 fio --filename=/dev/ublkb0 --ioengine=libaio --direct=1 \
	--iodepth=32 --rw=read --size=64M --group_reporting \
	--verify=crc32c --verify_only \
	--name=zc4k --bs=4k --offset=0 --mem=mmaphuge:"$HTLB_BUF" \
	--name=nz4k --bs=4k --offset=1G --mem=malloc \
	|| vt_die "phase 3a verify failed"
stop_dev
vt_pass "mixed 4k write+verify"

vt_log "phase 3b: mixed write + crc32c verify (zc 16k fallback path + non-zc 4k)"
run_dev
timeout 180 fio --filename=/dev/ublkb0 --ioengine=libaio --direct=1 \
	--iodepth=32 --rw=write --size=64M --group_reporting \
	--verify=crc32c --do_verify=0 \
	--name=zc16k --bs=16k --offset=0 --mem=mmaphuge:"$HTLB_BUF" \
	--name=nz4k --bs=4k --offset=1G --mem=malloc \
	|| vt_die "phase 3b write failed or hung"
timeout 180 fio --filename=/dev/ublkb0 --ioengine=libaio --direct=1 \
	--iodepth=32 --rw=read --size=64M --group_reporting \
	--verify=crc32c --verify_only \
	--name=zc16k --bs=16k --offset=0 --mem=mmaphuge:"$HTLB_BUF" \
	--name=nz4k --bs=4k --offset=1G --mem=malloc \
	|| vt_die "phase 3b verify failed"
stop_dev
vt_pass "mixed 16k/4k write+verify"

# The daemon prints BPF stats at each teardown (the log accumulates across
# device instances); prove both the fast path and the fallback path ran.
# Phase 3b alone is all-fallback (bs=16k), hence the sum over all phases.
vt_log "daemon BPF stats (all device instances):"
grep -E "BPF stats" "$DLOG" || true
SUBMITTED=$(grep -oE "submitted=[0-9]+" "$DLOG" | awk -F= '{s+=$2} END{print s+0}')
FALLBACK=$(grep -oE "fallback=[0-9]+" "$DLOG" | awk -F= '{s+=$2} END{print s+0}')
[ "${SUBMITTED:-0}" -gt 0 ] || vt_die "BPF fast path never engaged (submitted=${SUBMITTED:-0})"
[ "${FALLBACK:-0}" -gt 0 ] || vt_die "BPF fallback path never engaged (fallback=${FALLBACK:-0})"

vt_pass "mixed workload: submitted=$SUBMITTED fallback=$FALLBACK"
