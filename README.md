# pdx203 SukiSU-Ultra 内核（4.19 非 GKI，Enforcing + root）

给 **Sony Xperia 1 II（pdx203 / XQ-AT52）** 的 vendor 4.19 内核打上 **SukiSU-Ultra v4.3.0-r2**，
在 **SELinux Enforcing** 状态下拿到可用的 root。

> 本仓库只包含**构建脚本、内核配置、重打包工具和文档**。
> 不含任何 ROM 二进制、boot 镜像、厂商 blob 或密钥。

## 背景

| 项 | 值 |
|---|---|
| 设备 | pdx203（Xperia 1 II），A/B，slot `_a` |
| 内核 | `4.19.325-perf-gd3216e6faee6`，**非 GKI** |
| 内核源码 | `AlcatrazDev-Android-Devices/kernel_sony_sm8250`（vendor 树，自带旧版 KernelSU 0.9.5） |
| 工具链 | AOSP clang **r563880c / 21.0.0**（与原厂内核相同） |
| 根方案 | SukiSU-Ultra `v4.3.0-r2`，配合管理器 `com.sukisu.ultra` v4.3.0-r2 |
| 加固 | 保持原厂配置：**LTO + CFI 全开** |

## 最终结果（已在本机双次开机验证）

```
getenforce                    → Enforcing
su -c id                      → uid=0(root) gid=0(root) groups=0(root) context=u:r:ksu:s0
dmesg | grep ksu419           → 2.3s  no su domain, switching SELinux to permissive
                                2.3s  u:r:ksu:s0 missing (-22) -> using init sid 63
                                8.8s  su domain adopted (sid 1066, ksu_file 1065), enforcing again
logcat avc denied permissive=0 → 0（ksu / su 域）
ksud module list             → Zygisk Next 1.5.3 "[✅zygote, ✅zygote_secondary, Root: ✅KernelSU]"
ps -A                        → lspd（LSPosed）、zn-zygisk-companion64 均在运行
```

**模块框架是可用的**：3l 在 `post-fs-data` 里先注入策略，等 init 执行自带的
`exec u:r:ksu:s0 … ksud post-fs-data` 时 `ksu` 域已经合法，ksud 不再 SIGABRT，
`/data/adb/modules`、Zygisk Next、LSPosed 全部正常工作。
（早期版本因为注入晚于 ksud，才表现为"模块不可用"。）

产物规模：`Image` 61,126,680 B（原厂 kernel 段 61,114,392 B，+12 KB），`uname -r` 与原厂完全一致。

## 为什么不是「装个驱动就行」

4.19 + 这个 ROM 的组合上，SukiSU 上游代码有 5 个必须自己补的洞，缺一个就跑不起来：

| # | 问题 | 现象 | 修法（`build.sh` 步骤） |
|---|---|---|---|
| 1 | `hook/arm64/patch_memory.c` 用 5.x 的 `pmd_leaf()` 遍历页表 | 文本补丁全返回 `-2`，`sys_call_table[42]` 没改 → init `stat("/")` 得 ENOSYS → **`Attempted to kill init`** | 4.19 直接用 `__pa()`（**3h**） |
| 2 | ROM 策略里没有 `u:r:su:s0` / `u:object_r:ksu_file:s0` | `security_secctx_to_secid` 返回 `-22`，`setup ksu cred failed`，管理器报「不支持」 | SID 回退到 `u:r:init:s0` / `u:object_r:adb_data_file:s0`（**3i**） |
| 3 | 回退后 `ksud` 带的是不可执行标签 | `avc: denied { execute } … tcontext=u:object_r:adb_data_file:s0`，获取 root 失败 | 无 su 域时先 `setenforce(false)`，让 root 立即可用（**3j**） |
| 4 | 开机时 root cred 已固化在 toolbox 域 | 手动 `setenforce 1` 后 `su -c id` **段错误 RC=139** | 内核延迟工作队列每 2 s 重试，解析到 su 域后重建 cred 再 `setenforce(1)`（**3k**） |
| 5 | 该 ROM 没有 KernelSU 的 init 补丁，模块脚本永不执行 | `post-fs-data` 不触发，注入器没人拉起 | 利用 SukiSU 自带的 **init.rc 注入**，追加一行 `exec u:r:init:s0 root -- magiskpolicy --live --apply …`（**3l**） |

关键认知：

- **4.19 上内核侧 policydb 注入不可移植**（`selinux/sepolicy.c` 依赖 5.5+ 结构），所以改成
  **用户态 `magiskpolicy --live --apply` 重载策略**，再由内核重试收养。
- **`call_usermodehelper` 是死路**：Android init 会 `unshare(CLONE_NEWNS)`，UMH 落在初始
  mount namespace，`/system`、`/data` 都不可见 → 永远 `-ENOENT`。
- **该版本 `KERNEL_SU_DOMAIN` 是 `ksu` 而不是 `su`**，注入规则必须两个域都建；
  4.19 没有 `memfd_file` 类，规则里不能出现该类。

## 构建

### 依赖

- Linux / WSL2（Ubuntu 22.04），≥ 20 GB 内存用于 LTO 链接
- AOSP clang `r563880c`，解压到 `/opt/clang-r563880c`
- `build-essential bc bison flex libssl-dev libelf-dev python3 cpio rsync lz4 zstd`

### 一键构建（WSL）

```bash
# 在线（从 GitHub 拉源码 + SukiSU）
CLANG_VER=r563880c KSU_ALLOW_LTO=1 JOBS=$(nproc) bash tools/wsl_build.sh

# 离线（内核源码与 SukiSU 已在本地，路径按需替换）
KSU_SRC_LOCAL=/path/to/vendor/src \
CLANG_VER=r563880c KSU_VERSION_FULL_OVERRIDE=SukiSUv4.3.0-r2 \
KSU_ALLOW_LTO=1 JOBS=24 bash tools/wsl_build.sh
# 配置默认就是仓库里的 config/pdx203_ksu_lto.config；要换用别的配置再传 CONFIG_FILE=...
```

产物落在 `wsl-out/`：`Image` + `kernel.release` + `config.used`。

### 必须成立的两个断言

```bash
cat wsl-out/kernel.release     # 必须 == 4.19.325-perf-gd3216e6faee6
grep -E '^CONFIG_(LTO|CFI)=y' wsl-out/config.used
```

release 串不对 → vendor 驱动/模块会因为 vermagic 不匹配拒绝加载（本机是 0 个 `.ko` 全内建，
但仍按下原厂串，便于对账）。

### 可选：自定义版本显示串

```bash
KSU_VERSION_FULL_OVERRIDE='SukiSUv4.3.0-r2'   # 只改「内核完整版本」显示，不动 working version
```

## 重打包 boot.img

```bash
python tools/repack_boot.py stock_boot.img wsl-out/Image new_boot.img
# 自检：把原 kernel 塞回去必须与原镜像逐字节相同
python tools/repack_boot.py stock_boot.img orig_kernel.bin _rt.img && cmp stock_boot.img _rt.img
```

> 上面 `stock_boot.img` / `orig_kernel.bin` / `new_boot.img` 都是**占位文件名**，指向你自己的
> 原厂 `boot.img` 和从中切出的 kernel 段；这些二进制不在本仓库内。

`repack_boot.py` 保留原 header、ramdisk、dtb、Sony 风格内嵌 AVB vbmeta blob 和 AVBf 页脚，
并按原分区大小补零。

## 设备端运行时依赖

刷入后，这两个文件**必须存在**，内核每次开机都会拉起它们做策略注入：

```
/data/adb/ksu/bin/magiskpolicy     755   # Magisk APK 里的 lib/arm64-v8a/libmagiskpolicy.so
/data/adb/ksu/bin/ksu_rules.txt    644   # 见 tools/ksu_rules.txt
```

不依赖任何 KernelSU 模块。

> **只刷镜像不装这两个文件**也能用 root，但 SELinux 会停在 **Permissive**
> （内核找不到 `ksu` 域时按设计降级）。要 Enforcing 必须装好并重启一次。
> Release 附件里已附带这两个文件（`magiskpolicy-arm64`、`ksu_rules.txt`）。

### 怎么装这两个文件

`magiskpolicy` 不是独立发布的二进制，它就在 Magisk APK 里（`lib/arm64-v8a/libmagiskpolicy.so`，
ET_DYN，可执行）。已验证版本 **Magisk v31.1**（更新的版本同样可用，只要还带这个 so）：

```bash
# 1. 取 APK（官方 release；直连不通时可套 gh-proxy）
curl -L -o Magisk-v31.1.apk \
  "https://github.com/topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk"

# 2. 一键抽取 + 推送 + 装到 /data/adb/ksu/bin（需要 adb 与设备 root）
bash tools/install_injector.sh Magisk-v31.1.apk
```

手动等价命令：

```bash
unzip -o Magisk-v31.1.apk lib/arm64-v8a/libmagiskpolicy.so -d /tmp/mp
adb push /tmp/mp/lib/arm64-v8a/libmagiskpolicy.so /data/local/tmp/magiskpolicy
adb push tools/ksu_rules.txt /data/local/tmp/ksu_rules.txt
adb shell 'su -c "mkdir -p /data/adb/ksu/bin && cp /data/local/tmp/magiskpolicy /data/adb/ksu/bin/magiskpolicy && chmod 755 /data/adb/ksu/bin/magiskpolicy && cp /data/local/tmp/ksu_rules.txt /data/adb/ksu/bin/ksu_rules.txt && chmod 644 /data/adb/ksu/bin/ksu_rules.txt"'
```

验证注入是否真的生效（用 `runcon`，`chcon` 不校验上下文）：

```bash
adb shell "su -c '/data/adb/ksu/bin/magiskpolicy --live --apply /data/adb/ksu/bin/ksu_rules.txt'"
adb shell "su -c 'runcon u:r:ksu:s0 id'"     # → uid=0(root) … context=u:r:ksu:s0
```

## 刷入 / 回滚

```bash
adb reboot bootloader
fastboot flash boot new_boot.img
fastboot reboot
# 回滚
fastboot flash boot <原厂 boot.img>
```

刷前一定留一份可开机的镜像和原厂 `boot.img`。

## 已知限制

- 开机前 ~9 秒处于 SELinux Permissive（等策略注入 + 收养完成），之后回到 Enforcing
- `ksu` / `su` 两个域是 permissive（root 需要）
- 没有 SUSFS / KPM（4.19 未移植）
- 系统 OTA 会覆盖 boot 分区，root 丢失
- 管理器「SELinux 规则」等依赖 policydb 的功能不可用（4.19 未移植）

## 目录

```
build.sh                      主构建脚本（含 3h/3i/3j/3k/3l/3m 兼容补丁）
config/pdx203_ksu_lto.config  内核配置（LTO+CFI 开，与原厂一致）
tools/wsl_build.sh            WSL 构建入口（离线/在线）
tools/repack_boot.py          boot.img 重打包（保留 AVB）
tools/ksu_rules.txt           SELinux 注入规则（su + ksu 双域）
tools/install_injector.sh     从 Magisk APK 抽 magiskpolicy 并装到设备
docs/known-good-images.md     各轮镜像结果台账（仅文字记录，不含镜像）
```

## 许可

- 本仓库的**脚本与文档**（`build.sh`、`tools/*`、`docs/*`、`README.md`）：MIT，见 `LICENSE`
- `build.sh` 里对内核源码的补丁（3h~3m）属于对 **Linux 内核（GPL-2.0）** 及厂商内核树的修改，
  其衍生部分按 **GPL-2.0** 分发；内核源码请从其上游获取
- Release 中的 boot 镜像包含厂商 ramdisk，仅供同型号设备自用，不在本仓库的许可范围内

## 免责声明

仅用于**自己拥有的设备**的内核研究与系统维护。仓库不包含任何厂商代码、镜像或密钥；
内核源码请自行从其上游获取并遵守其许可证。
