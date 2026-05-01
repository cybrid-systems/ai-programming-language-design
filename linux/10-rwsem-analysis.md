# 10-rwsem — 读写信号量深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**rwsem（Reader-Writer Semaphore）** 允许多个读者同时持有，写者必须独占。适合读多写少场景。

---

## 1. 数据结构

```c
struct rw_semaphore {
    atomic_long_t count;       // 读者计数+写者标志
    struct optimistic_spin_queue osq;   // MCS 自旋队列
    struct raw_spinlock wait_lock;
    struct list_head wait_list;
};
```

count 编码：
- 0 = 空闲
- 正值 = 读者数量
- RWSEM_WRITER_BIAS = 写者持有

---

## 2. 数据流

```
down_read(sem)
  ├─ CAS(count, old, old + READ_BIAS)
  └─ down_read_slowpath() → spinning → schedule()

down_write(sem)
  ├─ CAS(count, 0, WRITER_BIAS)
  └─ down_write_slowpath() → spinning → schedule()
```

---

*分析工具：doom-lsp（clangd LSP）*
