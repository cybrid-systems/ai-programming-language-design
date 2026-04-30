# RCU (Read-Copy-Update) — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/rcupdate.h` + `kernel/rcu/tree.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**RCU（Read-Copy-Update）** 是 Linux 内核最常用的**读多写少同步原语**：
- **读端**：无锁（`rcu_read_lock()` / `rcu_read_unlock()`）
- **写端**：在宽限期（grace period）结束后才释放旧数据
- 性能：读端零开销，写端延迟释放

---

## 1. 核心 API

### 1.1 读端临界区

```c
// include/linux/rcupdate.h
rcu_read_lock();
    // 读共享数据
    rcu_dereference(ptr);  // 读取 RCU 指针
    // 使用数据...
rcu_read_unlock();
```

### 1.2 写端更新

```c
// include/linux/rcupdate.h
// 1. 原子替换
rcu_replace_pointer(root, new_ptr, lock);

// 2. 等待宽限期结束
synchronize_rcu();  // 阻塞直到所有读者退出

// 3. 释放旧数据
kfree_rcu(old_ptr, head);
```

---

## 2. 核心数据结构

### 2.1 rcu_head — RCU 回调节点

```c
// include/linux/rcupdate.h — rcu_head
struct rcu_head {
    struct rcu_head       *next;      // 链表
    void                 (*func)(struct rcu_head *); // 回调函数
};
```

### 2.2 rcu_node — RCU 树节点（用于宽限期检测）

```c
// kernel/rcu/tree.h — rcu_node
struct rcu_node {
    spinlock_t        lock;           // 保护
    unsigned long     qsmask;         // 需要同步的子节点掩码
    unsigned long     expmask;         // 正在同步的子节点
    struct rcu_data  *leaf[2];        // 子 RCU 数据
    // ...
};
```

### 2.3 rcu_data — per-CPU 数据

```c
// kernel/rcu/tree.h — rcu_data
struct rcu_data {
    unsigned long       gp_seq;         // 当前宽限期序号
    unsigned long       gp_seq_needed;  // 需要的宽限期
    struct rcu_segcblist    *cblist;   // 回调链表
    struct rcu_node           *mynode; // 所属节点
    // ...
};
```

---

## 3. rcu_dereference — 安全读取

```c
// include/linux/rcupdate.h
#define rcu_dereference(p) \
    __rcu_dereference_check(p, 0, __UNIQUE_ID(__rcu))

#define __rcu_dereference_check(p, space, check) \
({ \
    typeof(*p) *_________p1 = __unqual_scalar_typeof(*p) *__t; \
    smp_read_acquire((typeof(p))__t, &(p)); \
    __t; \
})

// smp_read_acquire 确保：
// - 读取 p 之前的所有内存操作都对读者可见
// - 防止编译器重排序
```

---

## 4. synchronize_rcu — 等待宽限期

```c
// kernel/rcu/tree.c — synchronize_rcu
void synchronize_rcu(void)
{
    // 1. 获取当前宽限期序号
    wait_event(gp_wq, rcu_gp_seq_end(drain));
    // 或：等待所有 CPU 进入 quiescent state

    // 2. 宽限期结束前，阻塞当前线程
    wait_rcu_gp();
}
```

---

## 5. kfree_rcu — 无锁释放

```c
// include/linux/rcupdate.h
#define kfree_rcu(ptr, rcu_head_member) \
    do { \
        struct rcu_head *p; \
        p = (struct rcu_head *)((char *)ptr - offsetof(typeof(*ptr), rcu_head_member)); \
        call_rcu(p, rcu_callback); \
    } while (0)

// 内核自动安排回调，在宽限期结束后调用 kfree
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/rcupdate.h` | `rcu_read_lock/unlock`、`rcu_dereference`、`synchronize_rcu`、`kfree_rcu` |
| `kernel/rcu/tree.c` | `synchronize_rcu`、`wait_rcu_gp` |
| `kernel/rcu/tree.h` | `struct rcu_node`、`struct rcu_data` |