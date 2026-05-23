#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: fio t/io_uring with hugetlb-backed buffer
# vmtest-requires: root fio-src hugetlb
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root
vt_require_fio
vt_install_trap

[ -n "${VT_T_IO_URING:-}" ] || vt_skip "FIO_DIR not set or fio/t/io_uring not built"

vt_setup_hugetlb 10
HTLB_BUF="$VT_HUGETLB_MNT/io_uring_buf"
BACKING="$VMTEST_TMPDIR/io_uring_test.img"

vt_atexit "rm -f '$HTLB_BUF' '$BACKING'"

fallocate -l 4M "$HTLB_BUF" || vt_die "fallocate hugetlb buffer failed"
truncate -s 256M "$BACKING"

vt_log "test 1: t/io_uring randrw with hugetlb buffer"
"$VT_T_IO_URING" -d 32 -b 4096 -p0 -r 5 -n 4 -H "$HTLB_BUF" "$BACKING"

vt_log "test 2: t/io_uring randrw plain"
"$VT_T_IO_URING" -d 32 -b 4096 -p0 -r 5 -n 4 "$BACKING"

vt_pass "t/io_uring hugetlb tests"
