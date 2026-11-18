# pdx203 SukiSU-Nova 内核（4.19 非 GKI）

[English](README.en.md) | 中文

给 **Sony Xperia 1 II（pdx203 / XQ-AT52）** 的 vendor 4.19 内核移植 **SukiSU Nova v3.0.0**，
在 **SELinux Enforcing** 状态下拿到 root 与完整模块框架。

> 本仓库只包含**构建脚本、内核配置、重打包工具和文档**。
> 不含 ROM 二进制、boot 镜像、厂商 blob 或密钥。

## 背景

| 项 | 值 |
|---|---|
| 设备 | pdx203（Xperia 1 II），A/B，当前 slot `_a` |
| 内核 | `4.19.325-perf-gd3216e6faee6`，**非 GKI** |
| 内核源码 | `AlcatrazDev-Android-Devices/kernel_sony_sm8250`（vendor 树，自带旧版 KernelSU 0.9.5） |
| 工具链 | AOSP clang **r563880c / 21.0.0** + LLD 21（与原厂内核相同） |
| 根方案 | **SukiSU Nova v3.0.0**，配合管理器 `com.sukisu.nova` v3.0.0 |
| 加固 | 保持原厂配置：**LTO + CFI 全开** |
| 版本串 | `uname -r` 与原厂完全一致，镜像内只有 `build-user@build-host` |

## 实测结果

```
su -c id            → uid=0(root) gid=0(root) context=u:r:ksu:s0
ksud --version      → 3.0.0 (uapi: 6)          # 内核与用户态版本一致
模块                → 4 个全部加载（含 uperf、Zygisk Next、LSPosed）
Zygisk Next 1.5.3   → ✅zygote, ✅zygote_secondary, 1 service injected
LSPosed v2.2.1      → lspd + companion 进程在跑
音频模块            → post-fs-data 正常执行，HAL 输出 AUDIO_FORMAT_PCM_24_BIT_PACKED
```

`Image` 61,126,680 B，`build.sh` 会校验 `kernel.release` 必须等于 `4.19.325-perf-gd3216e6faee6`，
否则直接报 `VERMAGIC MISMATCH` 退出。

## 与 Ultra 版的关键差异：没有 setup.sh

Nova 仓库不再提供 `setup.sh`，`kernel/` 与 `uapi/` 要手工接线：

```
kernel/  → drivers/kernelsu                       # 源码树
uapi/    → drivers/kernelsu/uapi                  # 头文件，源码里是 #include "uapi/xxx.h"
drivers/Makefile: obj-$(CONFIG_KSU) += kernelsu/
drivers/Kconfig : source "drivers/kernelsu/Kconfig"
```

`uapi/` 这一步漏掉会立刻报 `fatal error: 'uapi/supercall.h' file not found`——它必须放在
`drivers/kernelsu/uapi/`（引号包含是相对路径），不是 `include/uapi/`。

## 4.19 上必须补的坑

Nova v3.0.0 的代码基线是 5.x，直接编 4.19 会有 13 组错误，`compat419.sh` 逐条处理：

| 类别 | 内容 |
|---|---|
| fops 成员 | `file_operations.iopoll`（5.1+）、`remap_file_range`（5.0+）、`REMAP_FILE_DEDUP` |
| mount API | `uapi/linux/mount.h`（5.2+）、`path_mount()`（5.2+，4.19 走 `ksys_mount` + `KERNEL_DS`） |
| task work | `TWA_RESUME`（5.9+，4.19 的 `task_work_add` 收 bool）；`put_task_struct` 需 `<linux/sched/task.h>` |
| seccomp | `SECCOMP_ARCH_NATIVE_NR`、`struct seccomp.filter_count`（5.9+） |
| fsnotify | `fsnotify_ops.handle_inode_event`（5.x）→ 4.19 的 `handle_event` |
| clocksource | `vdso_clock_mode`（5.x）→ `vdso_default_clock_mode` |
| 符号导出 | `MODULE_IMPORT_NS`（5.4+）宏缺失 |
| 头文件 | `<linux/minmax.h>`（5.11+）、`tasklist_lock`/`init_task`/`task_pgrp`/`task_session` |
| 文本补丁 | aarch64 无 `pmd_leaf()`，改用 `__pa()`（`hook/arm64/patch_memory.c`） |
| SELinux | `selinux/sepolicy.c` 依赖 5.5+ 的 `policydb` 字段（`type_val_to_struct`、`filename_trans_key` 等），4.19 按降级路径处理 |

另外沿用 Ultra 版的 SELinux 落地方式：ROM 没有 `u:r:su:s0` / `u:object_r:ksu_file:s0`，
因此开机先用 `magiskpolicy --live --apply` 在用户态注入策略，再由内核重试收养 `ksu` 域并
`setenforce(1)`。细节见 [`docs/ultra-v4.3.0-r2.md`](docs/ultra-v4.3.0-r2.md)。

## 构建

### 前置依赖

| 依赖 | 获取方式 |
|---|---|
| 内核树 | `git clone https://github.com/AlcatrazDev-Android-Devices/kernel_sony_sm8250 ~/src/vendor/src`（默认路径，可用 `KSU_SRC_LOCAL` 覆盖） |
| AOSP clang | `curl -sSL 'https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r563880c.tar.gz' -o /tmp/clang.tar.gz && sudo mkdir -p /opt/clang-r563880c && sudo tar -xzf /tmp/clang.tar.gz -C /opt/clang-r563880c` |
| Nova 源码 | 脚本自动 clone 到 `~/cache/SukiSU-Nova`（可用 `NOVA_SRC` 覆盖） |
| 构建环境 | WSL2 / Linux，**必须在 ext4 上编**，不要在 `/mnt/c` 里编 |

### 用法

```bash
bash wsl_build_nova.sh                     # 完整构建（约 15 分钟，LTO 链接占大头）
KSU_CHECK_ONLY=1 bash wsl_build_nova.sh    # 只编驱动（约 1 分钟，先验证集成）
```

脚本以自身所在目录为仓库根，不依赖本机绝对路径；产物在 `src/out/arch/arm64/boot/Image`。

`wsl_build_nova.sh` 显式 `export PATH=/opt/clang-$CLANG_VER/bin:$PATH`——只写 `CLANG_VER=...`
不会生效，会静默回落到系统 clang（Ubuntu clang 14），产物能开机但工具链与原厂不一致。
`/proc/version` 里出现 `Ubuntu clang` 就是踩了这个坑。

编译分两段：`KSU_CHECK_ONLY=1` 只编 `drivers/kernelsu/`（约 1 分钟，先确认驱动干净），
去掉该变量才走完整 LTO 链接（约 15 分钟）。

## 刷入与回滚

```bash
fastboot flash boot_a pdx203_nova_v3.0.0_boot.img
fastboot flash boot_b pdx203_nova_v3.0.0_boot.img
fastboot reboot
```

开机后安装 **SukiSU Nova v3.0.0** 管理器（`com.sukisu.nova`）。内核与管理器版本必须一致；
它与旧版 `com.sukisu.ultra` 是两个不同的包，可以并存。

回滚：把刷机前备份的原厂 `boot.img` 刷回 `boot_a` / `boot_b` 即可。

## 历史版本

- SukiSU-Ultra `v4.3.0-r2`：见 [docs/ultra-v4.3.0-r2.md](docs/ultra-v4.3.0-r2.md)
- 各轮镜像验证台账（含未采用方案）：[`docs/known-good-images.md`](docs/known-good-images.md)

## 致谢

| 项目 | 贡献 |
|---|---|
| [SukiSU-Nova](https://github.com/SukiSU-Nova/SukiSU-Nova) | 根方案本体（内核驱动 + 管理器） |
| [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) | 上一代实现，本移植的兼容补丁基础 |
| [magiskpolicy](https://github.com/topjohnwu/Magisk) | 4.19 上唯一可行的策略热重载路径 |
| kernel_sony_sm8250 | vendor 内核源码 |

`magiskpolicy-arm64` 来自 Magisk，二进制与许可证说明见发布页的 `NOTICE.txt`。
