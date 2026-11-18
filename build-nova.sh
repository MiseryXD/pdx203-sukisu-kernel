#!/usr/bin/env bash
# Build a KernelSU-enabled kernel for Sony Xperia 1 II (pdx203)
# Source: AlcatrazDev-Android-Devices/kernel_sony_sm8250 @ 2026-07-05
# Root solution: SukiSU-Ultra (main branch, kprobe hooks)
set -euo pipefail

# 构建者信息会写进 /proc/version，默认是 WSL 的用户名@主机名。
# 对齐原厂 banner（build-user@build-host），同时避免把本机用户名打进镜像。
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-build-user}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-build-host}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"

# --- bisect switch -----------------------------------------------------------
# ./NO_KSU present  ->  build the plain vendor kernel (CONFIG_KSU=n, no SukiSU
# code at all). Used to separate "our KernelSU port breaks boot" from "the base
# kernel / toolchain / config breaks boot".
BASELINE=0
[ -f "$ROOT/NO_KSU" ] && BASELINE=1 || true
CFG_FILE="${CONFIG_FILE:-$ROOT/config/pdx203_ksu_lto.config}"
# ./VENDOR_KSU present -> do NO integration work at all and just build the tree
# as the maintainer shipped it (in-tree KernelSU 0.9.5) with CONFIG_KSU=y.
# Minimal possible diff from stock: only LTO/CFI are off.
if [ -f "$ROOT/VENDOR_KSU" ]; then
  BASELINE=1
  CFG_FILE="$ROOT/config/pdx203_vendor.config"
fi
echo "config=$CFG_FILE baseline=$BASELINE"

# --- safety net: LTO/CFI are OFF in this config (the 4.19 full-LTO link needed
# more RAM + disk than a hosted runner has), so the build fits in ~4 GB. A small
# swap is only insurance -- and it MUST live on the scratch disk, because a big
# swapfile on the runner's root fs triggers "No space left on device".
SWAP_KB="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo || echo 0)"
SWAP_KB="${SWAP_KB:-0}"
if [ "$SWAP_KB" -lt 2000000 ]; then
  SWAPDIR=/mnt
  [ -d "$SWAPDIR" ] || SWAPDIR=/tmp
  echo "swap online: ${SWAP_KB} kB -- adding 6G at $SWAPDIR/swapfile_ksu"
  sudo rm -f "$SWAPDIR/swapfile_ksu"
  sudo fallocate -l 6G "$SWAPDIR/swapfile_ksu" \
    || sudo dd if=/dev/zero of="$SWAPDIR/swapfile_ksu" bs=1M count=6144 status=none
  sudo chmod 600 "$SWAPDIR/swapfile_ksu"
  sudo mkswap "$SWAPDIR/swapfile_ksu" >/dev/null
  sudo swapon "$SWAPDIR/swapfile_ksu" || echo "!! swapon failed (non-fatal)"
fi
echo "--- memory before build ---"
free -h
df -h / /mnt 2>/dev/null | tail -3

# Local builds sit behind the GFW, where raw github is unreachable; gh-proxy.com
# forwards both plain HTTP fetches and git clone, so one prefix fixes all three.
GHP=""
[ "${KSU_GH_PROXY:-0}" = "1" ] && GHP="https://gh-proxy.com/"
KREPO="${GHP}https://github.com/AlcatrazDev-Android-Devices/kernel_sony_sm8250.git"
KCOMMIT="533b86f4123c4358ffa6f77ccd29cdccd5b09383"
KSU095="5c41724546123a76df139d6e393a3a5ae19ad202"
EXPECT_RELEASE="4.19.325-perf-gd3216e6faee6"

echo "==== 1. fetch kernel source (${KCOMMIT:0:12}) ===="
rm -rf "$SRC"
mkdir -p "$SRC"
cd "$SRC"
if [ -n "${KSU_SRC_LOCAL:-}" ] && [ -d "$KSU_SRC_LOCAL" ]; then
  echo "local source: $KSU_SRC_LOCAL (no network)"
  rsync -a --exclude 'out/' --exclude '.git/' "$KSU_SRC_LOCAL"/ "$SRC"/
  cd "$SRC"
else
cd "$SRC"
git init -q .
git remote add origin "$KREPO"
if git fetch --depth 1 origin "$KCOMMIT" 2>/dev/null; then
  git checkout -q FETCH_HEAD
else
  echo "!! fetch by sha failed, falling back to branch history"
  git fetch --depth 400 origin lineage-23.2
  git checkout -q "$KCOMMIT"
fi
fi
git log -1 --format='HEAD %H%n     %s' 2>/dev/null || echo "HEAD (local tree, no git)"

if [ "$BASELINE" = "1" ]; then
  echo "==== BASELINE=1: vendor kernel only, KernelSU skipped ===="
else
echo "==== 2. drop in-tree KernelSU v0.9.5 ===="
if [ -s "$HOME/cache/ksu095.patch" ]; then
  cp "$HOME/cache/ksu095.patch" /tmp/ksu095.patch
else
  curl -sSL "${GHP}https://github.com/AlcatrazDev-Android-Devices/kernel_sony_sm8250/commit/${KSU095}.patch" -o /tmp/ksu095.patch
  cp /tmp/ksu095.patch "$HOME/cache/ksu095.patch" 2>/dev/null || true
fi
git apply -R --whitespace=nowarn /tmp/ksu095.patch || git apply -R --3way --whitespace=nowarn /tmp/ksu095.patch
if [ -d drivers/kernelsu ]; then
  echo "note: leftover in-tree KSU files (different revision), removing"
  rm -rf drivers/kernelsu
fi
if grep -q kernelsu drivers/Makefile; then
  echo "note: stripping leftover kernelsu wiring from drivers/Makefile + Kconfig"
  sed -i '/kernelsu/d' drivers/Makefile
  sed -i '/drivers\/kernelsu\/Kconfig/d' drivers/Kconfig
fi
if grep -q kernelsu drivers/Makefile; then echo "!! drivers/Makefile still wires kernelsu"; exit 1; fi
echo "ok: drivers/kernelsu removed"

echo "==== 2b. re-apply path_umount backport (SukiSU kernel_umount needs it on <5.9) ===="
python3 - <<'PY'
src = open('/tmp/ksu095.patch', encoding='utf-8', errors='replace').read()
parts = src.split('diff --git ')
keep = ['diff --git ' + p for p in parts if p.startswith('a/fs/namespace.c')]
open('/tmp/path_umount.patch', 'w').write(''.join(keep))
print('namespace hunks:', len(keep))
PY
git apply --whitespace=nowarn /tmp/path_umount.patch
grep -q "^int path_umount" fs/namespace.c || { echo "!! path_umount backport failed"; exit 1; }
echo "ok: path_umount present"

echo "==== 3. integrate SukiSU-Nova (v3.0.0, kernel/ 手动集成) ===="
NOVA_SRC="${NOVA_SRC:-$HOME/cache/SukiSU-Nova}"
[ -d "$NOVA_SRC/kernel" ] || { echo "!! Nova source missing: $NOVA_SRC/kernel"; exit 1; }
echo "nova source: $NOVA_SRC"
rm -rf drivers/kernelsu
cp -a "$NOVA_SRC/kernel" drivers/kernelsu
cp -a "$NOVA_SRC/uapi" drivers/kernelsu/uapi
grep -q "kernelsu" drivers/Makefile || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
if ! grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig; then
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi
grep -n "kernelsu" drivers/Makefile drivers/Kconfig
echo "nova kernel/ files: $(find drivers/kernelsu -name '*.c' | wc -l)"

# 复用 Ultra 版验证过的 4.19 兼容补丁（锚点缺失只告警，不中断）
if [ -f "$ROOT/compat419.sh" ]; then
  echo "==== 3a. applying compat419.sh (4.19 shims) ===="
  bash "$ROOT/compat419.sh" || true
fi

echo "==== 3m. optional: SukiSU version-string override (env KSU_VERSION_FULL_OVERRIDE) ===="
python3 - <<'PY'
import sys
p = 'drivers/kernelsu/Kbuild'
s = open(p).read()
if 'KSU_VERSION_FULL_OVERRIDE' in s:
    print('version str    skip (already patched)')
else:
    old = 'KSU_VERSION_FULL := $(if $(call git_short_sha),v$(VERSION_TAG)-$(call git_short_sha)@$(call git_branch),v$(VERSION_TAG)-$(REPO_NAME)-unknown@unknown)'
    new = ('KSU_VERSION_FULL := $(if $(KSU_VERSION_FULL_OVERRIDE),$(KSU_VERSION_FULL_OVERRIDE),'
           '$(if $(call git_short_sha),v$(VERSION_TAG)-$(call git_short_sha)@$(call git_branch),'
           'v$(VERSION_TAG)-$(REPO_NAME)-unknown@unknown))')
    if old not in s:
        sys.exit('!! anchor missing for KSU_VERSION_FULL in ' + p)
    open(p, 'w').write(s.replace(old, new, 1))
    print('version str    ok (override hook)')
PY

fi  # end of KSU integration block

echo "==== 4. configure ===="
mkdir -p out
cp "$CFG_FILE" out/.config

MAKE_ARGS=(O=out ARCH=arm64
  CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu-
  LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip)

make "${MAKE_ARGS[@]}" olddefconfig
grep -E "^CONFIG_(KSU|KPROBES|KPROBE_EVENTS|KRETPROBES|LOCALVERSION|LTO|CFI)=" out/.config || true
if [ "${KSU_ALLOW_LTO:-0}" != "1" ]; then
  grep -q "^CONFIG_LTO_NONE=y" out/.config || { echo "FATAL: LTO still on, refusing to OOM again (set KSU_ALLOW_LTO=1 for local/CI-with-enough-RAM builds)"; exit 1; }
fi

# LTO is off now (see config), so the link step is cheap and full parallelism is
# fine. Override with JOBS=... to throttle.
JOBS="${JOBS:-$(nproc)}"
echo "using -j$JOBS for the image build"

if [ "$BASELINE" = "1" ]; then
  echo "==== 4b. skipped (baseline: no kernelsu driver) ===="
else
echo "==== 4b. fast feedback: prepare + compile kernelsu driver only ===="
make "${MAKE_ARGS[@]}" -j"$(nproc)" prepare > /tmp/prep.log 2>&1 || { tail -40 /tmp/prep.log; exit 1; }
# selinux/objsec.h needs the generated flask.h -> build that dir first
make "${MAKE_ARGS[@]}" -j"$(nproc)" security/selinux/ > /tmp/sel.log 2>&1 || { echo "!! selinux partial build failed"; grep -E "error:" /tmp/sel.log | head -10; exit 1; }
if make -k "${MAKE_ARGS[@]}" -j"$(nproc)" drivers/kernelsu/ > /tmp/ksu_check.log 2>&1; then
  echo "ok: kernelsu driver compiles clean"
else
  echo "!! kernelsu driver failed to compile (all errors, -k):"
  grep -E "error:|fatal error" /tmp/ksu_check.log | sed 's|.*\.\./||' | sort -u | head -80
  exit 1
fi

if [ "${KSU_CHECK_ONLY:-0}" = "1" ]; then
  echo "KSU_CHECK_ONLY=1 -> stopping after driver check"
  exit 0
fi
fi  # end of 4b (skipped for baseline)

echo "==== 5. pin version string (vermagic must match vendor modules) ===="
# build outside git so scripts/setlocalversion appends nothing
rm -rf .git
rm -f localversion-cip localversion-st

echo "==== 6. build ===="
make "${MAKE_ARGS[@]}" -j"$JOBS" Image

REL="$(cat out/include/config/kernel.release)"
echo "kernel.release = $REL"
if [ "$REL" != "$EXPECT_RELEASE" ]; then
  echo "!! VERMAGIC MISMATCH: expected $EXPECT_RELEASE"
  exit 1
fi

ls -la out/arch/arm64/boot/Image out/vmlinux
echo "==== done ===="
