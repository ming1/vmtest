#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: Run a group of ublk kernel selftests (make <group>)
# vmtest-requires: root kernel-selftests
# Usage: ./vmtest run ublk_test_grp <group-name>
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_root

GRP="${1:-}"
[ -n "$GRP" ] || vt_die "usage: vmtest run ublk_test_grp <group>"

vt_log "ublk selftest group: $GRP"
make -C "$KERNEL_DIR/tools/testing/selftests/ublk" JOBS=2 "$GRP"
ret=$?

dmesg | tail -n 80
exit "$ret"
