# 10-rwsem — 读写信号量深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`include/linux/rwsem.h` + `kernel/locking/rwsem.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**rwsem（读写信号量）** 允许多个读者同时持有锁（读共享），但写者必须独占。适用于读多写少场景。

---

## 1. 核心数据结构

### 1.1 struct rw_semaphore — 读写信号量

```c
// include/linux/rwsem.h:23 — rw_semaphore
struct rw_semaphore {
    atomic_long_t           count;         // 计数：锁状态编码
    //   RWSEM_UNLOCKED_VALUE = 0x0
    //   bit[0] = RWSEM_WRITER_LOCKED = 0x1  写锁标记
    //   其他位：等待者数量和读者计数

    spinlock_t             wait_lock;     // 保护等待者链表
    struct list_head        wait_list;     // 等待者链表（FIFO）
};
```

### 1.2 count 字段编码

```
count 值（atomic_long_t，64位/32位）：

RWSEM_UNLOCKED_VALUE = 0x0
  → 没有人持有锁

RWSEM_WRITER_LOCKED = 0x1
  → 有写者持有锁

正数（不含 bit[0]）：
  → 有 N 个读者持有锁
  → count = N << 1 | 0

写者等待时：
  count = (等待读者数 << 1) | RWSEM_WAITERS_FOR_WRITE
```

---

## 2. 计数操作

### 2.1 down_read / up_read — 读者加锁/解锁

```c
// kernel/locking/rwsem.c — down_read
void __sched down_read(struct rw_semaphore *sem)
{
    // 1. 尝试直接获取读锁
    long tmp = atomic_long_add_return(RWSEM_READER_BIAS, &sem->count);
    //   RWSEM_READER_BIAS = 0x00000001L

    // 2. 检查是否有写者持有或等待
    if ((tmp & (RWSEM_WRITER_LOCKED | RWSEM_WAITERS_FOR_WRITE)) == 0)
        return;  // 成功

    // 3. 有冲突，进入 slowpath
    rwsem_down_read_failed(sem);
}

// up_read：
void up_read(struct rw_semaphore *sem)
{
    long tmp = atomic_long_sub_return(RWSEM_READER_BIAS, &sem->count);
    // 减掉一个读者计数

    // 如果有写者在等待，唤醒
    if (tmp & RWSEM_WAITERS_FOR_WRITE)
        rwsem_wake_waiter(sem);
}
```

### 2.2 down_write / up_write — 写者加锁/解锁

```c
// kernel/locking/rwsem.c — down_write
void __sched down_write(struct rw_semaphore *sem)
{
    // 1. 尝试直接获取写锁
    //   RWSEM_WRITER_LOCKED = 0x1
    long tmp = atomic_long_cmpxchg_acquire(&sem->count,
                                          RWSEM_UNLOCKED_VALUE,
                                          RWSEM_WRITER_LOCKED);
    if (tmp == RWSEM_UNLOCKED_VALUE)
        return;  // 成功

    // 2. 进入 slowpath（有竞争）
    rwsem_down_write_failed(sem);
}

// up_write：
void up_write(struct rw_semaphore *sem)
{
    long tmp = atomic_long_sub_return(RWSEM_WRITER_LOCKED, &sem->count);

    // 如果有写者或读者在等待，唤醒
    if (tmp & (RWSEM_WAITERS_FOR_WRITE | RWSEM_READERS_WAITING))
        rwsem_wake_waiter(sem);
}
```

---

## 3. 失败路径

### 3.1 rwsem_down_read_failed — 读者获取失败

```c
// kernel/locking/rwsem.c — rwsem_down_read_failed
static long rwsem_down_read_failed(struct rw_semaphore *sem)
{
    // 1. 增加等待者计数
    atomic_long_add_return(RWSEM_WAITERS_FOR_READ, &sem->count);

    // 2. 自旋等待写者释放
    for (;;) {
        if (sem->count == RWSEM_UNLOCKED_VALUE)
            break;  // 已解锁

        // 让出 CPU
        schedule();
    }

    // 3. 减少等待者计数
    atomic_long_sub(RWSEM_WAITERS_FOR_READ, &sem->count);

    // 4. 重新获取读锁
    atomic_long_add(RWSEM_READER_BIAS, &sem->count);

    return 0;
}
```

### 3.2 rwsem_down_write_failed — 写者获取失败

```c
// kernel/locking/rwsem.c — rwsem_down_write_failed
static long rwsem_down_write_failed(struct rw_semaphore *sem)
{
    // 写者优先：阻塞新读者

    // 1. 加入等待队列
    waiter.task = current;
    list_add_tail(&waiter.list, &sem->wait_list);

    // 2. 标记有写者等待
    atomic_long_or(RWSEM_WAITERS_FOR_WRITE, &sem->count);

    // 3. 自旋等待
    for (;;) {
        if (sem->count == RWSEM_UNLOCKED_VALUE)
            break;
        schedule();
    }

    // 4. 标记无等待者
    atomic_long_andnot(RWSEM_WAITERS_FOR_WRITE, &sem->count);
    return 0;
}
```

---

## 4. 写者优先 vs 读者优先

### 4.1 Linux 的 rwsem 默认：写者优先

```
问题：写者饿死（读者不断来，写者永远得不到）

Linux rwsem 解决：
  - down_read 时如果有写者等待，读者也要自旋等待
  - 这实际上是一种"写者优先"
  - 新来的读者被阻塞在 rwsem_down_read_failed
```

### 4.2 读优先 vs 写优先

```
读优先：所有读者可以同时来，写者饿死
写优先：新读者被阻塞，直到所有写者完成
Linux 默认：写优先（通过 WAITERS_FOR_WRITE 标记）
```

---

## 5. 内核使用案例

### 5.1 VMA 读写锁（mmap_lock）

```c
// mm/mmap.c — mmap_write_lock
// 写操作：mmap()、munmap()、mprotect() 等
// 使用 down_write
void mmap_write_lock(struct mm_struct *mm)
{
    down_write(&mm->mmap_lock);
}

// 读操作：查找 VMA（find_vma）等
// 使用 down_read
struct vm_area_struct *find_vma(struct mm_struct *mm, unsigned long addr)
{
    down_read(&mm->mmap_lock);
    // ... 查找 ...
    up_read(&mm->mmap_lock);
}
```

### 5.2 文件系统 inode

```c
// fs/inode.c — i_sem
struct inode {
    struct rw_semaphore i_rwsem;  // 保护 inode 的某些字段
};
```

---

## 6. 与 RCU 的对比

| 特性 | rwsem | RCU |
|------|-------|-----|
| 读并发 | 多读者 | 多读者（完全并发）|
| 写并发 | 互斥 | 互斥 |
| 读延迟 | 自旋可能 | 零延迟（无锁）|
| 写延迟 | 需要唤醒 | 需要广播 |
| 适用 | 写少读多 | 读极多写极少 |

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/rwsem.h` | `struct rw_semaphore`、`RWSEM_*` 常量 |
| `kernel/locking/rwsem.c` | `down_read`、`up_read`、`down_write`、`up_write` |
| `kernel/locking/rwsem.c` | `rwsem_down_read_failed`、`rwsem_down_write_failed` |