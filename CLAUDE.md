# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A standalone harness for running Linux kernel block-layer / ublk / io_uring
tests under [virtme-ng](https://github.com/arighi/virtme-ng). It is *not* a
kernel source tree; it sits next to one and boots it. See `README.md` for
user-facing docs.

## Layout (load-bearing)

```
vmtest               CLI: list / run / run-host / config (bash)
run_vm               Low-level: invokes `vng` with our QEMU + kcmdline
lib/common.sh        All helpers — sourced by every test
tests/*.sh           One file per test, fronted by `# vmtest-desc:` /
                     `# vmtest-requires:` metadata comments
vmtest.conf.example  Sample config; users copy to vmtest.conf (gitignored)
data/                Runtime scratch (disk images, hugetlb buffers). Gitignored.
```

When adding code, prefer growing `lib/common.sh` over copy-pasting into a
new test. The `vmtest list` CLI parses the metadata comments at the top
of each `tests/*.sh` — preserve the exact prefix (`# vmtest-desc:` /
`# vmtest-requires:`).

## Execution model

1. The user runs `./vmtest run NAME [args]` on the host.
2. `vmtest` resolves config (`vmtest.conf` + env), then execs `run_vm` with
   the absolute path to `tests/NAME.sh` plus any extra args.
3. `run_vm` checks `$KERNEL_DIR/vmlinux`, ensures `data/d1.img` and
   `data/d2.img` exist (creating them with `truncate` if not), then boots
   `vng` with:
   - `--rwdir $VMTEST_DATA_DIR` — host dir visible read-write in guest.
   - `intel-iommu` enabled in QEMU and on the kernel cmdline.
   - Extra SCSI + NVMe devices behind the IOMMU.
   - `--exec "env VAR=val... tests/NAME.sh args..."` — env forwarding,
     because `vng` does **not** preserve the host environment otherwise.
4. Inside the VM, the test sources `lib/common.sh`, calls `vt_load_config`
   to repopulate `$KERNEL_DIR` / `$UBLKSRV_DIR` / etc., declares its
   requirements via `vt_require_*`, installs the cleanup trap, and runs.

## Config resolution

`vt_load_config` (in `lib/common.sh`) sources `${VMTEST_CONF:-./vmtest.conf}`
if present, then fills defaults. **The environment always wins** because
the `: "${VAR:=default}"` syntax only sets when unset. This means
`KERNEL_DIR=… ./vmtest run …` is the canonical per-invocation override and
should be treated as a supported public interface — don't break it.

## Conventions for new tests

- Source `lib/common.sh` with `. "$(dirname "$0")/../lib/common.sh"`. Relative
  paths inside tests are fragile because `vng` invokes them with an arbitrary
  cwd; the `dirname "$0"` form is what works.
- One `vt_install_trap` per test, with cleanup commands pushed via
  `vt_atexit "cmd"`. Cleanups run LIFO. Do not register your own EXIT trap
  — it will clobber the cleanup stack.
- Missing optional deps → `vt_skip` (exit 4); real failures → `vt_die` (exit
  1) or non-zero exit. Don't conflate the two — `vmtest list` shows
  requirements precisely so testers know what to install.
- Out-of-tree binaries (`ublksrv`, `fio/t/io_uring`) belong behind
  `vt_require_ublksrv` / `vt_require_fio`. Don't hard-code paths under
  `/home/ming/...` — those are gone for a reason.
- `set -eu` at the top; `set -x` only when actively debugging.

## Things that look like bugs but aren't

- `KERNEL_DIR` defaults to `<repo>/..` not `<repo>/../..` — the convention
  is that the repo sits inside the kernel tree as `vmtest/`, not two levels
  deep. (Earlier `run_vm` versions took the kernel path as a positional arg,
  which is why that pattern was easy to get wrong.)
- The two extra disk images are lazily created by `run_vm` on first boot,
  so a freshly-cloned repo will show `data/d{1,2}.img` appearing after the
  first `./vmtest run`.

## Verification

`./vmtest run loop_autoclear` is the dependency-free smoke test — it
only needs a built kernel and `vng`. Use it to validate harness changes
before touching the heavier ublksrv/VFIO paths.
