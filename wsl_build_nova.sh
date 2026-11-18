#!/usr/bin/env bash
# 用 AOSP clang (默认 r563880c) 编 pdx203 SukiSU-Nova 内核
#
# 用法：
#   bash wsl_build_nova.sh              # 完整构建
#   KSU_CHECK_ONLY=1 bash wsl_build_nova.sh   # 只编驱动，快速验证集成
#
# 前置：
#   1. 内核树：git clone 后放到 $KSU_SRC_LOCAL（默认 ~/src/vendor/src）
#   2. clang ：/opt/clang-r563880c（或用 CLANG_DIR 指定其它路径）
#   3. Nova  ：$NOVA_SRC（默认 ~/cache/SukiSU-Nova，脚本会自动 clone）
#
# 编译产物在 <本目录>/src/out/arch/arm64/boot/Image
set -euo pipefail

# 脚本自身所在目录即仓库根目录，不依赖任何本机路径
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLANG_VER=${CLANG_VER:-r563880c}
CLANG_DIR=${CLANG_DIR:-/opt/clang-$CLANG_VER}
if [ ! -x "$CLANG_DIR/bin/clang" ]; then
  echo "!! clang not found: $CLANG_DIR/bin/clang"
  echo "   AOSP prebuilt 下载："
  echo "   curl -sSL 'https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-$CLANG_VER.tar.gz' -o /tmp/clang.tar.gz"
  echo "   sudo mkdir -p $CLANG_DIR && sudo tar -xzf /tmp/clang.tar.gz -C $CLANG_DIR"
  exit 1
fi
export PATH="$CLANG_DIR/bin:$PATH"

export KSU_ALLOW_LTO=${KSU_ALLOW_LTO:-1}
export JOBS=${JOBS:-$(nproc)}
export CONFIG_FILE=${CONFIG_FILE:-$ROOT/config/pdx203_ksu_lto.config}
export KSU_SRC_LOCAL=${KSU_SRC_LOCAL:-$HOME/src/vendor/src}
export NOVA_SRC=${NOVA_SRC:-$HOME/cache/SukiSU-Nova}
export KSU_VERSION_FULL_OVERRIDE=${KSU_VERSION_FULL_OVERRIDE:-SukiSU-Nova-v3.0.0}
# 不泄露构建者身份
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-build-user}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-build-host}

[ -d "$KSU_SRC_LOCAL" ] || { echo "!! kernel tree missing: $KSU_SRC_LOCAL (见 README 前置依赖)"; exit 1; }
if [ ! -d "$NOVA_SRC/kernel" ]; then
  echo "== Nova source missing, cloning to $NOVA_SRC =="
  mkdir -p "$(dirname "$NOVA_SRC")"
  git clone --depth 1 https://github.com/SukiSU-Nova/SukiSU-Nova "$NOVA_SRC"
fi

echo "repo root:  $ROOT"
echo "clang:      $("$CLANG_DIR/bin/clang" --version | head -1)"
echo "kernel src: $KSU_SRC_LOCAL"
echo "nova src:   $NOVA_SRC"
echo "config:     $CONFIG_FILE"

cd "$ROOT"
bash build-nova.sh

if [ "${KSU_CHECK_ONLY:-0}" = "1" ]; then
  echo "== KSU_CHECK_ONLY=1：驱动已通过，跳过 Image 检查 =="
  exit 0
fi

IMG="$ROOT/src/out/arch/arm64/boot/Image"
echo "== Image =="
ls -l "$IMG"
echo "== banner（确认无个人信息）=="
strings "$IMG" 2>/dev/null | grep -m1 "Linux version 4\.19" || true
