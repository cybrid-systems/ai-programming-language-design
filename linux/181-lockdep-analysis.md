# 181-lockdep — 锁依赖追踪深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/locking/lockdep.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**lockdep** 是 Linux 内核的死锁检测器，通过追踪锁的获取顺序，构建有向图，检测循环等待、非法递归等死锁场景。

---

## 1. 锁分类

```c
// 锁类型（lock_class）：
//   .raw_spinlock_t    — 原始自旋锁
//   .spinlock_t        — 自旋锁（禁用抢占）
//   .rwlock_t          — 读写锁
//   .mutex             — 互斥锁
//   .rwsem            — 读写信号量
//   .ww_mutex         — 写时拥有互斥锁
```

---

## 2. lock_chain — 锁链

```c
// lockdep 追踪每个 CPU 的锁获取序列：
// lock_chain[cpu_id][depth] = lock_class_id

// 例如 CPU0 的锁获取序列：
//   spin_lock(&lock_A)      → depth 0
//   spin_lock(&lock_B)      → depth 1
//   spin_lock(&lock_C)      → depth 2
//   unlock(&lock_C)          → depth 1
//   unlock(&lock_B)          → depth 0
```

---

## 3. 死锁检测

```
lockdep 检测的死锁类型：

1. 递归死锁（不可重入）：
   spin_lock(&lock); spin_lock(&lock);  // 同一锁两次

2. 顺序死锁（A→B，B→A）：
   CPU0: lock_A → lock_B
   CPU1: lock_B → lock_A

3. 链式死锁（A→B→C→A）：
   每个 CPU 按不同顺序获取 A、B、C
```

---

## 4. proc 接口

```bash
# 查看锁依赖：
cat /proc/lock_stat

# 启用锁统计：
echo 1 > /proc/sys/kernel/lock_stat

# 查看死锁可能性：
cat /proc/lockdep/chains

# 锁统计：
cat /proc/lock_stat | head -20
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/locking/lockdep.c` | `check_chain_key`、`validate_chain` |
| `kernel/locking/lockdep_states.c` | 锁统计 |

---

## 6. 西游记类喻

**lockdep** 就像"天庭的锁具管理员"——

> lockdep 像天庭的锁具管理员，记录每个锁匠（CPU）每次取锁的顺序（lock_chain）。如果管理员发现某天有人按 A→B 顺序取了锁，另一天有人按 B→A 顺序取了锁，就知道这样迟早会出问题（A 持有着 A 等待 B，B 持有着 B 等待 A）。lockdep 在死锁发生前就能检测到潜在的死锁风险。

---

## 7. 关联文章

- **spinlock**（article 09）：spinlock 是 lockdep 的主要追踪对象
- **mutex**（article 08）：mutex 也被 lockdep 追踪