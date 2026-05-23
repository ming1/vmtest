#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: cargo test the rublk crate (Rust ublk targets)
# vmtest-requires: root rublk
# vmtest-host: yes
# Note: runs `cargo test` so it can be used either inside the VM
#       (./vmtest run rublk) or on the host (./vmtest run-host rublk).
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_cmd cargo

[ -d "$RUBLK_DIR" ] || vt_skip "RUBLK_DIR not set or missing: $RUBLK_DIR"
cd "$RUBLK_DIR"
exec cargo test
