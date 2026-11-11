#!/usr/bin/env bash
# Build the pdx203 KernelSU kernel natively inside WSL2 (ext4), for the case
# where the GitHub-hosted runner runs out of RAM / disk on the 4.19 LTO link.
#
# Run from Windows:
#   wsl -d Ubuntu-22.04 -- bash /mnt/c/Users/<user>/ksu-cloud/tools/wsl_build.sh
#
# Env knobs:
#   JOBS=16         make parallelism (default: nproc)
#   KSU_WORK=...    build dir inside ext4 (default ~/ksu-build; NEVER build on /mnt/c)
#   KSU_ALLOW_LTO=1 keep whatever config/pdx203_ksu.config says (needed to build
#                   the LTO+CFI variant: flip CONFIG_LTO_NONE/LTO/CFI there first)
set -euo pipefail

WINROOT=${WINROOT:-/mnt/c/Users/<user>/ksu-cloud}
WORK=${KSU_WORK:-$HOME/ksu-build}
CLANG_VER=${CLANG_VER:-r547379}
CLANG_DIR=${CLANG_DIR:-/opt/clang-$CLANG_VER}

echo "== 1. build deps =="
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  build-essential bc bison flex libssl-dev libelf-dev python3 zip unzip \
  cpio rsync kmod device-tree-compiler lz4 zstd git curl ca-certificates >/dev/null

echo "== 2. clang $CLANG_VER (AOSP prebuilt) =="
if [ ! -x "$CLANG_DIR/bin/clang" ]; then
  sudo mkdir -p "$CLANG_DIR"
  if [ -n "${CLANG_TARBALL:-}" ] && [ -f "$CLANG_TARBALL" ]; then
    echo "using local tarball: $CLANG_TARBALL"
    sudo tar -xzf "$CLANG_TARBALL" -C "$CLANG_DIR"
  else
    curl -sSL --retry 3 \
      "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-$CLANG_VER.tar.gz" \
      -o /tmp/clang.tar.gz
    [ "$(stat -c %s /tmp/clang.tar.gz)" -gt 100000000 ] || { echo "!! clang tarball too small, download blocked?"; exit 1; }
    sudo tar -xzf /tmp/clang.tar.gz -C "$CLANG_DIR"
    rm -f /tmp/clang.tar.gz
  fi
fi
export PATH="$CLANG_DIR/bin:$PATH"
"$CLANG_DIR/bin/clang" --version | head -1
echo "nproc=$(nproc)  mem=$(free -g | awk '/^Mem:/{print $2}')G"

echo "== 3. sync tree to ext4 ($WORK) =="
mkdir -p "$WORK"
rsync -a --delete \
  --exclude 'src/' --exclude 'out/' --exclude 'joblog*.bin' --exclude '.token' --exclude '.git/' \
  "$WINROOT"/ "$WORK"/
cd "$WORK"
git config --global --add safe.directory "$WORK" >/dev/null 2>&1 || true

echo "== 4. build =="
export KSU_GH_PROXY=1
bash build.sh

echo "== 5. publish artifacts back to Windows =="
OUT="$WINROOT/wsl-out"
mkdir -p "$OUT"
cp src/out/arch/arm64/boot/Image "$OUT/Image"
cp src/out/include/config/kernel.release "$OUT/kernel.release" 2>/dev/null || true
cp src/out/.config "$OUT/config.used" 2>/dev/null || true
ls -l "$OUT"
sha256sum "$OUT/Image"
echo "== done =="
