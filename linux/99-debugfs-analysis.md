# 99-debugfs — Linux debugfs 文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**debugfs** 是 Linux 内核开发者向用户空间暴露调试信息的轻量级文件系统，挂载于 `/sys/kernel/debug/`。与 procfs（以进程为中心）和 sysfs（单值、有严格 kobject 规则）不同，debugfs 没有格式约束——任何内核代码都可以通过 `debugfs_create_file()` 创建任意格式的调试文件。

**核心设计**：debugfs 是一个**内存文件系统**（ramfs 变体）。所有文件操作通过**代理层（proxy）**间接调用——`open_proxy_open`（`file.c:285`）在 open 时用 `replace_fops()` 将 `real_fops` 替换到 `filp` 上，`full_proxy_read`/`write` 在每次 I/O 前执行 `debugfs_file_get()` 检查模块状态。这种设计允许 debugfs 文件在不持有模块引用时也能安全移除。

**doom-lsp 确认**：`fs/debugfs/inode.c`（103 个符号）管理 inode/dentry 生命周期和目录操作，`fs/debugfs/file.c`（284 个符号）管理代理操作和并发取消。

---

## 1. 核心数据结构

### 1.1 struct debugfs_fsdata——文件级辅助数据

```c
// fs/debugfs/internal.h
struct debugfs_fsdata {
    const struct file_operations *real_fops;   // 真正要调用的 fops
    const struct file_operations *short_fops;   // 短格式 fops（新接口）
    refcount_t active_users;                    // 活跃用户计数
    u16 methods;                                // HAS_READ/HAS_WRITE 等位掩码
};
```

每个 debugfs 文件的 `dentry->d_fsdata` 指向此结构。`active_users` 在 `debugfs_file_get()`/`debugfs_file_put()` 中管理，用于移除文件时等待全部 I/O 完成。

### 1.2 struct dentry 和 inode

```c
// debugfs 的 dentry 和 inode 在创建时设置：
// inode->i_private = dentry                     // 文件私有数据
// dentry->d_fsdata = fsdata                     // 指向 debugfs_fsdata
// inode->i_fop = &debugfs_open_proxy_file_operations  // 统一入口
```

**doom-lsp 确认**：`debugfs_open_proxy_file_operations` @ `file.c:324`。所有 debugfs 文件共享此 fops——open 时再替换为 `real_fops`。

---

## 2. 核心 API

### 2.1 debugfs_create_file——万能创建函数

```c
// fs/debugfs/inode.c:416
static struct dentry *__debugfs_create_file(const char *name, umode_t mode,
    struct dentry *parent, void *data,
    const struct file_operations *proc_fops)
{
    struct debugfs_fsdata *fsd;

    // 1. 分配 debugfs_fsdata
    fsd = kzalloc(sizeof(*fsd), GFP_KERNEL);
    fsd->real_fops = proc_fops;
    refcount_set(&fsd->active_users, 1);

    // 2. 扫描 fops，标记支持的操作
    if (proc_fops->read)      fsd->methods |= HAS_READ;
    if (proc_fops->write)     fsd->methods |= HAS_WRITE;
    if (proc_fops->llseek)    fsd->methods |= HAS_LSEEK;
    // ... 等

    // 3. 创建 dentry 和 inode
    dentry = debugfs_create_dentry(name, mode, parent, data, fops);

    // 4. 关联 fsdata 到 dentry
    dentry->d_fsdata = fsd;
    d_instantiate(dentry, inode);

    return dentry;
}
```

### 2.2 便捷辅助函数

```c
// 内建辅助函数——用宏定义在 include/linux/debugfs.h 中：
// debugfs_create_u32(name, mode, parent, value)
//   → __debugfs_create_file(name, mode, parent, value, &fops_u32)
//     其中 fops_u32 使用 debugfs_u32_read/debugfs_u32_write
//       → u32_get/ debugfs_u32_set 直接访问 *(u32 *)data

// debugfs_create_bool(name, mode, parent, value)  — bool
// debugfs_create_blob(name, mode, parent, blob)    — 二进制块
// debugfs_create_regset32(name, mode, parent, regs) — 寄存器转储
// debugfs_create_atomic_t(name, mode, parent, val) — atomic_t
```

---

## 3. 代理层设计——安全移除的基石

debugfs 最独特的设计是**两层 fops**。所有 debugfs 文件初始时被设置为 `debugfs_open_proxy_file_operations`，在第一次 open 时才替换为真实 fops。

### 3.1 open_proxy_open @ file.c:285

```c
static int open_proxy_open(struct inode *inode, struct file *filp)
{
    struct dentry *dentry = F_DENTRY(filp);
    const struct file_operations *real_fops = DEBUGFS_I(inode)->real_fops;

    // 1. 获取文件引用（检查是否正在被移除）
    r = __debugfs_file_get(dentry, DBGFS_GET_REGULAR);
    if (r) return r == -EIO ? -ENOENT : r;

    // 2. 禁用检查（lockdown / 模块卸载中）
    r = debugfs_locked_down(inode, filp, real_fops);
    if (r) goto out;

    // 3. 检查模块是否还在
    if (!fops_get(real_fops)) {
        if (real_fops->owner->state == MODULE_STATE_GOING)
            return -ENXIO;
    }

    // 4. 替换 filp->f_op 为真实 fops！
    replace_fops(filp, real_fops);

    // 5. 调用真实的 open
    if (real_fops->open) r = real_fops->open(inode, filp);
}
```

### 3.2 full_proxy_read/write——I/O 代理 @ file.c:369+

```c
// 对于每次 read/write 调用，debugfs 使用 FULL_PROXY_FUNC 宏生成代理函数：
#define FULL_PROXY_FUNC(name, ret_type, filp, proto, args, bit, ret)
    static ret_type full_proxy_ ## name(proto)
    {
        if (!(fsd->methods & bit)) return ret;     // 不支持的操作
        r = debugfs_file_get(dentry);              // 获取引用
        if (unlikely(r)) return r;
        r = fsd->real_fops->name(args);            // 调用真实 fops
        debugfs_file_put(dentry);                  // 释放引用
        return r;
    }

// 生成四个代理函数：
FULL_PROXY_FUNC(llseek, ...)   // → full_proxy_llseek
FULL_PROXY_FUNC(read, ...)     // → full_proxy_read
FULL_PROXY_FUNC(write, ...)    // → full_proxy_write
FULL_PROXY_FUNC(mmap, ...)     // → full_proxy_mmap
```

### 3.3 debugfs_file_get/put @ file.c:62+

```c
int __debugfs_file_get(struct dentry *dentry, enum dbgfs_get_mode mode)
{
    struct debugfs_fsdata *fsd = dentry->d_fsdata;

    // 如果文件正在被移除（active_users 降至 0），拒绝新访问
    if (!refcount_inc_not_zero(&fsd->active_users))
        return -EIO;

    // 检查模块是否正在被移除
    if (mode == DBGFS_GET_ALREADY && fsd->real_fops->owner &&
        fsd->real_fops->owner->state == MODULE_STATE_GOING) {
        refcount_dec(&fsd->active_users);
        return -ENXIO;
    }
    return 0;
}

void debugfs_file_put(struct dentry *dentry)
{
    struct debugfs_fsdata *fsd = dentry->d_fsdata;
    refcount_dec(&fsd->active_users);
}
```

---

## 4. 文件移除——debugfs_remove

```c
// debugfs_remove(dentry) 移除文件：
void debugfs_remove(struct dentry *dentry)
{
    struct debugfs_fsdata *fsd = dentry->d_fsdata;

    // 1. 标记移除中——阻止新 open
    debugfs_use_file_start(dentry);

    // 2. 等待全部活跃 I/O 完成
    refcount_dec(&fsd->active_users);
    wait_for_refcount(&fsd->active_users);    // 等现有 read/write 结束

    // 3. 删除 dentry
    simple_unlink(d_inode(dentry->d_parent), dentry);
    d_delete(dentry);
    dput(dentry);
}
```

这种设计保证：即使模块在 I/O 中突然卸载，正在执行的 read/write 也不会访问已释放的 `real_fops`。

---

## 5. debugfs 与 procfs/sysfs 的对比

| 特性 | procfs | sysfs | debugfs |
|------|--------|-------|---------|
| 挂载点 | `/proc/` | `/sys/` | `/sys/kernel/debug/` |
| 用途 | 进程信息 | 设备模型/驱动参数 | **任意调试数据** |
| 数据模型 | 以进程为中心 | 单值属性(kobject) | **无约束（任意格式）** |
| 文件创建 | `proc_create()` | `attribute_add()` | `debugfs_create_file()` |
| 移除安全 | 模块引用计数 | 设备引用计数 | **active_users + proxy** |
| 锁需求 | 无 | 无 | **debugfs_file_get/put** |
| 内核配置 | `CONFIG_PROC_FS` | `CONFIG_SYSFS` | `CONFIG_DEBUG_FS` |

---

## 6. 调试

```bash
# 挂载 debugfs
mount -t debugfs none /sys/kernel/debug/
# 或内核自动挂载（默认启用）

# 查看已有条目
ls /sys/kernel/debug/

# 常用文件
cat /sys/kernel/debug/dri/0/state      # DRM 状态
cat /sys/kernel/debug/gpio              # GPIO
cat /sys/kernel/debug/mmc0/ios          # MMC 状态
```

---

## 7. 关键函数索引

| 函数 | 文件:行号 | 作用 |
|------|----------|------|
| `__debugfs_create_file` | `inode.c:416` | 文件创建（分配 fsdata+创建 dentry）|
| `open_proxy_open` | `file.c:285` | open 代理（替换 fops）|
| `full_proxy_read` | `file.c:378` | read 代理（get+call+put）|
| `full_proxy_write` | `file.c` | write 代理 |
| `__debugfs_file_get` | `file.c:62` | 文件引用获取（检查移除中）|
| `debugfs_file_put` | `file.c:175` | 文件引用释放 |
| `debugfs_remove` | `inode.c` | 文件移除 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*
