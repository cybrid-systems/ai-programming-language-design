# 26-RCU — 读-复制-更新深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**RCU（Read-Copy-Update）** 是一种无锁同步机制，允许多个读者与一个写者并发访问共享数据。读者不需要任何锁（无需原子操作），写者通过"发布新版本 → 等待所有旧读者退出 → 回收旧版本"的流程完成更新。

RCU 的三个核心原语：

| 操作 | 读者 | 写者 |
|------|------|------|
| 读端 | `rcu_read_lock()` / `rcu_read_unlock()` | — |
| 更新 | — | `rcu_assign_pointer()` / `synchronize_rcu()` |
| 回收 | — | `kfree_rcu()` / `call_rcu()` |

doom-lsp 确认 `kernel/rcu/tree.c` 包含约 459+ 个符号，`include/linux/rcupdate.h` 定义了 RCU API。

---

## 1. 核心思想

```
初始状态：共享指针 p → version A

读者（任意多个）：
  rcu_read_lock()
    ptr = rcu_dereference(p)      ← 读取共享指针
    // 使用 ptr...
  rcu_read_unlock()
  // 无需原子操作，无需内存屏障（特定架构）

写者：
  new = alloc_and_init()
  rcu_assign_pointer(p, new)      ← 发布新版本（需要内存屏障）
  synchronize_rcu()               ← 等待所有当前读者退出
  kfree(old)                      ← 安全回收旧版本

在 synchronize_rcu() 之后：
  - 所有在发布前进入的读者已经退出
  - 新读者看到的是 new
  - old 不会再被任何代码路径访问
```

---

## 2. 核心机制：宽限期（Grace Period）

```
时间轴：
  ───────┬──────┬──────────┬──────┬──────→
         │      │          │      │
     任务 A   任务 B   任务 C  任务 D
     rcu_read  rcu_read       rcu_read
     _lock()   _lock()        _lock()
         │      │    synchronize_rcu() ← 等待所有当前读者退出
         │      │    │
         │      │    └─ 直到所有已启动的读端都结束
         │      │
     rcu_read  rcu_read
     _unlock() _unlock()
                        rcu_read
                        _unlock()
                        │
                    ─── 此时 synchronize_rcu() 返回
                    ─── 可以安全回收旧数据
```

---

## 3. 核心 API

```c
// 读者端
rcu_read_lock()              // 标记读端临界区开始
rcu_dereference(p)           // 安全读取 RCU 保护的指针
rcu_read_unlock()            // 标记读端临界区结束

// 写者端
rcu_assign_pointer(p, new)   // 发布新指针
synchronize_rcu()            // 同步等待宽限期（可能阻塞）
synchronize_rcu_expedited()  // 快速版（通过 IPI 强制退出）
call_rcu(&head, callback)    // 异步：宽限期后回调
kfree_rcu(ptr, field)        // 宽限期后释放
```

---

## 4. 数据类型流

```
链表 RCU 保护：
  rcu_read_lock()
    pos = list_for_each_entry_rcu(...)  ← RCU 安全遍历
    // 使用 pos...
  rcu_read_unlock()

  // 写者删除节点：
  list_del_rcu(&pos->list)              ← 从链表移除
  synchronize_rcu()                     ← 等待所有读者退出
  kfree(pos)                            ← 安全释放

Linux 内核中的典型应用：
  ┌─────────────────────────────────────┐
  │ 路由表查找（net/ipv4/fib_trie）      │
  │ dentry cache（fs/dcache.c）          │
  │ file descriptor 表（kernel/fork.c）  │
  │ radix tree 读取                     │
  └─────────────────────────────────────┘
```

---

## 5. 源码文件索引

| 文件 | 关键符号 |
|------|---------|
| `include/linux/rcupdate.h` | RCU API 定义 |
| `include/linux/rcu.h` | 内部接口 |
| `kernel/rcu/tree.c` | tree RCU 实现 |
| `kernel/rcu/srcutree.c` | SRCU（可睡眠 RCU） |

---

*分析工具：doom-lsp（clangd LSP）| 分析日期：2026-05-01 | 内核版本：Linux 7.0-rc1*
