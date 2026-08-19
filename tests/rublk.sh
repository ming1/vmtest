#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# vmtest-desc: cargo test the rublk crate (Rust ublk targets)
# vmtest-requires: root rublk
# vmtest-host: yes
# Note: runs `cargo test` so it can be used either inside the VM
#       (./vmtest run rublk) or on the host (./vmtest run-host rublk).
#       Inside the VM the test runs as root while the rust toolchain
#       lives under the invoking user's home, so point rustup/cargo
#       there explicitly (same as libublk.sh).
set -eu

. "$(dirname "$0")/../lib/common.sh"
vt_load_config
vt_require_cmd cargo

[ -d "$RUBLK_DIR" ] || vt_skip "RUBLK_DIR not set or missing: $RUBLK_DIR"

cargo_bin=$(command -v cargo)
case "$cargo_bin" in
/home/*/.cargo/bin/cargo)
	user_home=${cargo_bin%/.cargo/bin/cargo}
	export CARGO_HOME="$user_home/.cargo" RUSTUP_HOME="$user_home/.rustup"
	;;
esac

cd "$RUBLK_DIR"
exec cargo test "$@"
