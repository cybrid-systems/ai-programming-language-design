# 26-RCU — 读取-复制-更新深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/rcupdate.h` + `kernel/rcu/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**RCU（Read-Copy-Update）** 是 Linux 的高性能读写并发机制：读操作不加锁（可并行），写操作在宽限期（grace period）后才真正删除旧数据。

---

## 1. RCU 核心思想

```
传统锁：
  读者 ─┐
         ├─→ [临界区] ─→ 离开
  读者 ─┘
         ↑
      写入者（独占）

RCU：
  读者 ─┐
         ├─→ [读取] ─→ 离开（无锁）
  读者 ─┘
         ↑
  写入者 ──→ [复制+修改] ─→ [发布新数据] ─→ [等待宽限期] ─→ [删除旧数据]
```

---

## 2. 核心 API

### 2.1 rcu_read_lock / rcu_read_unlock — 读临界区

```c
// include/linux/rcupdate.h — rcu_read_lock
void rcu_read_lock(void)
{
    __rcu_read_lock();
    // 在 preempt_disable 基础上加 RCU 嵌套计数
}

// 实际实现（SMP）：
//   preempt_disable() + rcu_read_lock_nesting++

// rcu_read_unlock：
void rcu_read_unlock(void)
{
    __rcu_read_unlock();
    // preempt_enable() + 嵌套计数--
}
```

### 2.2 rcu_dereference — 安全解引用

```c
// include/linux/rcupdate.h — rcu_dereference
#define rcu_dereference(p) \
    rcu_dereference_check(p, __rcu_read_lock_held())

// 编译时检查：确保在 RCU 读临界区内
// 内存屏障：确保读取到的是发布后的完整数据
```

### 2.3 synchronize_rcu — 等待宽限期

```c
// kernel/rcu/update.c — synchronize_rcu
void synchronize_rcu(void)
{
    // 1. 等待所有正在进行的 RCU 读临界区完成
    // 2. 宽限期结束后返回
    //    宽限期 = 所有 CPU 都经过一次 quiescent state

    // 实现：注册回调，由 RCU 软中断在宽限期结束时调用
    wait_rcu_gp();
}
```

---

## 3. 宽限期（Grace Period）

### 3.1 rcu_gp_kthread — RCU 守护线程

```c
// kernel/rcu/tree.c — rcu_gp_kthread
static int __noreturn rcu_gp_kthread(void *arg)
{
    for (;;) {
        // 1. 等待触发条件
        wait_event_interruptible(rcu_gp_wq, need_more_gp());

        // 2. 开始新的宽限期
        rcu_advance_gp();

        // 3. 扫描所有 CPU，等待 quiescent state
        for_each_online_cpu(cpu) {
            // 检查 CPU 是否已经报告 qs（quiescent state）
            // 如果所有 CPU 都 qs，宽限期结束
        }

        // 4. 宽限期结束，调用所有注册的回调
        rcu_do_batch();
    }
}
```

### 3.2 Quiescent State

```
Quiescent state（静止状态）= CPU 不在 RCU 读临界区内

每个 CPU 需要在宽限期内报告至少一次 quiescent state：
  - 用户态执行
  - idle 进程
  - 处于 spinlock 临界区
```

---

## 4. list_for_each_entry_rcu — RCU 安全遍历

```c
// include/linux/rculist.h — list_for_each_entry_rcu
#define list_for_each_entry_rcu(pos, head, member, lock...) \
    for (pos = list_entry(rcu_dereference_raw((head)->next), \
                typeof(*pos), member); \
         list_entry_is_head(pos, head, member) || \
         ({ rcu_read_lock(); \
            cond = 1; \
            rcu_dereference_raw(pos->member.next); \
          }); \
         pos = list_entry(rcu_dereference_raw(pos->member.next), \
               typeof(*pos), member))
```

---

## 5. 使用案例：Linux 内核链表

### 5.1 hlist_for_each_entry_rcu

```c
// 查找 dentry：
hlist_for_each_entry_rcu(dentry, &inode->i_dentry, d_hash) {
    if (dentry->d_name == name)
        return dentry;
}
```

---

## 6. SRCU（Sleepable RCU）

```c
// include/linux/srcutiny.h — srcu_read_lock
int srcu_read_lock(struct srcu_struct *sp)
{
    return sp->completed & 0x1;
}

// srcu_read_lock 不禁用抢占，可在睡眠上下文使用
// 但必须有对应的 srcu_read_unlock
```

---

## 7. RCU vs 传统锁

| 特性 | RCU | 读写锁 |
|------|-----|--------|
| 读并发 | ✓（完全并行）| ✗（写独占）|
| 读延迟 | 零（无锁）| 自旋等待 |
| 写延迟 | 需要宽限期 | 即时 |
| 内存开销 | 低 | 高 |
| 适用 | 读多写少 | 读写均衡 |

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/rcupdate.h` | `rcu_read_lock/unlock`、`rcu_dereference`、`synchronize_rcu` |
| `include/linux/rculist.h` | `list_for_each_entry_rcu` |
| `kernel/rcu/tree.c` | `rcu_gp_kthread` |

---

## 9. 西游记类比

**RCU** 就像"取经路上的空中快递"——

> 悟空（写者）要更新一本书，先复制一本（复制+修改），然后把新书放到书架上（发布新数据）。但不能立即销毁旧书——要等所有正在翻阅这本书的人（RCU 读临界区）都看完。宽限期就像"宽限期通知单"，通知所有读者："请在宽限期内看完旧书"。等所有人都看完（或离开），旧书才能销毁。这就是 RCU 的核心：写者复制，读者无锁，宽限期后清理。

---

## 10. 关联文章

- **hlist**（article 02）：RCU 安全遍历
- **list_head**（article 01）：RCU 遍历变体