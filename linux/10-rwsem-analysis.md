# rwsem — 读写信号量深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/rwsem.h` + `kernel/locking/rwsem.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**rwsem（读写信号量）**允许多个读者同时持有锁，但写入者独占：
- **读者**：`count > 0` 时可并发进入
- **写入者**：需要独占访问

---

## 1. 核心数据结构

### 1.1 rw_semaphore

```c
// include/linux/rwsem.h — rw_semaphore
struct rw_semaphore {
    atomic_long_t           count;           // 高位=写锁计数，低位=读者计数
    raw_spinlock_t         wait_lock;        // 保护等待链表
    struct list_head       wait_list;        // 等待者链表
#ifdef CONFIG_RWSEM_SPIN_ON_OWNER
    struct task_struct     *owner;           // 持有者（用于 optimistic spinning）
#endif
};
```

### 1.2 count 编码

```
count 位布局（64-bit）：
  [63:32] 写锁计数（取负表示有写锁）
  [31:0]   读者计数

  count = 0:          锁空闲
  count > 0:         有 count 个读者
  count < 0:          有写入者（count 的绝对值 = 写等待者+读者数）
```

---

## 2. 读锁（down_read）

```c
// kernel/locking/rwsem.c — __down_read
static inline void __down_read(struct rw_semaphore *sem)
{
    if (atomic_long_inc_return(&sem->count) <= 0) {
        // count <= 0：有写入者等待，自旋等待
        rwsem_down_read_failed(sem);
    }
}
```

---

## 3. 写锁（down_write）

```c
// kernel/locking/rwsem.c — __down_write
static inline int __down_write(struct rw_semaphore *sem)
{
    long tmp;

    tmp = atomic_long_add_return(RWSEM_ACTIVE_WRITE_BIAS, &sem->count);
    if (tmp != RWSEM_ACTIVE_WRITE_BIAS)
        // 已失败，走慢路径
        return rwsem_down_write_failed(sem);

    return 0;
}

#define RWSEM_ACTIVE_WRITE_BIAS   (-RWSEM_WAITING_BIAS)
#define RWSEM_WAITING_BIAS        (-RWSEM_ACTIVE_MASK - 1)
#define RWSEM_ACTIVE_MASK         0xffff
```

---

## 4. 参考

| 文件 | 函数 |
|------|------|
| `include/linux/rwsem.h` | `struct rw_semaphore` |
| `kernel/locking/rwsem.c` | `__down_read`、`__down_write`、`rwsem_down_*_failed` |
