# pdx203 SukiSU-Ultra kernel — 4.19 non-GKI, SELinux **Enforcing** + working root

English | [中文](README.md)

SukiSU-Ultra **v4.3.0-r2** ported onto the vendor 4.19 kernel of the
**Sony Xperia 1 II (pdx203 / XQ-AT52)**, with root working while SELinux stays
**Enforcing**.

> This repository contains **build scripts, kernel configs, a repack tool and docs**.
> It does not contain ROM binaries, vendor blobs or keys beyond the release assets.

## Target environment

| Item | Value |
|---|---|
| Device | pdx203 (Xperia 1 II), A/B, slot `_a` |
| Kernel | `4.19.325-perf-gd3216e6faee6`, **non-GKI** |
| Kernel source | `AlcatrazDev-Android-Devices/kernel_sony_sm8250` (vendor tree, ships an old in-tree KernelSU 0.9.5) |
| Toolchain | AOSP clang **r563880c / 21.0.0** — the exact compiler the stock kernel was built with |
| Root solution | SukiSU-Ultra `v4.3.0-r2` + manager `com.sukisu.ultra` v4.3.0-r2 |
| Hardening | stock configuration: **LTO + CFI enabled** |

## Verified result (two boots on device)

```
getenforce                     → Enforcing
su -c id                       → uid=0(root) gid=0(root) groups=0(root) context=u:r:ksu:s0
dmesg | grep ksu419            → 2.3s  no su domain, switching SELinux to permissive
                                 2.3s  u:r:ksu:s0 missing (-22) -> using init sid 63
                                 8.8s  su domain adopted (sid 1066, ksu_file 1065), enforcing again
ksud module list               → Zygisk Next 1.5.3 "[zygote ok, zygote_secondary ok, Root: KernelSU]"
ps -A                          → lspd (LSPosed), zn-zygisk-companion64 running
avc: denied … permissive=0     → 0 for the ksu / su domains
```

Image size: 61,126,680 B (stock kernel slice 61,114,392 B, +12 KB);
`uname -r` is identical to stock.

## Why a driver drop-in is not enough

On 4.19 + this ROM, upstream SukiSU needs five compatibility fixes. Any one missing
and either the device does not boot or root never works:

| # | Problem | Symptom | Fix (`build.sh` step) |
|---|---|---|---|
| 1 | `hook/arm64/patch_memory.c` walks page tables with `pmd_leaf()` (**5.x only**) | every text poke returns `-2`; `sys_call_table[42]` is never patched → init's `stat("/")` gets ENOSYS → **`Attempted to kill init`** | on < 5.0 use `__pa()` directly (**3h**) |
| 2 | ROM policy has no `u:r:su:s0` / `u:object_r:ksu_file:s0` | `security_secctx_to_secid` returns `-22`, `setup ksu cred failed`, manager reports "unsupported" | fall back to `u:r:init:s0` / `u:object_r:adb_data_file:s0` (**3i**) |
| 3 | with that fallback, `ksud` carries a non-executable label | `avc: denied { execute } … tcontext=u:object_r:adb_data_file:s0`, root request fails | drop SELinux to permissive when the su domain is missing (**3j**) |
| 4 | root creds were frozen into the fallback domain at boot | `setenforce 1` later makes `su -c id` **segfault (RC=139)** | delayed work retries every 2 s, re-runs `setup_ksu_cred()` once the injected su domain resolves, then `setenforce(1)` (**3k**) |
| 5 | this ROM has **no KernelSU init patch**, so module scripts never run | injector is never launched | use SukiSU's own init.rc injection and append a line running `magiskpolicy --live --apply` with `u:r:init:s0` (**3l**) |

Key findings:

- **Kernel-side policydb injection is not portable to 4.19** (`selinux/sepolicy.c`
  depends on 5.5+ structures), so the policy is reloaded from **userspace**
  (`magiskpolicy --live --apply`) and the kernel later adopts the new SIDs.
- **`call_usermodehelper` is a dead end**: Android's init calls `unshare(CLONE_NEWNS)`,
  so a UMH thread lives in the initial mount namespace where neither `/system` nor
  `/data` exists — every absolute path returns `-ENOENT`.
- In this SukiSU version `KERNEL_SU_DOMAIN` is **`ksu`**, not `su`; the injected rule
  set must create both domains. 4.19 has no `memfd_file` class, so rules using it are
  dropped by `magiskpolicy`.
- After injecting, the root credentials **must be rebuilt**; flipping to Enforcing with
  the old creds is what causes the segfault.

## Build

### Requirements

- Linux or WSL2 (Ubuntu 22.04), ≥ 20 GB RAM for the LTO link
- AOSP clang `r563880c` unpacked to `/opt/clang-r563880c`
- `build-essential bc bison flex libssl-dev libelf-dev python3 cpio rsync lz4 zstd`

The clang tarball is published on `android.googlesource.com`:

```bash
curl -L -o clang-r563880c.tar.gz \
  "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r563880c.tar.gz"
sudo mkdir -p /opt/clang-r563880c && sudo tar -xzf clang-r563880c.tar.gz -C /opt/clang-r563880c
/opt/clang-r563880c/bin/clang --version   # must say: based on r563880c
```

### Build (WSL)

```bash
# online (fetches kernel source and SukiSU from GitHub)
CLANG_VER=r563880c KSU_ALLOW_LTO=1 JOBS=$(nproc) bash tools/wsl_build.sh

# offline (source and driver already local; adjust paths)
KSU_SRC_LOCAL=/path/to/vendor/src \
CLANG_VER=r563880c KSU_VERSION_FULL_OVERRIDE=SukiSUv4.3.0-r2 \
KSU_ALLOW_LTO=1 JOBS=24 bash tools/wsl_build.sh
# the config defaults to config/pdx203_ksu_lto.config; pass CONFIG_FILE=... to override
```

Artifacts land in `wsl-out/`: `Image`, `kernel.release`, `config.used`.

> `build.sh` exports `KBUILD_BUILD_USER=build-user` and `KBUILD_BUILD_HOST=build-host` by
> default, so `/proc/version` matches the stock banner and no local username/hostname is
> embedded in the image.

### Assertions that must hold

```bash
cat wsl-out/kernel.release     # must be exactly 4.19.325-perf-gd3216e6faee6
grep -E '^CONFIG_(LTO|CFI)=y' wsl-out/config.used
```

The release string is pinned in `CONFIG_LOCALVERSION` because the build tree has no
`.git`, so `LOCALVERSION_AUTO` cannot regenerate the `-g<sha>` suffix.

### Optional: display-version override

```bash
KSU_VERSION_FULL_OVERRIDE='SukiSUv4.3.0-r2'   # only changes the "full version" string
```

It does not touch the working version, so manager compatibility is unaffected.

## Repack the boot image

```bash
python tools/repack_boot.py stock_boot.img wsl-out/Image new_boot.img
# self-check: reinserting the original kernel must reproduce the input byte for byte
python tools/repack_boot.py stock_boot.img orig_kernel.bin _rt.img && cmp stock_boot.img _rt.img
```

`stock_boot.img`, `orig_kernel.bin` and `new_boot.img` are **placeholders** for your own
stock image and its kernel slice; those binaries are not in this repository.

`repack_boot.py` preserves the original header, ramdisk, dtb, the Sony-style embedded
AVB vbmeta blob and the AVB footer, and pads to the original partition size.

## Device-side runtime dependency

Two files must exist on the device; the kernel launches the injector on every boot:

```
/data/adb/ksu/bin/magiskpolicy     755   # lib/arm64-v8a/libmagiskpolicy.so from a Magisk APK
/data/adb/ksu/bin/ksu_rules.txt    644   # tools/ksu_rules.txt
```

> **Flashing the image alone still gives you root, but SELinux stays Permissive** —
> the kernel deliberately degrades when the `ksu` domain cannot be resolved.
> To get Enforcing, install both files and reboot once.
> The release assets ship both of them.

### Installing them

`magiskpolicy` is not published standalone; it lives inside the Magisk APK as
`lib/arm64-v8a/libmagiskpolicy.so` (an ET_DYN executable). Verified with
**Magisk v31.1** (newer releases work too as long as that `.so` is present):

```bash
curl -L -o Magisk-v31.1.apk \
  "https://github.com/topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk"
bash tools/install_injector.sh Magisk-v31.1.apk     # extract + push + chmod
```

Manual equivalent:

```bash
unzip -o Magisk-v31.1.apk lib/arm64-v8a/libmagiskpolicy.so -d /tmp/mp
adb push /tmp/mp/lib/arm64-v8a/libmagiskpolicy.so /data/local/tmp/magiskpolicy
adb push tools/ksu_rules.txt /data/local/tmp/ksu_rules.txt
adb shell 'su -c "mkdir -p /data/adb/ksu/bin && cp /data/local/tmp/magiskpolicy /data/adb/ksu/bin/magiskpolicy && chmod 755 /data/adb/ksu/bin/magiskpolicy && cp /data/local/tmp/ksu_rules.txt /data/adb/ksu/bin/ksu_rules.txt && chmod 644 /data/adb/ksu/bin/ksu_rules.txt"'
```

Verify with `runcon` (`chcon` does not validate contexts):

```bash
adb shell "su -c '/data/adb/ksu/bin/magiskpolicy --live --apply /data/adb/ksu/bin/ksu_rules.txt'"
adb shell "su -c 'runcon u:r:ksu:s0 id'"     # → uid=0(root) … context=u:r:ksu:s0
```

## Flash and rollback

```bash
adb reboot bootloader
fastboot flash boot boot_pdx203_sukisu-v4.3.0-r2_enforcing.img
fastboot reboot

# rollback
fastboot flash boot <your stock boot.img>
```

Prerequisites for anyone else flashing this:

| Requirement | If missing |
|---|---|
| same model, pdx203 / XQ-AT52 | will not boot |
| same kernel version `4.19.325-perf-gd3216e6faee6` | may not boot |
| unlocked bootloader | `fastboot flash` is rejected |
| your own stock `boot.img` backed up | no way back |

## Known limitations

- ~9 seconds of SELinux Permissive on every boot (until the policy is injected and adopted)
- the `ksu` and `su` domains are permissive (root needs them)
- no SUSFS, no KPM
- a system OTA overwrites the boot partition and removes root
- only this model and this 4.19 vendor ROM
- manager features that depend on policydb patching are unavailable on 4.19

## Layout

```
README.md / README.en.md      Chinese / English documentation
build.sh                      main build script (3h/3i/3j/3k/3l/3m compat steps)
config/pdx203_ksu_lto.config  kernel config (LTO+CFI, matches stock)
tools/wsl_build.sh            WSL build entry point (online/offline)
tools/repack_boot.py          boot.img repacker (AVB preserved)
tools/ksu_rules.txt           SELinux injection rules (su + ksu domains)
tools/install_injector.sh     extract magiskpolicy from a Magisk APK and install it
docs/known-good-images.md     image-by-image result ledger (text only, no binaries)
```

## Acknowledgements

None of this would exist without these projects:

| Project | Used for |
|---|---|
| [**SukiSU-Ultra**](https://github.com/SukiSU-Ultra/SukiSU-Ultra) | the kernel driver and manager this port is built on |
| [**KernelSU**](https://github.com/tiann/KernelSU) | upstream of SukiSU and of non-GKI support |
| [**Magisk**](https://github.com/topjohnwu/Magisk) | `magiskpolicy`, the only practical way to reload the policy on 4.19 |
| [**kernel_sony_sm8250**](https://github.com/AlcatrazDev-Android-Devices/kernel_sony_sm8250) | the 4.19 vendor kernel tree for this device (maintained by Alcatraz323) |
| [**AOSP clang prebuilts**](https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/) | the `r563880c` toolchain, the same one the stock kernel was built with |
| [**Evolution X**](https://github.com/Evolution-X) | the ROM on the test device, and the source of most compatibility problems |
| [**Zygisk Next**](https://github.com/Dr-TSNG/ZygiskNext) | used to prove the module framework works on 4.19 |
| [**LSPosed**](https://github.com/LSPosed/LSPosed) | same, verifying the Zygisk injection path |

And the Linux kernel community — this is essentially 5.x practice dragged back to 4.19.

## License

- scripts and docs (`build.sh`, `tools/*`, `docs/*`, `README*`): MIT, see `LICENSE`
- the kernel patches in `build.sh` (3h–3m) modify the **Linux kernel (GPL-2.0)** and the
  vendor tree, so those derivative parts are GPL-2.0; get the kernel source from upstream
- the boot images in the release contain the vendor ramdisk and are outside this
  repository's license; use them only on your own device
- `magiskpolicy-arm64` is redistributed unmodified from Magisk v31.1 (GPL-3.0), see
  `NOTICE.txt` in the release

## Disclaimer

For your own device only; flashing is at your own risk. The repository ships scripts and
configuration only — obtain the kernel source from its upstream and respect its license.
