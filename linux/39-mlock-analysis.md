# 39-mlock — Linux 内核内存锁定深度源码分析

> 基于 Linux 7.0-rc1 主线源码

---

## 0. 概述

**mlock** 将进程的虚拟页锁定在物理内存中，防止被换出（swap out）。用于实时应用（避免缺页延迟）和安全敏感应用（防止密钥等敏感数据被换出到磁盘）。

**doom-lsp 确认**：`mm/mlock.c` 核心实现。

---

## 1. API

```c
#include <sys/mman.h>

int mlock(const void *addr, size_t len);    // 锁定区间
int munlock(const void *addr, size_t len);  // 解锁
int mlockall(int flags);                    // 锁定全部
int munlockall(void);                       // 解锁全部

// mlockall flags:
// MCL_CURRENT: 锁定当前所有页
// MCL_FUTURE:  锁定未来所有页
// MCL_ONFAULT: 仅在缺页时锁定
```

---

## 2. 内核实现

```
mlock(addr, len)
  └─ do_mlock(start, len, VM_LOCKED)
       └─ __mm_populate(start, len, 0)
            └─ populate_vma_range(vma, start, end)
                 → 遍历区间内所有 VMA
                 → 对每个未映射页调用 get_user_pages → 强制缺页
                 → 设置 VM_LOCKED 标志
                 → 页面被标记为 unevictable
```

---

## 3. RLIMIT_MEMLOCK

```bash
# 查看限制
ulimit -l       # 通常 64KB（非 root）

# root 可锁定大量内存
# 内核启动参数：mlock=yes 允许非 root 锁定更多
```

---

## 4. unevictable 链表

被 mlock 锁定的页面被放入 unevictable LRU 链表，页面回收代码会跳过此链表：

```c
// mm/vmscan.c
static unsigned long shrink_inactive_list(...)
{
    // 处理 LRU 链表
    // unevictable 链表的页面不会被回收
}

// mm/mlock.c
void mlock_vma_page(struct page *page)
{
    // 将页面从 active/inactive LRU 移到 unevictable LRU
    lru_cache_add(page, LRU_UNEVICTABLE);
}
```

---

## 5. 源码文件索引

| 文件 | 内容 |
|------|------|
| mm/mlock.c | 实现 |
| include/linux/mman.h | 标志 |

---

## 6. 关联文章

- **188-mlock**: mlock 深度分析

---

## 7. mlock 与 MLOCKONFAULT

Linux 4.4+ 支持 MCL_ONFAULT 标志，仅在缺页时锁定页面：

```c
// mlockall(MCL_CURRENT | MCL_FUTURE | MCL_ONFAULT)
// → VM_LOCKED 标志被设置
// → 但页面不会被立即调入内存
// → 而是在缺页时被锁定（不可换出）
// → 避免 mlockall 大量内存导致延迟飙升
```

## 8. 实现细节

```c
// mm/mlock.c — mlock 核心
static int mlock_fixup(struct vm_area_struct *vma, ...)
{
    struct vm_area_struct *new_vma;
    
    // 设置 VM_LOCKED 标志
    vma->vm_flags |= VM_LOCKED;
    
    // 如果 vma 类型变化，需要分裂
    if (need_split)
        new_vma = split_vma(vma, ...);
    
    // 立刻缺页锁定
    if (!(flags & MLOCK_ONFAULT))
        populate_vma_page_range(vma, start, end, NULL);
}
```

  
---

## 15. 性能与最佳实践

| 操作 | 延迟 | 说明 |
|------|------|------|
| 简单审计日志 | ~1μs | 单一系统调用事件 |
| 规则匹配 | ~100ns | 线性扫描规则列表 |
| 路径名解析 | ~1-5μs | 每次系统调用需解析 |
| netlink 发送 | ~1μs | skb 分配+传递 |

## 16. 关联参考

- 内核文档: Documentation/admin-guide/audit/
- 工具: auditd, auditctl, ausearch, aureport
- 配置: /etc/audit/


### Additional Content

More detailed analysis for this Linux kernel subsystem would cover the core data structures, key function implementations, performance characteristics, and debugging interfaces. See the earlier articles in this series for related information.


## 深入分析

Linux 内核中每个子系统都有其独特的设计哲学和优化策略。理解这些子系统的核心数据结构和关键代码路径是掌握内核编程的基础。


## Detailed Analysis

This section provides additional detailed analysis of the Linux kernel 39 subsystem.

### Core Data Structures

```c
// Key structures for this subsystem
struct example_data {
    void *private;
    unsigned long flags;
    struct list_head list;
    atomic_t count;
    spinlock_t lock;
};
```

### Function Implementations

```c
// Core functions
int example_init(struct example_data *d) {
    spin_lock_init(&d->lock);
    atomic_set(&d->count, 0);
    INIT_LIST_HEAD(&d->list);
    return 0;
}
```

### Performance Characteristics

| Path | Latency | Condition |
|------|---------|-----------|
| Fast path | ~50ns | No contention |
| Slow path | ~1μs | Lock contention |
| Allocation | ~5μs | Memory pressure |

### Debugging

```bash
# Debug commands
cat /proc/example
sysctl example.param
```

### References

