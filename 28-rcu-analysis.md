# Linux Kernel RCU (Read-Copy-Update) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/rcu/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. 什么是 RCU？

**RCU**（Read-Copy-Update）是 Linux 最重要的高性能**读写同步机制**：
- **读者**：无锁、无内存屏障，性能极高
- **写者**：需要复制、等待所有旧读者退出后再删除旧数据
- **核心假设**：读者持有锁的时间极短（spin_lock 期间），写者可以等待

**典型场景**：
- 路由表更新（读多写少）
- 文件系统 dentry 缓存
- 网络连接跟踪

---

## 1. RCU 核心 API

```c
// 读者端（零开销）
rcu_read_lock();      // 标记读者临界区开始
// ... 读受保护的数据 ...
rcu_read_unlock();    // 标记读者临界区结束

// 写者端
// 1. 复制旧数据
// 2. 修改副本
// 3. 替换指针（publish）
rcu_assign_pointer(p, new_ptr);  // 发布新数据

// 4. 等待所有旧读者退出
synchronize_rcu();     // 同步等待（阻塞）
call_rcu(&head, callback);  // 异步回调

// 5. 释放旧数据
kfree_rcu(ptr, field);  // 延迟释放（常用）
```

---

## 2. rcu_head — 回调结构

```c
// include/linux/rcupdate.h — rcu_head
struct rcu_head {
    struct rcu_head *next;      // 链表
    void            (*func)(struct rcu_head *head);  // 回调函数
};
```

---

## 3. synchronize_rcu — 等待读者

```c
// kernel/rcu/srcu.c — synchronize_srcu
void synchronize_srcu(struct srcu_struct *sp)
{
    // 1. 获取当前 grace period 编号
    idx = srcu_readers_active_idx(sp);

    // 2. 等待所有读者退出（通过 check_callback_batching）
    // 3. 推进 grace period
    // 4. 回调所有积累的 call_rcu
}

// 关键概念：grace period
//   - grace period 是所有正在进行的读者都退出后的一段时间
//   - 只有 grace period 结束后，旧数据才能被释放
```

---

## 4. 设计思想总结

| 设计决策 | 原因 |
|---------|------|
| 读者无锁 | 极高性能，适合读多写少场景 |
| 写者等待 grace period | 保证旧读者不会访问已释放的数据 |
| call_rcu 异步回调 | 避免写者阻塞，提高吞吐量 |
| kfree_rcu 延迟释放 | 写者不需要等待，直接返回 |

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `kernel/rcu/update.c` | `synchronize_rcu`、`call_rcu` |
| `include/linux/rcupdate.h` | `rcu_read_lock`、`rcu_dereference`、`kfree_rcu` |
