# pdx203 SukiSU-Nova kernel (4.19, non-GKI)

English | [中文](README.md)

Port of **SukiSU Nova v3.0.0** onto the Sony Xperia 1 II (**pdx203 / XQ-AT52**) vendor 4.19 kernel,
with root and the full module framework working under **SELinux Enforcing**.

> This repository contains build scripts, kernel config, repack tools and docs only.
> No ROM binaries, boot images, vendor blobs or credentials.

## Baseline

| Item | Value |
|---|---|
| Device | pdx203 (Xperia 1 II), A/B, current slot `_a` |
| Kernel | `4.19.325-perf-gd3216e6faee6`, **non-GKI** |
| Kernel source | `AlcatrazDev-Android-Devices/kernel_sony_sm8250` (vendor tree, ships old KernelSU 0.9.5) |
| Toolchain | AOSP clang **r563880c / 21.0.0** + LLD 21 (same as stock) |
| Root | **SukiSU Nova v3.0.0**, manager `com.sukisu.nova` v3.0.0 |
| Hardening | Stock config kept: **LTO + CFI on** |
| Version string | `uname -r` identical to stock; image carries only `build-user@build-host` |

## Verified

```
su -c id            → uid=0(root) context=u:r:ksu:s0
ksud --version      → 3.0.0 (uapi: 6)
modules             → all 4 loaded (uperf, Zygisk Next, LSPosed, audio tweak)
Zygisk Next 1.5.3   → ✅zygote, ✅zygote_secondary, 1 service injected
LSPosed v2.2.1      → lspd + companion running
audio module        → post-fs-data runs, HAL outputs AUDIO_FORMAT_PCM_24_BIT_PACKED
```

## Integration (no setup.sh in Nova)

```
kernel/  → drivers/kernelsu
uapi/    → drivers/kernelsu/uapi          # sources do #include "uapi/xxx.h"
drivers/Makefile: obj-$(CONFIG_KSU) += kernelsu/
drivers/Kconfig : source "drivers/kernelsu/Kconfig"
```

Skipping the `uapi/` copy fails immediately with `fatal error: 'uapi/supercall.h' file not found` —
it must live in `drivers/kernelsu/uapi/` (quoted include is a relative path), not `include/uapi/`.

## 4.19 compatibility fixes

Nova's baseline is 5.x; on 4.19 there are 13 error groups, all handled by `compat419.sh`:

fops members (`iopoll`, `remap_file_range`, `REMAP_FILE_DEDUP`) · mount API (`uapi/linux/mount.h`,
`path_mount()` via `ksys_mount` + `KERNEL_DS`) · `TWA_RESUME` and `put_task_struct` includes ·
seccomp (`SECCOMP_ARCH_NATIVE_NR`, `filter_count`) · fsnotify `handle_inode_event` ·
clocksource `vdso_clock_mode` · `MODULE_IMPORT_NS` · `<linux/minmax.h>` · `tasklist_lock`/`init_task`/
`task_pgrp`/`task_session` · aarch64 text poke without `pmd_leaf()` (uses `__pa()`) ·
SELinux `policydb` fields that only exist in 5.5+.

The SELinux landing strategy is inherited from the Ultra port: the ROM has no `u:r:su:s0` /
`u:object_r:ksu_file:s0`, so the kernel injects policy from user space via
`magiskpolicy --live --apply` at boot, then re-adopts the `ksu` domain and re-enables enforcing.
Details: [`docs/ultra-v4.3.0-r2.md`](docs/ultra-v4.3.0-r2.md) (Chinese).

## Build

```bash
bash wsl_build_nova.sh
```

Requires WSL2 (build on ext4, never on `/mnt/c`), `/opt/clang-r563880c`, kernel tree at
`~/src/vendor/src`. The script must `export PATH=/opt/clang-$CLANG_VER/bin:$PATH` — setting only
`CLANG_VER=...` silently falls back to the system clang (Ubuntu clang 14); the result boots but the
toolchain no longer matches stock. `Ubuntu clang` in `/proc/version` is the tell.

Two-stage build: `KSU_CHECK_ONLY=1` compiles `drivers/kernelsu/` only (~1 min), then a full LTO link
(~15 min).

## Flash / rollback

```bash
fastboot flash boot_a pdx203_nova_v3.0.0_boot.img
fastboot flash boot_b pdx203_nova_v3.0.0_boot.img
fastboot reboot
```

Install **SukiSU Nova v3.0.0** (`com.sukisu.nova`) afterwards. Kernel and manager versions must match;
it is a separate package from the old `com.sukisu.ultra` and both can coexist.

Rollback: flash your stock `boot.img` back to `boot_a` / `boot_b`.

## History

- SukiSU-Ultra `v4.3.0-r2`: [docs/ultra-v4.3.0-r2.md](docs/ultra-v4.3.0-r2.md)

## Credits

| Project | Contribution |
|---|---|
| [SukiSU-Nova](https://github.com/SukiSU-Nova/SukiSU-Nova) | the root solution itself |
| [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) | previous generation; base of the compat patches |
| [magiskpolicy](https://github.com/topjohnwu/Magisk) | only working policy reload path on 4.19 |
| kernel_sony_sm8250 | vendor kernel source |

`magiskpolicy-arm64` comes from Magisk; binary and license notes are in `NOTICE.txt` on the release page.
