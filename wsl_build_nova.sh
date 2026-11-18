#!/usr/bin/env bash
# 用 AOSP clang (r563880c) 编 pdx203 SukiSU-Nova 内核
# 与 ksu-build/tools/wsl_build.sh 的区别：显式 export PATH，避免落到系统 clang
set -euo pipefail

CLANG_VER=${CLANG_VER:-r563880c}
CLANG_DIR=${CLANG_DIR:-/opt/clang-$CLANG_VER}
export PATH="$CLANG_DIR/bin:$PATH"

export KSU_ALLOW_LTO=${KSU_ALLOW_LTO:-1}
export JOBS=${JOBS:-24}
export CONFIG_FILE=${CONFIG_FILE:-$HOME/ksu-build-nova/config/pdx203_ksu_lto.config}
export KSU_SRC_LOCAL=${KSU_SRC_LOCAL:-$HOME/src/vendor/src}
export KSU_VERSION_FULL_OVERRIDE=${KSU_VERSION_FULL_OVERRIDE:-SukiSU-Nova-v3.0.0}
# 不泄露本机用户名/主机名
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-build-user}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-build-host}

echo "clang: $("$CLANG_DIR/bin/clang" --version | head -1)"
echo "which clang: $(command -v clang)"
echo "KSU src: $KSU_SRC_LOCAL"
echo "config:  $CONFIG_FILE"

cd "$HOME/ksu-build-nova"
bash build-nova.sh "$@"

IMG="$HOME/ksu-build-nova/src/out/arch/arm64/boot/Image"
echo "== Image =="
ls -l "$IMG"
echo "== /proc/version 预览（检查有无个人信息）=="
strings "$IMG" 2>/dev/null | grep -m2 "Linux version" || true
