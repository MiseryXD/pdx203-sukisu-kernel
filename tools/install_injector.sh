#!/usr/bin/env bash
# 从 Magisk APK 抽出 magiskpolicy，并把运行时依赖装到设备上。
#
#   ./install_injector.sh /path/to/Magisk-v31.1.apk
#
# 依赖：unzip、adb（设备已 root，`su` 可用）
# 说明：magiskpolicy 就是 APK 里的 lib/arm64-v8a/libmagiskpolicy.so（ET_DYN 可执行），
#       改名为 magiskpolicy 直接运行即可。
set -euo pipefail

APK="${1:-}"
if [ -z "$APK" ] || [ ! -f "$APK" ]; then
    echo "usage: $0 /path/to/Magisk-v31.1.apk" >&2
    exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== 从 $APK 抽取 libmagiskpolicy.so"
unzip -o -q "$APK" "lib/arm64-v8a/libmagiskpolicy.so" -d "$TMP"
SO="$TMP/lib/arm64-v8a/libmagiskpolicy.so"
[ -f "$SO" ] || { echo "!! APK 里没有 lib/arm64-v8a/libmagiskpolicy.so" >&2; exit 1; }
file "$SO" 2>/dev/null || true

echo "== 推送到设备"
adb push "$SO" /data/local/tmp/magiskpolicy
adb push "$HERE/ksu_rules.txt" /data/local/tmp/ksu_rules.txt

echo "== 安装到 /data/adb/ksu/bin"
adb shell 'su -c "
mkdir -p /data/adb/ksu/bin &&
cp /data/local/tmp/magiskpolicy /data/adb/ksu/bin/magiskpolicy &&
chmod 755 /data/adb/ksu/bin/magiskpolicy &&
cp /data/local/tmp/ksu_rules.txt /data/adb/ksu/bin/ksu_rules.txt &&
chmod 644 /data/adb/ksu/bin/ksu_rules.txt &&
ls -lZ /data/adb/ksu/bin/
"'

cat <<'EOF'

== 完成。验证（需要当前策略仍是 Permissive）：
    adb shell "su -c '/data/adb/ksu/bin/magiskpolicy --live --apply /data/adb/ksu/bin/ksu_rules.txt'"
    adb shell "su -c 'runcon u:r:ksu:s0 id'"      # 应输出 uid=0(root) … context=u:r:ksu:s0
之后重启，内核会在 post-fs-data 阶段自己注入并切回 Enforcing。
EOF
