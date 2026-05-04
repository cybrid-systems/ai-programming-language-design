# 098-debugfs — Linux debugfs 文件系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**debugfs** 是 Linux 内核开发者向用户空间暴露调试信息的轻量级文件系统（挂载于 `/sys/kernel/debug/`）。与 procfs（以进程为中心）和 sysfs（单值、有严格 kobject 规则）不同，debugfs **没有格式约束**——任何内核代码可以通过 `debugfs_create_file()` + 自定义 `struct file_operations` 暴露任意格式的调试数据。

**核心设计**：debugfs 的文件操作通过**分层代理**间接调用。所有文件初始时被设置为 `debugfs_open_proxy_file_operations`，在第一次 `open` 时通过 `open_proxy_open`（`file.c:285`）用 `replace_fops()` 替换为真实 fops。每次 `read`/`write` 前通过 `debugfs_file_get()`（`file.c:175`）获取引用——如果文件正在被移除，则拒绝新访问。这种两层的设计让 debugfs 可以在不持有模块引用计数的情况下**安全移除文件**。

```
文件创建：                       文件读写（代理层）：
debugfs_create_file()             用户 read → full_proxy_read()
  → alloc_fsd()                     → debugfs_file_get()  获取引用
  → 创建 dentry                     如果 active_users==0 → 返回 -EIO
  → d_fsdata = fsd                 → real_fops->read()   调用真实函数
  → fops = proxy_fops              → debugfs_file_put()  释放引用

文件移除：
debugfs_remove()
  → 标记 dentry 为 unlinked
  → refcount_dec(&active_users)
  → wait_for_completion(&active_users_drained)
  → 删除 dentry
```

**doom-lsp 确认**：`fs/debugfs/inode.c`（103 符号）管理 inode/dentry 生命周期。`fs/debugfs/file.c`（284 符号）管理代理操作和引用计数。`__debugfs_file_get` @ `file.c:62`，`open_proxy_open` @ `file.c:285`。

---

## 1. 核心数据结构

### 1.1 struct debugfs_fsdata——文件元数据

```c
// fs/debugfs/internal.h
struct debugfs_fsdata {
    const struct file_operations *real_fops;   // 完整 fops（旧接口）
    const struct file_operations *short_fops;  // 精简 fops（新接口）
    refcount_t active_users;                    // 活跃用户计数
    struct completion active_users_drained;     // 等待全部 I/O 完成
    u16 methods;                                // HAS_READ/WRITE/LSEEK 等位掩码
    struct list_head cancellations;             // 取消请求链表
    struct mutex cancellations_mtx;             // 保护取消链表
};
```

**设计要点**：
- `active_users` 初始为 1，`debugfs_file_get()` 递增，`debugfs_file_put()` 递减
- 移除文件时 `refcount_dec(&active_users)` → 等待降至 0（现有 I/O 完成后）
- `real_fops` vs `short_fops`：旧接口传递完整 `struct file_operations`，新接口传递 `struct debugfs_short_fops`（精简版），在 `__debugfs_file_get` 中根据 `mode` 参数区分

**doom-lsp 确认**：`__debugfs_file_get` @ `file.c:62`，`active_users_drained` 在 `file.c:112` 通过 `init_completion` 初始化。

### 1.2 延迟初始化——cmpxchg 竞态处理

```c
// __debugfs_file_get @ file.c:62 中：
// fsd 不在 dentry 上时延迟分配（首次 open 时）：
d_fsd = READ_ONCE(dentry->d_fsdata);
if (!d_fsd) {
    // 首次访问——分配 fsd
    fsd = kzalloc(sizeof(*fsd), GFP_KERNEL);
    if (mode == DBGFS_GET_SHORT)
        fsd->short_fops = DEBUGFS_I(inode)->short_fops;
    else
        fsd->real_fops = DEBUGFS_I(inode)->real_fops;

    // cmpxchg——并发安全：只有一个线程的 fsd 被写入
    d_fsd = cmpxchg(&dentry->d_fsdata, NULL, fsd);
    if (d_fsd) {
        // 另一个线程先写了 — 释放本地的
        kfree(fsd);
        fsd = d_fsd;
    }
}
if (d_unlinked(dentry)) return -EIO;  // 文件已移除
if (!refcount_inc_not_zero(&fsd->active_users)) return -EIO;
```

---

## 2. 文件创建路径

### 2.1 __debugfs_create_file @ inode.c:416

```c
static struct dentry *__debugfs_create_file(const char *name, umode_t mode,
    struct dentry *parent, void *data,
    const struct file_operations *proc_fops)
{
    // 1. 分配 fsd（此处只存 fops，不设置 active_users）
    fsd = kzalloc(sizeof(*fsd), GFP_KERNEL);
    fsd->real_fops = proc_fops;
    if (proc_fops->read)   fsd->methods |= HAS_READ;
    if (proc_fops->write)  fsd->methods |= HAS_WRITE;
    // ...
    // 注意：此时 active_users 未初始化！留给 __debugfs_file_get 延迟创建

    // 2. 创建 dentry 和 inode
    dentry = debugfs_create_dentry(name, mode, parent, data, &debugfs_open_proxy_file_operations);
    // inode->i_fop = proxy_fops（所有 debugfs 文件统一入口）
    // dentry->d_fsdata = fsd

    d_instantiate(dentry, inode);
    return dentry;
}
```

### 2.2 debugfs_create_dir @ inode.c:570

```c
struct dentry *debugfs_create_dir(const char *name, struct dentry *parent)
{
    // 创建目录 dentry
    dentry = debugfs_create_dentry(name, S_IFDIR | 0755, parent, NULL, &simple_dir_operations);
    inode->i_op = &debugfs_dir_inode_operations;   // 目录 inode 操作
    return dentry;
}
```

---

## 3. 代理层——四类代理函数

### 3.1 open_proxy_open @ file.c:285

```c
static int open_proxy_open(struct inode *inode, struct file *filp)
{
    // 1. 获取文件引用（触发 fsd 延迟初始化）
    r = __debugfs_file_get(dentry, DBGFS_GET_REGULAR);
    if (r) return r == -EIO ? -ENOENT : r;

    // 2. 锁定检查（lockdown / 模块状态）
    r = debugfs_locked_down(inode, filp, real_fops);
    if (r) goto out;

    // 3. 检查模块是否存活（确保模块未卸载）
    if (!fops_get(real_fops)) {
        if (real_fops->owner->state == MODULE_STATE_GOING)
            return -ENXIO;
    }

    // 4. 替换 filp->f_op 为真正 fops
    replace_fops(filp, real_fops);

    // 5. 调真实 open
    if (real_fops->open) r = real_fops->open(inode, filp);
    debugfs_file_put(dentry);
}
```

### 3.2  FULL/SHORT_PROXY_FUNC——宏生成器 @ file.c:355-390

```c
// FULL_PROXY_FUNC：为旧接口（full file_operations）生成代理
#define FULL_PROXY_FUNC(name, ret_type, filp, proto, args, bit, ret)
    static ret_type full_proxy_ ## name(proto) {
        if (!(fsd->methods & bit)) return ret;       // 不支持→默认返回值
        r = debugfs_file_get(dentry);                // 获取引用
        if (unlikely(r)) return r;
        r = fsd->real_fops->name(args);              // 调真实函数
        debugfs_file_put(dentry);
        return r;
    }

// SHORT_PROXY_FUNC：为新接口（debugfs_short_fops）生成代理
#define SHORT_PROXY_FUNC(name, ret_type, filp, proto, args, bit, ret)
    static ret_type short_proxy_ ## name(proto) {
        if (!(fsd->methods & bit)) return ret;
        r = debugfs_file_get(dentry);
        if (unlikely(r)) return r;
        r = fsd->short_fops->name(args);              // 调精简 fops
        debugfs_file_put(dentry);
        return r;
    }

// 生成的 8 个代理函数：
FULL_PROXY_FUNC(llseek, ...) → full_proxy_llseek
FULL_PROXY_FUNC(read, ...)   → full_proxy_read
FULL_PROXY_FUNC(write, ...)  → full_proxy_write
FULL_PROXY_FUNC(mmap, ...)   → full_proxy_mmap
SHORT_PROXY_FUNC(llseek, ...)→ short_proxy_llseek
SHORT_PROXY_FUNC(read, ...)  → short_proxy_read
SHORT_PROXY_FUNC(write, ...) → short_proxy_write
```

---

## 4. 文件移除——debugfs_remove

```c
// 移除文件路径：
// debugfs_remove(dentry)
// → simple_unlink + d_delete (debugfs 核心)
// → 之后 d_fsdata->active_users 会阻止新 I/O
// → 等待已有 I/O 完成

// 关键在于：debugfs_remove 将 dentry 标记为 unlinked，
// 而 __debugfs_file_get 会在 d_unlinked(dentry) 时返回 -EIO

// 调用者通常不需要显式等待，debugfs_remove 内部通过
// active_users_drained completion 同步
```

---

## 5. 取消机制——debugfs_enter_cancellation @ file.c:206

```c
// 某些 debugfs 操作需要等待外部事件（如用户空间返回结果）
// 取消机制允许在移除文件时中断等待：
void debugfs_enter_cancellation(struct file *file,
                                 struct debugfs_cancellation *canc)
{
    // 将 canc 添加到 fsd->cancellations 链表
    // 移除时遍历链表 → complete() 所有等待者
}

void debugfs_leave_cancellation(struct file *file,
                                 struct debugfs_cancellation *canc)
{
    // 从链表移除
}
```

---

## 6. debugfs 与 procfs/sysfs 的对比

| 特性 | procfs | sysfs | debugfs |
|------|--------|-------|---------|
| 挂载点 | `/proc/` | `/sys/` | `/sys/kernel/debug/` |
| 用途 | 进程信息 | 设备模型/驱动参数 | **任意调试数据** |
| 数据模型 | 以进程为中心 | 单值属性(kobject) | **无约束** |
| fops 机制 | 直接使用 | 通过 sysfs_ops 转发 | **代理层（proxy）+ active_users** |
| 移除安全 | 模块引用计数 | 设备引用计数 | **active_users + completion** |
| 取消机制 | 无 | 无 | **debugfs_enter_cancellation** |

---

## 7. 关键函数索引

| 函数 | 文件:行号 | 作用 |
|------|----------|------|
| `__debugfs_create_file` | `inode.c:416` | 创建文件（分配 fsd + dentry）|
| `debugfs_create_dir` | `inode.c:570` | 创建目录 |
| `open_proxy_open` | `file.c:285` | open 代理（替换 fops + 检查状态）|
| `full_proxy_read` | `file.c:378` | 完整 read 代理（get+call+put）|
| `short_proxy_read` | `file.c:373` | 精简 read 代理 |
| `__debugfs_file_get` | `file.c:62` | 懒初始化 fsd + 获取引用 |
| `debugfs_file_put` | `file.c:175` | 释放引用 + complete 等待者 |
| `debugfs_enter_cancellation` | `file.c:206` | 注册取消回调 |
| `debugfs_leave_cancellation` | `file.c:242` | 注销取消回调 |

---

## 8. 总结

debugfs 的核心设计是**代理层 + 引用计数安全移除**。`__debugfs_create_file`（`inode.c:416`）分配 `debugfs_fsdata` 并设置为 `proxy_fops`。每次 I/O 前的 `__debugfs_file_get`（`file.c:62`）使用 cmpxchg 实现 fsd 的延迟初始化，`refcount_inc_not_zero` 与 `d_unlinked` 双重检查保证移除安全。`FULL_PROXY_FUNC`/`SHORT_PROXY_FUNC` 宏生成器（`file.c:355-390`）为 `real_fops` 和 `short_fops` 两种接口生成对应的代理函数。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 内核版本：Linux 7.0-rc1*

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `debugfs_create_file()` | fs/debugfs/inode.c | 文件创建 |
| `debugfs_create_dir()` | fs/debugfs/inode.c | 目录创建 |
| `debugfs_remove()` | fs/debugfs/inode.c | 删除 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
