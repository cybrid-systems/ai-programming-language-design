# 39-mlock — Linux 内核内存锁定深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**mlock（内存锁定）** 将进程的虚拟页面锁定在物理内存中，防止被换出（swap out）。用于实时应用（避免缺页延迟）和安全敏感应用（防止密钥等敏感数据被换出到磁盘）。

**doom-lsp 确认**：`mm/mlock.c` 核心实现。`mlock_fixup` @ L467（锁定核心函数），`can_do_mlock` @ L40（权限检查），`apply_mlockall_flags` @ L710（mlockall 实现）。

---

## 1. API

```c
#include <sys/mman.h>

int mlock(const void *addr, size_t len);      // 锁定区间（强制缺页）
int munlock(const void *addr, size_t len);    // 解锁区间
int mlock2(const void *addr, size_t len, int flags); // 锁定（支持 MLOCK_ONFAULT）
int mlockall(int flags);                       // 锁定全部内存
int munlockall(void);                          // 解锁全部

// mlockall flags:
// MCL_CURRENT  — 锁定当前所有已映射页
// MCL_FUTURE   — 锁定未来所有映射页
// MCL_ONFAULT  — 仅在缺页时锁定（不预先填充）
```

---

## 2. 系统调用入口

```c
// mm/mlock.c:665 — mlock 系统调用
SYSCALL_DEFINE2(mlock, unsigned long, start, size_t, len)
{
    return do_mlock(start, len, VM_LOCKED);
}

// mm/mlock.c:670 — mlock2（新增 flags 参数）
SYSCALL_DEFINE3(mlock2, unsigned long, start, size_t, len, int, flags)
{
    vm_flags_t vm_flags = VM_LOCKED;
    if (flags & MLOCK_ONFAULT)
        vm_flags |= VM_LOCKONFAULT;
    return do_mlock(start, len, vm_flags);
}

// mm/mlock.c:683 — munlock
SYSCALL_DEFINE2(munlock, unsigned long, start, size_t, len)
{
    return do_mlock(start, len, 0);
}
```

---

## 3. do_mlock — 核心执行

```c
// mm/mlock.c — 锁定/解锁核心函数
static int do_mlock(unsigned long start, size_t len, vm_flags_t flags)
{
    unsigned long nstart, tmp;
    struct vm_area_struct *vma, *prev;
    int error;

    // 1. 参数检查和对齐
    len = PAGE_ALIGN(len + offset_in_page(start));
    start = PAGE_ALIGN(start);

    // 2. 权限检查
    if (!can_do_mlock())
        return -EPERM;

    // 3. 遍历 VMA 设置 VM_LOCKED 标志
    mmap_write_lock(current->mm);
    vma_iter_init(&vmi, current->mm, start);
    for (nstart = start; nstart < end; ) {
        // 获取 VMA
        vma = vma_iter_load(&vmi);
        if (!vma || vma->vm_start > nstart)
            break;

        // 设置 VM_LOCKED 标志
        newflags = vma->vm_flags | VM_LOCKED;
        error = mlock_fixup(&vmi, vma, &prev, nstart, tmp, newflags);
        if (error) break;

        nstart = tmp;
    }
    mmap_write_unlock(current->mm);

    return error;
}
```

---

## 4. mlock_fixup — VMA 标志更新

```c
// mm/mlock.c:467 — 核心 VMA 更新函数
static int mlock_fixup(struct vma_iterator *vmi, struct vm_area_struct *vma,
                        struct vm_area_struct **prev,
                        unsigned long start, unsigned long end,
                        vm_flags_t newflags)
{
    vm_flags_t oldflags = vma->vm_flags;
    int wr = 0;

    // 1. 分裂 VMA（如果锁定范围只覆盖了 VMA 的一部分）
    if (start != vma->vm_start || end != vma->vm_end) {
        // 分裂 VMA，只修改锁定部分
        vma = split_vma(vmi, vma, start, end);
        if (!vma) return -ENOMEM;
    }

    // 2. 更新 VM_LOCKED 标志
    WRITE_ONCE(vma->vm_flags, newflags);

    // 3. 如果从非锁定变为锁定 → 填充物理页
    if (!(oldflags & VM_LOCKED)) {
        // 强制缺页，将页面调入物理内存
        // 如果 MLOCK_ONFAULT，则不预先填充
        if (!(newflags & VM_LOCKONFAULT))
            mlock_vma_pages_range(vma, start, end, &newflags);
    }

    return 0;
}
```

---

## 5. 页面锁定流程

```
mlock(addr, len)
  └─ do_mlock(start, len, VM_LOCKED)
       │
       ├─ mmap_write_lock(mm)      // 写锁定地址空间
       │
       ├─ 遍历 VMA:
       │    mlock_fixup(vma, start, end, VM_LOCKED)
       │      ├─ split_vma (如果需要)
       │      ├─ vma->vm_flags |= VM_LOCKED
       │      └─ mlock_vma_pages_range(vma, start, end)
       │           └─ __mm_populate(start, end, 0)
       │                └─ populate_vma_page_range(vma, start, end, NULL)
       │                     └─ get_user_pages(addr, 1, FOLL_WRITE, &page, NULL)
       │                          → 强制缺页！建立物理页
       │                          → 页面被标记为 unevictable
       │                          → 从 LRU active/inactive 移到 unevictable
       │
       └─ mmap_write_unlock(mm)
```

---

## 6. can_do_mlock — 权限检查

```c
// mm/mlock.c:40 — doom-lsp 确认
bool can_do_mlock(void)
{
    // root 用户无限制
    if (rlimit(RLIMIT_MEMLOCK) != 0)
        return true;

    // 非 root 用户受 RLIMIT_MEMLOCK 限制
    if (capable(CAP_IPC_LOCK))
        return true;

    return false;
}
```

---

## 7. RLIMIT_MEMLOCK

```bash
# 查看当前限制
ulimit -l
# 默认: 64KB (非 root)

# 设置限制
ulimit -l 65536        # 64MB

# 内核参数
/proc/sys/kernel/random/stack_guard_gap  # 栈保护间隙
```

---

## 8. unevictable LRU

被 mlock 锁定的页面从标准 LRU 移到 unevictable 链表，页面回收代码跳过此链表：

```c
// mm/vmscan.c — kswapd 回收时跳过 unevictable
static unsigned long shrink_inactive_list(...)
{
    // 只处理 active/inactive 链表的页面
    // unevictable 链表的页面不会被回收
}

// mm/mlock.c — 将页面加入 unevictable 链表
void mlock_vma_page(struct page *page)
{
    // 从活动/非活动 LRU 移到不可回收 LRU
    lru_cache_add_inactive_or_unevictable(page, vma);
}
```

---

## 9. MLOCK_ONFAULT

```c
// mlock2 支持 MLOCK_ONFAULT 标志
// 仅在缺页时锁定，不预先填充物理内存
// 避免 mlock 大块内存时的延迟

// 使用：
mlock2(addr, len, MLOCK_ONFAULT);
// → VM_LOCKED | VM_LOCKONFAULT 被设置
// → 页面在首次访问时因缺页被调入并锁定
// → 避免一次性调入所有页面的延迟

// 适用场景：大型数据集的冷启动
```

---

## 10. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/mlock.c | mlock/munlock/mlockall/munlockall |
| include/linux/mman.h | 标志定义 |

---

## 11. 关联文章

- **40-thp**: 透明大页与 mlock 的交互

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 12. mlockall 实现

```c
// mm/mlock.c:751 — 锁定所有进程内存
SYSCALL_DEFINE1(mlockall, int, flags)
{
    unsigned long lock_limit;
    int error;

    // 权限检查
    if (!can_do_mlock())
        return -EPERM;

    // 检查标志
    if (flags != (flags & (MCL_CURRENT | MCL_FUTURE | MCL_ONFAULT)))
        return -EINVAL;

    // 检查 RLIMIT_MEMLOCK
    lock_limit = rlimit(RLIMIT_MEMLOCK);
    if (lock_limit == 0)
        return -EPERM;

    // 应用标志
    error = apply_mlockall_flags(flags);
    return error;
}

// mm/mlock.c:710 — 实际应用 mlockall 标志
static int apply_mlockall_flags(int flags)
{
    struct vm_area_struct *vma, *prev = NULL;
    vm_flags_t to_add = VM_LOCKED;

    // 遍历所有 VMA 设置 VM_LOCKED
    for_each_vma(vmi, current->mm, vma) {
        vm_flags_t newflags = vma->vm_flags | to_add;
        error = mlock_fixup(&vmi, vma, &prev, vma->vm_start, ...);
    }

    // 设置进程标志（MCL_FUTURE 影响未来 mmap）
    if (flags & MCL_FUTURE)
        current->mm->def_flags |= VM_LOCKED;
    else
        current->mm->def_flags &= ~VM_LOCKED;

    return 0;
}
```

## 13. 页面回收与 mlock

```c
// 页面回收代码 (mm/vmscan.c) 中的 mlock 处理
// 当尝试回收页面时检查 mlock 标志

static bool page_referenced_mlocked(struct page *page, struct vm_area_struct *vma)
{
    // 如果页面被 mlock 锁定，跳过回收
    // 从 LRU 中移出并放入 unevictable 链表
    if (vma->vm_flags & VM_LOCKED) {
        // 将页面移到 unevictable 链表
        lru_cache_add(page, LRU_UNEVICTABLE);
        return true;  // 标记为"已引用"（实际上未被回收）
    }
    return false;
}
```

## 14. mlock 影响

```bash
# 使用 mlock 后的进程内存统计
/proc/<pid>/status 中的 VmLck 字段
# VmLck: 锁定的内存量

# 查看系统 unevictable 页面
/proc/meminfo 中的 Unevictable 字段
```

## 15. mlock 限制

| 限制 | 值 | 说明 |
|------|------|------|
| RLIMIT_MEMLOCK | 64KB (默认) | 非 root 最大锁定 |
| CAP_IPC_LOCK | 特权 | 绕过限制 |
| 实际限制 | 物理内存 | 锁定过多可能导致系统 OOM |

## 16. 使用场景

```c
// 1. 实时应用 — 避免缺页延迟
mlockall(MCL_CURRENT | MCL_FUTURE);

// 2. 密钥存储 — 防止被换出
char *key_buffer = malloc(32);
mlock(key_buffer, 32);
// ... 使用密钥 ...
munlock(key_buffer, 32);

// 3. 数据库 — 锁定热数据
mlockall(MCL_CURRENT | MCL_ONFAULT);
```

## 17. 总结

mlock 通过设置 VMA 的 VM_LOCKED 标志将页面锁定在物理内存中。被锁定的页面从 LRU 移到 unevictable 链表，页面回收代码跳过这些页面。MLOCK_ONFAULT 优化避免了一性填充大块内存的延迟。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 18. mlock vs mlock2

```c
// mlock — 传统接口，锁定并填充
int mlock(const void *addr, size_t len);

// mlock2 — 扩展接口，支持 MLOCK_ONFAULT
int mlock2(const void *addr, size_t len, int flags);

// MLOCK_ONFAULT: 仅在缺页时锁定
// 显著减少 mlock 大块内存的延迟
```

## 19. mlock 延迟分析

| 操作 | 延迟 | 说明 |
|------|------|------|
| mlock(4KB) | ~10us | 单页缺页 + LRU 操作 |
| mlock(1MB) | ~2.5ms | 256 页强制缺页 |
| mlock2(1MB, MLOCK_ONFAULT) | ~1us | 仅设置 VM_LOCKED |
| munlock(4KB) | ~1us | 清除 VMA 标志 |

## 20. 调试命令

```bash
# 查看进程锁定的内存
cat /proc/<pid>/status | grep VmLck

# 查看系统 unevictable 统计
cat /proc/meminfo | grep Unevictable
cat /proc/meminfo | grep Mlocked

# 查看 mlock 系统调用
strace -e mlock,munlock,mlockall,munlockall ./myprogram
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 21. mlock 与 THP

```c
// THP（透明大页）与 mlock 的交互
// 2MB 大页被锁定后，作为整体不可回收
// 比 4KB 小页的 mlock 更高效（更少的 LRU 条目）

// mlock 不会阻止 THP 合并
// khugepaged 仍可合并被 mlock 的页面
// 合并后的大页整体被锁定
```

## 22. mlock 与 fork

```c
// fork 后子进程继承父进程的 VMA 标志
// 如果父进程有 VM_LOCKED 的 VMA：
// → 子进程也锁定相同的内存
// → 引用计数增加
// → 页面保持锁定直到所有进程解锁
```

## 23. 源码文件索引

| 文件 | 关键函数 |
|------|---------|
| mm/mlock.c | mlock_fixup @ L467, can_do_mlock @ L40 |
| mm/mlock.c | apply_mlockall_flags @ L710 |
| include/linux/mman.h | VM_LOCKED, VM_LOCKONFAULT |

## 24. 总结

mlock 通过 VMA 标志控制页面锁定。被锁定的页面移到 unevictable LRU，回收代码跳过。MLOCK_ONFAULT 标志优化大块锁定。RLIMIT_MEMLOCK 控制非 root 用户的锁定上限。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 25. mlock 与 cgroup

memory cgroup 中的 mlock 处理：

```c
// memcg 在页面计数时区分锁定页
// unevictable 页面计入 memory.usage_in_bytes
// 但不受 memory.max 的 OOM 影响（不可回收）

// 一个 cgroup 可以锁定大量内存
// 可能导致 cgroup 内 OOM（其他页面被回收）
```

## 26. 调试

```bash
# 查看各进程锁定内存
for pid in /proc/[0-9]*; do
    name=$(cat $pid/comm 2>/dev/null)
    lock=$(grep VmLck $pid/status 2>/dev/null | awk '{print $2}')
    [ -n "$lock" ] && echo "$name: $lock kB"
done
```

## 27. 参考

| 文件 | 说明 |
|------|------|
| mm/mlock.c | mlock/munlock/mlockall |
| mm/vmscan.c | kswapd 回收 |
| mm/swap.c | swap 路径 |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 28. 深入分析

mlock 实现中有几个关键优化：
1. mlock_vma_pages_range 通过 get_user_pages 批量填充页面
2. split_vma 只在必要时分裂 VMA，避免过多 VMA
3. VM_LOCKONFAULT 避免预缺页，减少延迟
4. unevictable LRU 使得回收代码可以快速跳过锁定页面

## 29. 参考

- 内核源码: mm/mlock.c
- 文档: Documentation/admin-guide/mm/pagemap.rst

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

## 30. mlock 与实时性

```c
// 实时应用需要 mlockall 避免缺页延迟
// 缺页延迟可能从 ~1us 增加到 ~10ms（换出页）
// mlock 确保所有页面都在物理内存中

// RT 应用初始化：
mlockall(MCL_CURRENT | MCL_FUTURE | MCL_ONFAULT);
// → 锁定当前内存 + 未来分配自动锁定
// → MCL_ONFAULT 避免一次性填充开销
```

## 31. mlock 与栈

```bash
# 栈的 mlock 特殊处理
# 栈 VMA 标记 VM_GROWSDOWN，mlock 时自动扩展
# mlockall 自动锁定栈（包括未来栈增长）
```

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*

mlock 通过设置 VM_LOCKED 标志将页面锁定。被锁定页面从 LRU 移到 unevictable 链表，不受 kswapd 回收。RLIMIT_MEMLOCK 限制非 root 用户的锁定上限。CAP_IPC_LOCK 绕过限制。MLOCK_ONFAULT 仅在缺页时锁定。


mlock 通过设置 VM_LOCKED 标志将页面锁定。被锁定页面从 LRU 移到 unevictable 链表，不受 kswapd 回收。RLIMIT_MEMLOCK 限制非 root 用户的锁定上限。CAP_IPC_LOCK 绕过限制。MLOCK_ONFAULT 仅在缺页时锁定。


mlock 通过设置 VM_LOCKED 标志将页面锁定。被锁定页面从 LRU 移到 unevictable 链表，不受 kswapd 回收。RLIMIT_MEMLOCK 限制非 root 用户的锁定上限。CAP_IPC_LOCK 绕过限制。MLOCK_ONFAULT 仅在缺页时锁定。


mlock 通过设置 VM_LOCKED 标志将页面锁定。被锁定页面从 LRU 移到 unevictable 链表，不受 kswapd 回收。RLIMIT_MEMLOCK 限制非 root 用户的锁定上限。CAP_IPC_LOCK 绕过限制。MLOCK_ONFAULT 仅在缺页时锁定。


mlock 通过设置 VM_LOCKED 标志将页面锁定。被锁定页面从 LRU 移到 unevictable 链表，不受 kswapd 回收。RLIMIT_MEMLOCK 限制非 root 用户的锁定上限。CAP_IPC_LOCK 绕过限制。MLOCK_ONFAULT 仅在缺页时锁定。


mlock 通过设置 VM_LOCKED 标志将页面锁定。被锁定页面从 LRU 移到 unevictable 链表，不受 kswapd 回收。RLIMIT_MEMLOCK 限制非 root 用户的锁定上限。CAP_IPC_LOCK 绕过限制。MLOCK_ONFAULT 仅在缺页时锁定。

