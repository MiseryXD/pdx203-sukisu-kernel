#!/bin/bash
# 从 Ultra 版 build.sh 提取的 4.19 兼容补丁集合（3b~3j）
# 由 nova build 脚本在集成 Nova 之后调用。锚点缺失时只打印、不中断。
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

