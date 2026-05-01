# 26-RCU — 读-复制-更新深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**RCU（Read-Copy-Update）** 是一种无锁同步机制：读者无需任何锁（甚至无需原子操作），写者通过"发布新版本 → 等待旧读者退出 → 回收旧版本"更新数据。

---

## 1. 核心原语

```
读端：
  rcu_read_lock()                       ← 进入读端临界区
  ptr = rcu_dereference(p)              ← 安全读取
  // 使用 ptr...
  rcu_read_unlock()                     ← 退出

写端：
  ptr->a = new_val;                      ← 更新数据
  rcu_assign_pointer(p, new_ptr)         ← 发布新指针
  synchronize_rcu()                      ← 等待所有旧读者退出
  kfree(old_ptr)                         ← 安全回收
```

---

## 2. 宽限期（Grace Period）

```
时间线：
  A进入读端         B进入读端    synchronize_rcu()
  │                  │               │
  │   A退出读端      │  B退出读端    │
  │                  │               │
  └──────────────────┴───────────────┘
                                     ↓ 返回
                        可以安全回收旧数据
```

所有在 `synchronize_rcu()` 调用前已进入的读者都退出后，宽限期结束。

---

## 3. 核心 API

| API | 说明 |
|-----|------|
| `rcu_read_lock/unlock` | 读端临界区 |
| `rcu_dereference` | 安全读取 RCU 指针 |
| `rcu_assign_pointer` | 发布新指针（写端）|
| `synchronize_rcu` | 同步等待（可能阻塞）|
| `call_rcu` | 异步：宽限期后调用回调 |
| `kfree_rcu` | 宽限期后释放 |

---

*分析工具：doom-lsp（clangd LSP）*
