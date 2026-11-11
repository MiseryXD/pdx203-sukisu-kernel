# 各轮镜像结果台账

> 仅文字记录（不含镜像文件）。所有镜像均在同一台 pdx203 上手工刷入验证。

设备：Sony Xperia 1 II (XQ-AT52 / pdx203)，slot `_a`，vendor ROM（Android 11），0 个 vendor `.ko`（全内建）。
分区 boot 大小 96 MiB (100,663,296 B)，boot header v2，尾部含 AVB vbmeta blob(704 B) + AVBf 页脚。

## 已验证可用的镜像

| 文件 | 内容 | 状态 |
|---|---|---|
| `vendor_boot_KSU095_working.img` | 维护者原样内核 + 自带 KernelSU 0.9.5，LTO/CFI **关**，vermagic 已锁 | ✅ 已刷机验证：开机正常，官方 KernelSU 管理端显示「工作中」 |
| `ksu_lto_cfi_candidate.img` | SukiSU-Ultra `main`(kprobe) 移植版，LTO+CFI **开**，vermagic 已锁 | ❌ 无法开机：SukiSU 文本补丁页表漫游失败（`patch syscall 42 failed: -2`）→ init ENOSYS → kill init |
| `ksu_lto_nomanual.img` | 同上但 `KSU_MANUAL_SU=n` | ❌ 同样无法开机 — dispatcher 安装是无条件的，关 MANUAL_SU 无用 |
| `ksu_pa_boot.img` | 加了 `__pa()` 文本补丁修复（4.19 无 `pmd_leaf`） | ✅ **能开机**；但管理器 v4.3r2 报"不支持"（内核来自 `main`=4.1.x，且 SELinux SID 缓存 -22、无 prctl 钩子） |
| `ksu_v43_boot.img` | 改用 SukiSU tag `v4.3.0-r2` 重编（版本对齐管理器） | ✅ 能开机，`dispatcher installed at slot 42` 成功；❌ 管理器仍"不支持"，接口层未打通 |

`vendor_boot_KSU095_working.img` sha256 = `c564ac16c3a93432a63505277f7d55b357152ca4aaac52dee32482a746126fea`

## ✅✅ 终版（最接近原厂）：原厂同款 clang + LTO/CFI + Enforcing

| 文件 | 内容 | 状态 |
|---|---|---|
| `ksu_stock_clang_lto_WORKING.img` | 原厂同款 **clang r563880c / 21.0.0**（`5e96669f`，与原厂 banner 同哈希）+ **LTO+CFI 开** + `__pa()` + 3i/3j/3k/3l + `KSU_VERSION_FULL_OVERRIDE=SukiSUv4.3.0-r2` | ✅ **已刷机 + 重启双验证**：Enforcing、`context=u:r:ksu:s0`、avc 拒绝 0（sha256 `5c3f5b181025c5acc8c3d446fb39c213f19daef145e94ac04a2d305278d7e3b1`）|

- `/proc/version`：`Linux version 4.19.325-perf-gd3216e6faee6 (build@host) (Android (14054515, +pgo, +bolt, +lto, +mlgo, based on r563880c) clang version 21.0.0 …)` —— 编译器/构建号与原厂完全一致，只有构建者名不同。
- Image 61,126,680 B（原厂 kernel 段 61,114,392 B，+12 KB），`uname -r` 与原厂相同。
- 管理器「内核完整版本」显示 `SukiSUv4.3.0-r2`（由 `build.sh` **3m** 通过 `KSU_VERSION_FULL_OVERRIDE` 注入 `kernel/Kbuild`，不动 working version，管理器兼容性不受影响）。
- 本机构建命令（离线）：
  ```bash
  KSU_SRC_LOCAL=/home/<user>/src/vendor/src \
  CONFIG_FILE=/home/<user>/ksu-build/config/pdx203_ksu_lto.config \
  CLANG_VER=r563880c KSU_VERSION_FULL_OVERRIDE=SukiSUv4.3.0-r2 \
  KSU_ALLOW_LTO=1 JOBS=24 bash tools/wsl_build.sh
  ```
- 工具链来源：镜像站下载 `clang-r563880c`（`AndroidVersion.txt` = `21.0.0 / based on r563880c`，`BUILD_INFO.bid` = `14054515`），装到 WSL `/opt/clang-r563880c`。
- 坑：`3m` 的锚点必须是 `drivers/kernelsu/Kbuild`——`drivers/kernelsu` 本身就是指向 `KernelSU/kernel` 的软链，写成 `drivers/kernelsu/kernel/Kbuild` 会 `FileNotFoundError` 直接中断构建。

## ✅ 最终版：SukiSU + **Enforcing** 可用 root

| 文件 | 内容 | 状态 |
|---|---|---|
| `ksu_enforcing_boot_WORKING.img` | SukiSU v4.3.0-r2 + `__pa()` 文本补丁 + SID 回退(3i) + permissive 过渡(3j) + 内核重试收养(3k) + **init.rc 注入行(3l)**；非 LTO | ✅ **开机 Enforcing + root 可用**（sha256 `54457575d415877e925ed991caa461cab1e7d321a432d2a02b21f21ce7074ee1`）|

验证记录（两次开机复现）：
```
getenforce                     → Enforcing
su -c id                       → uid=0(root) … context=u:r:ksu:s0
dmesg | grep ksu419            → ksu419: su domain adopted (sid 1065, ksu_file 1066), enforcing again
logcat avc denied permissive=0 → 0
```
开机时序：`2.1s` 3j 切 Permissive → init 解析注入的 init.rc → `post-fs-data` 阶段跑 3l 的注入行（`u:r:init:s0` 执行 magiskpolicy）→ `6.4~17s` 3k 重试解析到 `u:r:ksu:s0`（sid≈1066）→ 重建 root cred + `setenforce(1)`。

### 关键机制（为什么必须这么做）

1. **内核侧的 init.rc 注入是有效的**：SukiSU 会 hook init 的 `read`，把 `KERNEL_SU_RC` 追加进 init.rc；dmesg 有 `KernelSU: read init.rc, comm: init, rc_count: 355`。但 SukiSU 自带的 `exec u:r:ksu:s0 … ksud post-fs-data` 在该 ROM 上此时上下文非法 → ksud SIGABRT。所以 **3l 自己追加一行用 `u:r:init:s0`** 执行注入器。
2. **内核 `call_usermodehelper` 拉不起用户态程序**（返回 `-ENOENT`）：Android init 会 `unshare(CLONE_NEWNS)`，UMH 落在初始 mount namespace，看不到 `/system`、`/data`。此路不通，已放弃。
3. **该版本 `KERNEL_SU_DOMAIN` 是 `ksu`（不是 `su`）**：策略里 ROM 已有 `type su`，但缺 `domain` 属性；内核要的是 `u:r:ksu:s0`，所以注入规则必须同时建 `su` 与 `ksu` 两个域。
4. **magiskpolicy 要按 4.19 裁剪规则**：`memfd_file` 类在 4.19 不存在（`class memfd_file does not exist`），含该类的行会被丢弃。
5. **注入后必须重建 cred**：开机时 root cred 已固化为 toolbox/init 域，只 `setenforce 1` 会让 `su` 段错误（RC=139）。

### 设备端依赖（别删）

```
/data/adb/ksu/bin/magiskpolicy   755   (Magisk v31.1 抽出)
/data/adb/ksu/bin/ksu_rules.txt  644   (同时建 su + ksu 域、ksu_file 类型)
```
不依赖任何 KernelSU 模块（`/data/adb/modules/` 只有 ROM 自带 `uperf`）。

## 离线构建（网络差时）

```bash
# 首次：把 vendor 源码包解到 ~/src/vendor/src 并统一 LF（包里是 CRLF，git apply 会全被拒）
find . -type f \( -name '*.c' -o -name '*.h' -o -name '*.S' -o -name 'Makefile' -o -name 'Kconfig' \) -print0 | xargs -0 sed -i 's/\r$//'
# SukiSU 用 tarball 缓存成带 tag 的本地仓库：~/cache/SukiSU（git init + tag v4.3.0-r2）
KSU_SRC_LOCAL=/home/<user>/src/vendor/src JOBS=24 bash tools/wsl_build.sh
```

两个坑（都会让 0.9.5 钩子残留 → 链接期 `undefined symbol: ksu_handle_*`）：
- `~/ksu-build` **不能是 git 仓库**：`git apply` 会以仓库根为基准，补丁静默空转（`wsl_build.sh` 已加 `--exclude '.git/'`）。
- 源码包必须 LF，否则 `git apply -R` 全部失败，`--3way` 兜底还会返回 0 掩盖错误。

## 复现配方（两种变体）

共同点（缺一不可）：
- 源码：`AlcatrazDev-Android-Devices/kernel_sony_sm8250` @ `533b86f4123c`
- 工具链：AOSP clang **`r563880c` / 21.0.0**（与原厂内核同一把，`BUILD_INFO.bid=14054515`）
- `CONFIG_LOCALVERSION="-perf-gd3216e6faee6"` + `CONFIG_LOCALVERSION_AUTO=n`，且源码副本里 `rm -rf .git`、删掉 `localversion-*`
- 构建后必须断言 `out/include/config/kernel.release == 4.19.325-perf-gd3216e6faee6`

仓库只提供成品配置 `config/pdx203_ksu_lto.config`（LTO+CFI 开，与原厂一致）：
撤掉树内 KSU 0.9.5 → 重新 apply `fs/namespace.c` 的 `path_umount` 回移 → 拉取 SukiSU `v4.3.0-r2` → 一串 4.19 兼容补丁（3h~3m）。

本地构建：`CLANG_VER=r563880c KSU_ALLOW_LTO=1 JOBS=24 bash tools/wsl_build.sh`
（WSL2 Ubuntu-22.04，构建树 `~/ksu-build`，产物回到 `wsl-out/`）。

早期用于二分排查的 `CONFIG_KSU=n` 基线与 vendor 0.9.5 基线配置**不在本仓库内**；
需要时从同一份源码导出，把 `CONFIG_KSU` 关掉或保留树内驱动即可。

## 重打包（只换 kernel 段）

```bash
python tools/repack_boot.py boot.img <Image> out.img
# 自检：把原 kernel 塞回去，输出必须与原镜像逐字节相同
python tools/repack_boot.py boot.img orig_kernel.bin _rt.img && cmp boot.img _rt.img
```

`ksu_lto_cfi_candidate.img` 的校验结果：总大小不变、ramdisk/second/dtb 逐字节相同、header 仅偏移 9 变化、
kernel 段 sha256 == `wsl-out/Image`、vbmeta 704 B 原样保留并搬到新偏移 66,080,768、AVBf 页脚自洽。

## 刷机 / 回滚

```bash
D:\platform-tools\adb.exe reboot bootloader
D:\platform-tools\fastboot.exe flash boot C:\Users\<user>\ksu-cloud\known_good\ksu_lto_cfi_candidate.img
D:\platform-tools\fastboot.exe reboot

# 回滚（刷回已验证镜像）
D:\platform-tools\fastboot.exe flash boot C:\Users\<user>\ksu-cloud\known_good\vendor_boot_KSU095_working.img

# 或彻底回原厂
D:\platform-tools\fastboot.exe flash boot C:\Users\<user>\.hermes\desktop-attachments\boot.img
```

Sony 进 fastboot：关机后按住 **音量上** 插 USB（蓝灯）；出不来时 长按 **Power+音量上 ~15 秒** 强制重启后再插。

## 管理端配对

- 变体 A（内核内 0.9.5）→ 用 `me.weishu.kernelsu`（官方 KernelSU）
- 变体 B（SukiSU main）→ 用 `com.sukisu.ultra`（SukiSU Ultra）

两个 app 可以共存，但**只有与内核匹配的那个**会显示「工作中」。

## ✅ SukiSU 移植成功版

| 文件 | 说明 | 结果 |
|---|---|---|
| `ksu_perm_boot.img` | `v4.3.0-r2` + `__pa()` 修复 + **SELinux 缺失回退**（非 LTO） | ✅ 开机 + 管理器「工作正常」+ `su -c id` = uid=0 |

打通最后一步的两处改动（`build.sh` 段 `3i` / `3j`）：

1. 该 ROM 的策略里**没有** `u:r:su:s0`，`security_secctx_to_secid` 返回 -EINVAL → `setup ksu cred failed`
   → 域解析失败时回退到 `u:r:init:s0`（SID 63，必然存在）；`u:object_r:ksu_file:s0` 缺失时回退 `u:object_r:adb_data_file:s0`。
2. 只有域回退还不够：`/data/adb/ksu/bin/ksud` 标签是 `adb_data_file`，`avc denied { execute }` 直接拦住 ksud
   → 在 `cache_sid()` 的 su 域失败分支调用 `setenforce(false)`，把 SELinux 切成 **Permissive**。

**代价**：`getenforce` 为 Permissive。这是 4.19 上无法注入 sepolicy（policydb 布局不同）时的等效做法；
正常 KernelSU 靠注入 `su`/`ksu_file` 类型 + 规则达成同样效果。日志判据：
`ksu419: u:r:ksu:s0 missing (-22) -> using init sid 63` 与 `ksu419: no su domain, switching SELinux to permissive`。

permissive 下 `su` 的 `context=u:r:toolbox:s0` 属正常（不再做域转换）。

## 注意

- 系统 OTA 会覆盖 boot 分区，升级后需重刷。
- production ROM 上 `adb shell` 无法自证 root（`su` 不在 PATH、`/data/adb` 0700、`dmesg/logcat` 受限），只信管理端显示。
- `/proc/config.gz` 可读，可用它与 `wsl-out/config.used` 做 diff：当前运行内核 vs 待刷候选仅 22 项差异，全部是 LTO/CFI/KPROBES/KSU_* 与三个其他 Sony 机型开关。
