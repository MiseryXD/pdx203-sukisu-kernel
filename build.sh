#!/usr/bin/env bash
# Build a KernelSU-enabled kernel for Sony Xperia 1 II (pdx203)
# Source: AlcatrazDev-Android-Devices/kernel_sony_sm8250 @ 2026-07-05
# Root solution: SukiSU-Ultra (main branch, kprobe hooks)
set -euo pipefail

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

echo "==== 3. integrate SukiSU-Ultra (v4.3.0-r2 / kprobe -- must match manager v4.3r2) ===="
KSU_REF="${KSU_REF:-v4.3.0-r2}"
if [ -d "$HOME/cache/SukiSU" ]; then
  echo "local SukiSU repo: $HOME/cache/SukiSU"
  rsync -a "$HOME/cache/SukiSU"/ KernelSU/
  sed -e "s#git clone https://github.com/SukiSU-Ultra/SukiSU-Ultra KernelSU#true#" \
      -e "s#^\s*git pull.*#true#" "$HOME/cache/setup.sh" > /tmp/ksu_setup_local.sh
  bash /tmp/ksu_setup_local.sh "$KSU_REF"
else
  curl -LSs "${GHP}https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s "$KSU_REF"
fi
grep -n "kernelsu" drivers/Makefile drivers/Kconfig

echo "==== 3b. compat: MODULE_IMPORT_NS only exists on >= 5.4 ===="
python3 - <<'PY'
p = 'drivers/kernelsu/core/init.c'
s = open(p).read()
needle = 'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);'
guard = '#ifndef MODULE_IMPORT_NS\n#define MODULE_IMPORT_NS(x)\n#endif\n'
if 'define MODULE_IMPORT_NS' not in s:
    assert needle in s, 'anchor not found in init.c'
    s = s.replace(needle, guard + needle, 1)
    open(p, 'w').write(s)
    print('patched', p)
else:
    print('already patched')
PY

echo "==== 3c. compat: file_wrapper.c uses post-4.19 fops members ===="
python3 - <<'PY'
p = 'drivers/kernelsu/infra/file_wrapper.c'
s = open(p).read()
done = []

def sub(old, new, tag, count=1):
    global s
    assert s.count(old) >= 1, 'anchor missing: ' + tag
    s = s.replace(old, new, count)
    done.append(tag)

# iopoll: struct file_operations.iopoll appears in 5.1
sub("#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\nstatic int ksu_wrapper_iopoll",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\nstatic int ksu_wrapper_iopoll",
    'iopoll-def-open')
sub("    return orig->f_op->iopoll(kiocb, spin);\n}\n#endif\n",
    "    return orig->f_op->iopoll(kiocb, spin);\n}\n#endif\n#endif /* >= 5.1 */\n",
    'iopoll-def-close')
sub("    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;\n#endif\n",
    'iopoll-assign')

# remap_file_range: 4.19 only has dedupe_file_range (5 args), member renamed in 5.0
sub("static loff_t ksu_wrapper_remap_file_range",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\nstatic loff_t ksu_wrapper_remap_file_range",
    'remap-def-open')
sub("        return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n    }\n}\n",
    "        return orig->f_op->remap_file_range(orig, pos_in, file_out, pos_out, len, remap_flags);\n    }\n}\n#endif /* >= 5.0 */\n",
    'remap-def-close')
sub("    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n",
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;\n#endif\n",
    'remap-assign')

open(p, 'w').write(s)
print('file_wrapper.c patched:', ', '.join(done))
PY

echo "==== 3d. compat: seccomp action cache only exists on >= 5.9 ===="
python3 - <<'PY'
p = 'drivers/kernelsu/infra/seccomp_cache.c'
s = open(p).read()
if 'kernelsu: 4.19 stub' not in s:
    anchor = 'struct action_cache {'
    assert anchor in s, 'anchor missing in seccomp_cache.c'
    head, body = s.split(anchor, 1)
    stub = """/* kernelsu: 4.19 stub -- the seccomp action cache (SECCOMP_ARCH_NATIVE_NR,
 * struct action_cache inside struct seccomp_filter) was introduced in 5.9.
 * On 4.19 the local struct layout below does NOT match the kernel's own
 * struct seccomp_filter, so poking it would corrupt memory. The cache is a
 * pure fast-path optimisation: making these no-ops keeps the syscall bypass
 * working, just without the cached-bit shortcut. */
#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)
void ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr)
{
    (void)filter;
    (void)nr;
}

void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr)
{
    (void)filter;
    (void)nr;
}
#else
"""
    s = head + stub + anchor + body.rstrip('\n') + '\n#endif /* >= 5.9 */\n'
    open(p, 'w').write(s)
    print('patched', p)
else:
    print('already patched')
PY

echo "==== 3e. compat: uapi/mount.h (5.2+), path_mount (5.2+), TWA_RESUME (5.9+) ===="
python3 - <<'PY'
import sys

def patch(p, marker, old, new, tag):
    s = open(p).read()
    if marker in s:
        print('%-14s skip (already patched)' % tag)
        return
    if old not in s:
        sys.exit('!! anchor missing for %s in %s' % (tag, p))
    open(p, 'w').write(s.replace(old, new, 1))
    print('%-14s ok' % tag)

# --- su_mount_ns.c: uapi/linux/mount.h does not exist before 5.2 (MS_* live in uapi/linux/fs.h) ---
patch('drivers/kernelsu/infra/su_mount_ns.c',
      'ksu419: mount.h',
      '#include <uapi/linux/mount.h>',
      '/* ksu419: mount.h */\n'
      '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)\n'
      '#include <uapi/linux/mount.h>\n'
      '#endif',
      'mount.h')

# --- su_mount_ns.c: path_mount() arrived with the 5.2 mount API refactor ---
patch('drivers/kernelsu/infra/su_mount_ns.c',
      'ksu419: path_mount',
      'extern int path_mount(const char *dev_name, struct path *path, const char *type_page, unsigned long flags,\n'
      '                      void *data_page);',
      '/* ksu419: path_mount */\n'
      '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 2, 0)\n'
      'extern int path_mount(const char *dev_name, struct path *path, const char *type_page, unsigned long flags,\n'
      '                      void *data_page);\n'
      '#else\n'
      '/* 4.19 has no path_mount(). The only call site asks for MS_PRIVATE|MS_REC on\n'
      ' * the fs root, so route it through ksys_mount() with KERNEL_DS so kernel\n'
      ' * strings are accepted as user pointers (valid up to 5.10). */\n'
      '#include <linux/syscalls.h>\n'
      '#include <linux/uaccess.h>\n'
      'static int path_mount(const char *dev_name, struct path *path, const char *type_page,\n'
      '                      unsigned long flags, void *data_page)\n'
      '{\n'
      '    mm_segment_t old_fs;\n'
      '    int ret;\n'
      '    (void)dev_name;\n'
      '    (void)path;\n'
      '    (void)type_page;\n'
      '    (void)data_page;\n'
      '    old_fs = get_fs();\n'
      '    set_fs(KERNEL_DS);\n'
      '    ret = ksys_mount(NULL, (char __user *)"/", NULL, flags, NULL);\n'
      '    set_fs(old_fs);\n'
      '    return ret;\n'
      '}\n'
      '#endif',
      'path_mount')

# --- TWA_RESUME enum is 5.9+; 4.19 task_work_add() takes a bool ---
for f in ('drivers/kernelsu/policy/allowlist.c', 'drivers/kernelsu/supercall/supercall.c'):
    patch(f,
          'ksu419: TWA_RESUME',
          '#include <linux/task_work.h>\n',
          '#include <linux/task_work.h>\n'
          '/* ksu419: TWA_RESUME -- 4.19 task_work_add() takes a bool, TWA_* enum is 5.9+ */\n'
          '#ifndef TWA_RESUME\n'
          '#define TWA_RESUME true\n'
          '#endif\n',
          f.split('/')[-1])
PY

echo "==== 3f. compat: fsnotify 4.19, clocksource vdso, seccomp filter_count, task.h ===="
echo "==== 3f-2. drop 5.x-only SELinux policydb subsystem, stub its API ===="
python3 - <<'PY'
import sys

def load(p):
    return open(p, newline='').read().replace('\r\n', '\n')

def save(p, s):
    open(p, 'w', newline='\n').write(s)

def patch(p, marker, old, new, tag):
    s = load(p)
    if marker in s:
        print('%-18s skip (already patched)' % tag)
        return
    if old not in s:
        sys.exit('!! anchor missing for %s in %s' % (tag, p))
    save(p, s.replace(old, new, 1))
    print('%-18s ok' % tag)

# --- allowlist.c: put_task_struct() lives in <linux/sched/task.h> ---
patch('drivers/kernelsu/policy/allowlist.c',
      'ksu419: sched/task.h',
      '#include <linux/task_work.h>\n',
      '/* ksu419: sched/task.h */\n'
      '#include <linux/sched/task.h>\n'
      '#include <linux/task_work.h>\n',
      'allowlist task.h')

# --- app_profile.c: struct seccomp.filter_count is 5.9+ ---
patch('drivers/kernelsu/policy/app_profile.c',
      'ksu419: filter_count',
      '    atomic_set(&current->seccomp.filter_count, 0);\n',
      '/* ksu419: filter_count */\n'
      '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n'
      '    atomic_set(&current->seccomp.filter_count, 0);\n'
      '#endif\n',
      'app_profile')

# --- app_profile.c: seccomp_filter_release() only exists since 5.9; 4.19 has
# put_seccomp_filter(), which is exactly the __put_seccomp_filter() half of it.
# The caller already cleared current->seccomp (mode/filter) itself, and the
# 'fake' copy still holds the old filter pointer, so the two are equivalent.
patch('drivers/kernelsu/policy/app_profile.c',
      'ksu419: seccomp release',
      'void seccomp_filter_release(struct task_struct *tsk);\n',
      '/* ksu419: seccomp release -- pre-5.9 has put_seccomp_filter() instead of\n'
      ' * seccomp_filter_release(); same refcount drop, see kernel/seccomp.c. */\n'
      '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n'
      'void seccomp_filter_release(struct task_struct *tsk);\n'
      '#else\n'
      '#define seccomp_filter_release put_seccomp_filter\n'
      '#endif\n',
      'app_profile seccomp')

# --- cpu_spoof.c: clocksource.vdso_clock_mode + enum vdso_clock_mode are 5.3+ ---
patch('drivers/kernelsu/extension/cpu_spoof.c',
      'ksu419: clocksource vdso',
      '                    if (curr_cs_ptr && *curr_cs_ptr) {\n'
      '                        (*curr_cs_ptr)->vdso_clock_mode =\n'
      '                            VDSO_CLOCKMODE_ARCHTIMER;\n'
      '                    } else {\n',
      '                    if (curr_cs_ptr && *curr_cs_ptr) {\n'
      '/* ksu419: clocksource vdso -- struct clocksource has no vdso_clock_mode\n'
      ' * before 5.3, and neither does enum vdso_clock_mode exist. Time spoofing\n'
      ' * is cosmetic, so skip it there instead of patching struct layout. */\n'
      '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 3, 0)\n'
      '                        (*curr_cs_ptr)->vdso_clock_mode =\n'
      '                            VDSO_CLOCKMODE_ARCHTIMER;\n'
      '#endif\n'
      '                    } else {\n',
      'cpu_spoof cs')

patch('drivers/kernelsu/extension/cpu_spoof.c',
      'ksu419: vdso-def-open',
      '                {\n'
      '                    enum vdso_clock_mode *vd_default =\n',
      '/* ksu419: vdso-def-open */\n'
      '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 3, 0)\n'
      '                {\n'
      '                    enum vdso_clock_mode *vd_default =\n',
      'cpu_spoof vdso_default')

patch('drivers/kernelsu/extension/cpu_spoof.c',
      'ksu419: vdso-def-close',
      "                        pr_warn(\"ksu: set_spoof_cpu failed to resolve 'vdso_default'\\n\");\n"
      '                        ++missing;\n'
      '                    }\n'
      '                }\n',
      "                        pr_warn(\"ksu: set_spoof_cpu failed to resolve 'vdso_default'\\n\");\n"
      '                        ++missing;\n'
      '                    }\n'
      '                }\n'
      '/* ksu419: vdso-def-close */\n'
      '#endif\n',
      'cpu_spoof vdso end')

# --- pkg_observer.c: fsnotify_ops.handle_inode_event + struct qstr name are 5.9+ ---
patch('drivers/kernelsu/manager/pkg_observer.c',
      '#include <linux/string.h>',
      '#include <linux/sched.h>\n',
      '#include <linux/sched.h>\n'
      '#include <linux/string.h>\n',
      'pkg_observer str.h')

patch('drivers/kernelsu/manager/pkg_observer.c',
      'ksu419: fsnotify',
      'static int ksu_handle_inode_event(struct fsnotify_mark *mark, u32 mask, struct inode *inode, struct inode *dir,\n'
      '                                  const struct qstr *file_name, u32 cookie)\n'
      '{\n'
      '    if (!file_name)\n'
      '        return 0;\n'
      '    if (mask & FS_ISDIR)\n'
      '        return 0;\n'
      '    if (file_name->len == 13 && !memcmp(file_name->name, "packages.list", 13)) {\n'
      '        pr_info("packages.list detected: %d\\n", mask);\n'
      '        ksu_defer_track_throne();\n'
      '    }\n'
      '    return 0;\n'
      '}\n'
      '\n'
      'static const struct fsnotify_ops ksu_ops = {\n'
      '    .handle_inode_event = ksu_handle_inode_event,\n'
      '};\n',
      '/* ksu419: fsnotify -- 4.19 uses handle_event() with a NUL-terminated\n'
      ' * unsigned char name (no mark, no dir, no qstr). */\n'
      '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n'
      'static int ksu_handle_inode_event(struct fsnotify_mark *mark, u32 mask, struct inode *inode, struct inode *dir,\n'
      '                                  const struct qstr *file_name, u32 cookie)\n'
      '{\n'
      '    if (!file_name)\n'
      '        return 0;\n'
      '    if (mask & FS_ISDIR)\n'
      '        return 0;\n'
      '    if (file_name->len == 13 && !memcmp(file_name->name, "packages.list", 13)) {\n'
      '        pr_info("packages.list detected: %d\\n", mask);\n'
      '        ksu_defer_track_throne();\n'
      '    }\n'
      '    return 0;\n'
      '}\n'
      '\n'
      'static const struct fsnotify_ops ksu_ops = {\n'
      '    .handle_inode_event = ksu_handle_inode_event,\n'
      '};\n'
      '#else\n'
      'static int ksu_handle_inode_event_419(struct fsnotify_group *group, struct inode *inode, u32 mask,\n'
      '                                     const void *data, int data_type, const unsigned char *file_name,\n'
      '                                     u32 cookie, struct fsnotify_iter_info *iter_info)\n'
      '{\n'
      '    (void)group;\n'
      '    (void)inode;\n'
      '    (void)data;\n'
      '    (void)data_type;\n'
      '    (void)cookie;\n'
      '    (void)iter_info;\n'
      '    if (!file_name)\n'
      '        return 0;\n'
      '    if (mask & FS_ISDIR)\n'
      '        return 0;\n'
      '    if (!strcmp((const char *)file_name, "packages.list")) {\n'
      '        pr_info("packages.list detected: %d\\n", mask);\n'
      '        ksu_defer_track_throne();\n'
      '    }\n'
      '    return 0;\n'
      '}\n'
      '\n'
      'static const struct fsnotify_ops ksu_ops = {\n'
      '    .handle_event = ksu_handle_inode_event_419,\n'
      '};\n'
      '#endif\n',
      'pkg_observer')

STUB = '''// SPDX-License-Identifier: GPL-2.0
/*
 * ksu419: 4.19 still has the pre-5.5 SELinux layout -- flex_array avtab, no
 * struct selinux_policy indirection, no filename_trans_key, no status_page.
 * The upstream sepolicy patcher (selinux/sepolicy.c), its rule loader
 * (selinux/rules.c) and the status-page hider (feature/selinux_hide.c)
 * therefore cannot be built for this kernel.
 *
 * Root is unaffected: ksu escalates by installing init's creds, so no custom
 * policy has to be injected to run su. Policy commands coming from ksud are
 * answered with -EOPNOTSUPP instead of pretending to succeed.
 */
#include <linux/errno.h>
#include <linux/types.h>
#include <linux/version.h>

struct selinux_policy;

#include "selinux/sepolicy.h"
#include "selinux/selinux.h"
#include "feature/selinux_hide.h"

/* --- selinux/sepolicy.c --- */
struct selinux_policy *ksu_dup_sepolicy(struct selinux_policy *old_pol)
{
	return NULL;
}

void ksu_destroy_sepolicy(struct selinux_policy *orig)
{
}

bool ksu_type(struct policydb *db, const char *name, const char *attr)
{
	return false;
}

bool ksu_attribute(struct policydb *db, const char *name)
{
	return false;
}

bool ksu_permissive(struct policydb *db, const char *type)
{
	return false;
}

bool ksu_enforce(struct policydb *db, const char *type)
{
	return false;
}

bool ksu_typeattribute(struct policydb *db, const char *type, const char *attr)
{
	return false;
}

bool ksu_exists(struct policydb *db, const char *type)
{
	return false;
}

int ksu_type_is_original(struct policydb *db, u32 policy_generation, u32 type_value)
{
	return -1;
}

bool ksu_set_original_types(struct policydb *db, struct policydb *orig_db, u32 policy_generation)
{
	return false;
}

bool ksu_advance_original_types(struct policydb *db, struct policydb *old_db, u32 old_policy_generation,
				u32 policy_generation)
{
	return false;
}

bool ksu_allow(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm)
{
	return false;
}

bool ksu_deny(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm)
{
	return false;
}

bool ksu_auditallow(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm)
{
	return false;
}

bool ksu_dontaudit(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *perm)
{
	return false;
}

bool ksu_allowxperm(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *range)
{
	return false;
}

bool ksu_auditallowxperm(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *range)
{
	return false;
}

bool ksu_dontauditxperm(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *range)
{
	return false;
}

bool ksu_type_transition(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *def,
			 const char *obj)
{
	return false;
}

bool ksu_type_change(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *def)
{
	return false;
}

bool ksu_type_member(struct policydb *db, const char *src, const char *tgt, const char *cls, const char *def)
{
	return false;
}

bool ksu_genfscon(struct policydb *db, const char *fs_name, const char *path, const char *ctx)
{
	return false;
}

/* --- selinux/rules.c --- */
void apply_kernelsu_rules(void)
{
}

int handle_sepolicy(void __user *user_data, u64 data_len)
{
	return -EOPNOTSUPP;
}

/* --- feature/selinux_hide.c --- */
void ksu_selinux_hide_init(void)
{
}

void ksu_selinux_hide_exit(void)
{
}

void ksu_selinux_hide_drop_backup_if_unused(void)
{
}

void ksu_selinux_hide_handle_second_stage(void)
{
}

void ksu_selinux_hide_handle_post_fs_data(void)
{
}
'''

p = 'drivers/kernelsu/ksu419_selinux_stub.c'
try:
    cur = load(p)
except FileNotFoundError:
    cur = None
if cur != STUB:
    save(p, STUB)
    print('%-18s written' % 'selinux stub')
else:
    print('%-18s skip' % 'selinux stub')

# --- Kbuild: swap the three 5.x-only units for the stub on 4.x ---
patch('drivers/kernelsu/Kbuild',
      'ksu419: selinux stub',
      'kernelsu-objs += selinux/rules.o\n'
      'kernelsu-objs += selinux/sepolicy.o\n',
      '# ksu419: selinux stub -- 4.19 policydb layout differs, see ksu419_selinux_stub.c\n'
      'ifeq ($(VERSION),4)\n'
      'kernelsu-objs += ksu419_selinux_stub.o\n'
      'else\n'
      'kernelsu-objs += selinux/rules.o\n'
      'kernelsu-objs += selinux/sepolicy.o\n'
      'endif\n',
      'Kbuild sepolicy')

patch('drivers/kernelsu/Kbuild',
      'ksu419: selinux_hide off',
      'kernelsu-objs += feature/selinux_hide.o\n',
      '# ksu419: selinux_hide off -- status_page/status_lock are 5.7+\n'
      'ifneq ($(VERSION),4)\n'
      'kernelsu-objs += feature/selinux_hide.o\n'
      'endif\n',
      'Kbuild selinux_hide')
PY

echo "==== 3g. compat: minmax.h (5.11+), tasklist_lock/init_task/task_pgrp ===="
python3 - <<'PY'
import sys

def load(p):
    return open(p, newline='').read().replace('\r\n', '\n')

def save(p, s):
    open(p, 'w', newline='\n').write(s)

def patch(p, marker, old, new, tag):
    s = load(p)
    if marker in s:
        print('%-16s skip (already patched)' % tag)
        return
    if old not in s:
        sys.exit('!! anchor missing for %s in %s' % (tag, p))
    save(p, s.replace(old, new, 1))
    print('%-16s ok' % tag)

# --- sulog/event.c: <linux/minmax.h> only exists from 5.11; kernel.h has the macros ---
patch('drivers/kernelsu/sulog/event.c',
      'ksu419: minmax.h',
      '#include <linux/minmax.h>\n',
      '/* ksu419: minmax.h -- 5.11+. kernel.h carries min/max/clamp on 4.19. */\n'
      '#include <linux/kernel.h>\n',
      'sulog minmax')

# --- supercall/dispatch.c: tasklist_lock/init_task live in sched/task.h,
#     task_pgrp/task_session in sched/signal.h, change_pid in pid.h ---
patch('drivers/kernelsu/supercall/dispatch.c',
      'ksu419: sched headers',
      '#include <linux/thread_info.h>\n',
      '#include <linux/thread_info.h>\n'
      '/* ksu419: sched headers -- do_set_init_pgrp() needs tasklist_lock, init_task,\n'
      ' * task_pgrp/task_session and change_pid; nothing pulls them in on 4.19. */\n'
      '#include <linux/pid.h>\n'
      '#include <linux/sched/signal.h>\n'
      '#include <linux/sched/task.h>\n',
      'dispatch sched')
PY

echo "==== 3h. compat: aarch64 text poke -- 4.19 has no pmd_leaf(), use __pa() ===="
python3 - <<'PY'
import sys

def patch(p, marker, old, new, tag):
    s = open(p).read()
    if marker in s:
        print('%-14s skip (already patched)' % tag)
        return
    if old not in s:
        sys.exit('!! anchor missing for %s in %s' % (tag, p))
    open(p, 'w').write(s.replace(old, new, 1))
    print('%-14s ok' % tag)

# --- patch_memory.c: phys_from_virt() walks init_mm with pgd/p4d/pud/pmd/pte and
#     only knows pmd_leaf() (5.x). On 4.19 there is no pmd_leaf(), so a 2 MiB
#     section mapping or a split rodata page falls through the walk and returns
#     -ENOENT. KSU then fails to write sys_call_table[42] ("failed to patch kernel
#     address ...: -2" / "patch syscall 42 failed"), its dispatcher never lands,
#     and init's early stat()/access() calls return ENOSYS ->
#     "FirstStageMount not available" -> "Attempted to kill init" panic.
#     arm64's __virt_to_phys() already handles both the linear map and the kernel
#     image mapping (kimage_voffset, KASLR-safe), which is all this needs.
patch('drivers/kernelsu/hook/arm64/patch_memory.c',
      'ksu419: phys via __pa',
      '    int phy_err;\n'
      '    unsigned long phy = phys_from_virt(p, &phy_err);\n'
      '    if (phy_err) {\n'
      '        ret = phy_err;\n'
      '        goto err;\n'
      '    }',
      '/* ksu419: phys via __pa */\n'
      '#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)\n'
      '    int phy_err = 0;\n'
      '    unsigned long phy = (unsigned long)__pa(p);\n'
      '    (void)phy_err;\n'
      '#else\n'
      '    int phy_err;\n'
      '    unsigned long phy = phys_from_virt(p, &phy_err);\n'
      '    if (phy_err) {\n'
      '        ret = phy_err;\n'
      '        goto err;\n'
      '    }\n'
      '#endif',
      'phys __pa')

patch('drivers/kernelsu/hook/arm64/patch_memory.c',
      'ksu419: memory.h',
      '#include "asm-generic/fixmap.h"',
      '/* ksu419: memory.h */\n'
      '#include "asm-generic/fixmap.h"\n'
      '#include "asm/memory.h"',
      'memory.h')
PY

echo "==== 3i. compat: ROM without u:r:su:s0 / u:object_r:ksu_file:s0 -- fall back ===="
python3 - <<'PY'
import sys

def patch(p, marker, old, new, tag):
    s = open(p).read()
    if marker in s:
        print('%-16s skip (already patched)' % tag)
        return
    if old not in s:
        sys.exit('!! anchor missing for %s in %s' % (tag, p))
    open(p, 'w').write(s.replace(old, new, 1))
    print('%-16s ok' % tag)

# Most custom ROMs ship no `su` domain (they never needed one), so
# security_secctx_to_secid("u:r:su:s0") returns -EINVAL and KSU's root cred is
# left without a domain -- every later grant fails and the manager reports
# "unsupported". init exists on every Android; fall back to it (same trick
# Magisk uses on non-GKI kernels: the domain only decides which policy applies,
# the uid is still 0).
patch('drivers/kernelsu/selinux/selinux.c',
      'ksu419: sid fallback',
      '    error = security_secctx_to_secid(domain, strlen(domain), &sid);\n'
      '    if (error) {\n'
      '        pr_info("security_secctx_to_secid %s -> sid: %d, error: %d\\n", domain, sid, error);\n'
      '    }',
      '    /* ksu419: sid fallback */\n'
      '    error = security_secctx_to_secid(domain, strlen(domain), &sid);\n'
      '    if (error) {\n'
      '        u32 fb = 0;\n'
      '        if (!security_secctx_to_secid(INIT_CONTEXT, strlen(INIT_CONTEXT), &fb)) {\n'
      '            pr_info("ksu419: %s missing (%d) -> using init sid %u\\n", domain, error, fb);\n'
      '            error = 0;\n'
      '            sid = fb;\n'
      '        }\n'
      '    }\n'
      '    if (error) {\n'
      '        pr_info("security_secctx_to_secid %s -> sid: %d, error: %d\\n", domain, sid, error);\n'
      '    }',
      'su sid fallback')

# Same story for the file label KSU stamps on its own files (/data/adb/ksu/*).
# adb_data_file is what Magisk labels /data/adb with and is present on every
# Android; without a label the allowlist writes fail with -EACCES.
patch('drivers/kernelsu/selinux/selinux.c',
      'ksu419: file sid fallback',
      '    err = security_secctx_to_secid(KSU_FILE_CONTEXT, strlen(KSU_FILE_CONTEXT), &ksu_file_sid);\n'
      '    if (err) {\n'
      '        pr_warn("Failed to cache ksu_file SID: %d\\n", err);\n'
      '        ksu_file_sid = 0;',
      '    /* ksu419: file sid fallback */\n'
      '    err = security_secctx_to_secid(KSU_FILE_CONTEXT, strlen(KSU_FILE_CONTEXT), &ksu_file_sid);\n'
      '    if (err) {\n'
      '        if (!security_secctx_to_secid("u:object_r:adb_data_file:s0", 27, &ksu_file_sid))\n'
      '            pr_info("ksu419: no ksu_file type, using adb_data_file sid %u\\n", ksu_file_sid);\n'
      '    }\n'
      '    if (err && !ksu_file_sid) {\n'
      '        pr_warn("Failed to cache ksu_file SID: %d\\n", err);\n'
      '        ksu_file_sid = 0;',
      'ksu_file fallback')
PY

echo "==== 3j. compat: no su domain -> permissive (cannot inject policy on 4.19) ===="
python3 - <<'PY'
import sys

p = 'drivers/kernelsu/selinux/selinux.c'
s = open(p).read()
if 'ksu419: permissive fallback' in s:
    print('permissive     skip (already patched)')
else:
    old = ('    err = security_secctx_to_secid(KERNEL_SU_CONTEXT, strlen(KERNEL_SU_CONTEXT), &cached_su_sid);\n'
           '    if (err) {\n'
           '        pr_warn("Failed to cache kernel su domain SID: %d\\n", err);\n'
           '        cached_su_sid = 0;\n'
           '    } else {\n')
    new = ('    err = security_secctx_to_secid(KERNEL_SU_CONTEXT, strlen(KERNEL_SU_CONTEXT), &cached_su_sid);\n'
           '    if (err) {\n'
           '        /* ksu419: permissive fallback -- this ROM has no su type and 4.19 cannot take an\n'
           '         * injected policy (the policydb layout differs), so every label/exec check KSU\n'
           '         * relies on is denied (seen: avc denied { execute } for /data/adb/ksu/bin/ksud\n'
           '         * under adb_data_file, init cannot run it). Permissive is the same trade-off\n'
           '         * Magisk makes on non-GKI kernels. */\n'
           '        pr_warn("ksu419: no su domain, switching SELinux to permissive\\n");\n'
           '        setenforce(false);\n'
           '        cached_su_sid = 0;\n'
           '    } else {\n')
    if old not in s:
        sys.exit('!! anchor missing for permissive fallback in ' + p)
    open(p, 'w').write(s.replace(old, new, 1))
    print('permissive     ok')
PY

echo "==== 3k. compat: adopt injected su domain (kernel-driven umh injection) ===="
python3 - <<'PY'
import sys
p = 'drivers/kernelsu/selinux/selinux.c'
s = open(p).read()
if 'ksu419_sid_retry_fn' in s:
    print('sid retry      skip (already patched)')
else:
    if '#include <linux/workqueue.h>' not in s:
        s = s.replace('#include "linux/sched.h"',
                      '#include "linux/sched.h"\n#include <linux/workqueue.h>\n'
                      '#include <linux/jiffies.h>', 1)
    anchor = 'void cache_sid(void)\n{'
    if anchor not in s:
        sys.exit('!! anchor missing for cache_sid in ' + p)
    fn = '''/* ksu419: adopt an injected policy.
 * This ROM has a "su" type but no domain attribute on it, so u:r:su:s0 is an
 * invalid context (-EINVAL) and the kernel cannot build a root cred in the su
 * domain. 4.19 cannot take KernelSU's in-kernel policydb patch, so userspace
 * has to add the missing attributes/allows (magiskpolicy --live). There is no
 * init.rc hook and no module framework on this build, so the kernel fires the
 * injector itself via call_usermodehelper, then re-caches the SID, rebuilds
 * ksu_cred in the su domain and switches back to enforcing.
 */
static void ksu419_sid_retry_fn(struct work_struct *work);
static DECLARE_DELAYED_WORK(ksu419_sid_retry_work, ksu419_sid_retry_fn);
static int ksu419_retry_n;

static void ksu419_sid_retry_fn(struct work_struct *work)
{
    u32 sid = 0;
    u32 fsid = 0;

    if (!security_secctx_to_secid(KERNEL_SU_CONTEXT, strlen(KERNEL_SU_CONTEXT), &sid) && sid) {
        cached_su_sid = sid;
        if (!security_secctx_to_secid(KSU_FILE_CONTEXT, strlen(KSU_FILE_CONTEXT), &fsid) && fsid)
            ksu_file_sid = fsid;
        setup_ksu_cred();
        setenforce(true);
        pr_info("ksu419: su domain adopted (sid %u, ksu_file %u), enforcing again\\n",
                cached_su_sid, ksu_file_sid);
        return;
    }

    ksu419_retry_n++;

    if (ksu419_retry_n < 150)
        queue_delayed_work(system_wq, &ksu419_sid_retry_work, 2 * HZ);
    else
        pr_warn("ksu419: no su domain after retries, staying permissive\\n");
}

'''
    s = s.replace(anchor, fn + anchor, 1)
    old2 = '        setenforce(false);\n        cached_su_sid = 0;\n'
    new2 = ('        setenforce(false);\n'
            '        cached_su_sid = 0;\n'
            '        ksu419_retry_n = 0;\n'
            '        queue_delayed_work(system_wq, &ksu419_sid_retry_work, 2 * HZ);\n')
    if old2 not in s:
        sys.exit('!! anchor missing for retry arming in ' + p)
    s = s.replace(old2, new2, 1)
    open(p, 'w').write(s)
    print('sid retry      ok (umh injector)')
PY

echo "==== 3l. compat: inject policy from init.rc using a valid init domain ===="
python3 - <<'PY'
import sys
p = 'drivers/kernelsu/runtime/ksud_integration.c'
s = open(p).read()
if 'ksu419 injector' in s:
    print('init.rc inject skip (already patched)')
else:
    old = '    "    start logd\\n"\n'
    new = ('    "    start logd\\n"\n'
           '    /* ksu419 injector: valid context, runs before ksud post-fs-data */\n'
           '    "    exec u:r:init:s0 root -- /data/adb/ksu/bin/magiskpolicy --live --apply /data/adb/ksu/bin/ksu_rules.txt\\n"\n')
    if old not in s:
        sys.exit('!! anchor missing for init.rc injector in ' + p)
    open(p, 'w').write(s.replace(old, new, 1))
    print('init.rc inject ok')
PY

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
