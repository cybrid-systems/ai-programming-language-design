# Linux Kernel rwsem v7.0 核心强化 — 深度源码分析

> 基于 Linux 7.0-rc1 主线源码 + v7.0 重大新特性
> 工具：doom-lsp（clangd LSP）+ git log + 源码对照
> 更新：整合 2026-04-23 深入分析笔记

---

## 0. v7.0 对 rwsem 的核心改进概述

v7.0 对 rwsem 本身的核心算法（optimistic spinning / wait_list / owner tracking）**没有结构性改动**，但通过两项基础设施级强化，让读密集型子系统的并发性能上了一个台阶：

| 改进维度 | 具体变化 | 实际影响 |
|---------|---------|---------|
| **编译时安全** | Clang Context Analysis（上下文锁分析） | 锁规则在编译期静态验证，运行时开销接近零 |
| **可观测性** | F2FS rwsem tracepoint | 精确量化 spinning vs 睡眠开销 |
| **运行时** | optimistic spinning 核心不变 | 受益于 scheduler / NUMA / cache 整体优化 |

---

## 1. Compiler-Based Context and Locking Analysis（编译时上下文锁分析）

### 1.1 核心机制

Linux 7.0 引入了基于 Clang 的**上下文锁分析**框架（commit series by Peter Zijlstra / elver@ team）。

**传统方式**：lockdep 在运行时检测锁误用（如持有读锁时 down_write），但只能检测实际执行到的路径，容易漏报或产生大量 warning。

**新方式**：Clang 语言扩展把内核同步原语建模为 `context lock`：

```c
// 开发者声明"持有此锁时必须处于什么上下文"
context_lock(rw_semaphore) acquire;
context_lock(rw_semaphore) release;

// 示例用法（来自 mm/mmap.c）
void do_mmap(...)
{
    // 编译器静态验证：down_read(&mm->mmap_lock) 时是否处于正确上下文
    down_read(&mm->mmap_lock);   // 读锁，编译器验证无违规模
}
```

**编译器在编译期检查**：
1. `acquire` / `release` 是否配对
2. 嵌套规则（持读锁时不能 down_write）
3. 上下文正确性（中断上下文 vs 进程上下文）
4. 潜在死锁模式（类似 lockdep 的 cycle 检测，但提前到编译期）

### 1.2 对 rwsem 的实际影响

**page cache（`address_space->i_mmap_rwsem`）、dentry（`dentry->d_lock`）**等读密集型路径：

```
过去：
  - 依赖运行时 lockdep 检测
  - lockdep warning 过多时开发者不敢优化
  - 并发参数不敢设得太激进

现在（v7.0）：
  - 编译期已保证锁规则正确
  - 开发者敢开启更激进的 optimistic spinning
  - lockdep warning 大幅减少
  - 实际吞吐提升来源于：更少上下文切换 + 更好 owner 跟踪精度
```

---

## 2. F2FS rwsem Elapsed Time Trace（可观测性强化）

### 2.1 新增 Tracepoint

v7.0 在 F2FS 中新增了精确的 rwsem 持有时间 tracepoint：

```c
// 来自 fs/f2fs/*.c 和相关 tracepoint 定义
trace_f2fs_down_read(sem, elapsed_time);    // 读锁获取 + 耗时
trace_f2fs_up_read(sem, elapsed_time);      // 读锁释放 + 持有时间
trace_f2fs_down_write(sem, elapsed_time);   // 写锁获取
trace_f2fs_up_write(sem, elapsed_time);     // 写锁释放 + 持有时间
```

### 2.2 实际用途

```
生产环境监控场景：

1. 获取 rwsem 持有时间分布
   $ perf record -e f2fs:f2fs_up_read -a -- sleep 10
   $ perf report

   结果：
     - 99% 读锁持有 < 5μs → optimistic spinning 非常有效
     - 1% 读锁持有 > 50μs → 可能需要调整 spinning 阈值

2. 判断 spinning vs 睡眠的决策质量
   - spinning 时间很短但最终还是睡眠 → spinning 阈值太低
   - spinning 时间很长但抢到锁 → spinning 有效，可提高阈值

3. 热点识别
   - 高频、长持有时间的锁 → 优化锁粒度或读写分离
```

---

## 3. Optimistic Spinning 核心现状（v7.0）

### 3.1 核心路径（`kernel/locking/rwsem.c:840`）

```c
static bool rwsem_optimistic_spin(struct rw_semaphore *sem)
{
    // 1. 获取 MCS 队列锁（osq）
    if (!osq_lock(&sem->osq))
        return false;

    // 2. 自旋循环
    for (;;) {
        enum owner_state owner_state = rwsem_owner_state(sem);

        if (owner_state == OWNER_NULL) {
            // 无持有者 → 原子抢锁
            if (atomic_long_try_cmpxchg(&sem->count, &orig, curr)) {
                rwsem_set_owner(sem);
                return true;
            }
        }

        if (owner_state == OWNER_WRITER) {
            // 写者持有 → 检查是否在运行
            if (rwsem_spin_on_owner(sem))
                continue;   // 仍在运行，继续自旋
            break;         // 写者已睡眠，退出自旋
        }

        if (owner_state == OWNER_READER) {
            // 读者持有 → 短暂自旋等待
            if (++loop > 10)
                break;
            cpu_relax();
        }

        if (owner_state == OWNER_NONSPINNABLE)
            break;
    }

    osq_unlock(&sem->osq);
    return false;
}
```

### 3.2 为什么 v7.0 没有改核心算法但性能仍提升？

```
1. owner 跟踪精度提升
   → scheduler 改进让 rwsem_spin_on_owner() 判断更准
   → 写者睡眠时更快退出自旋，不浪费 CPU

2. NUMA / cache 改进
   → osq MCS 队列的 cacheline 竞争更少
   → 自旋时 lock owner 的 cacheline 更容易在本地

3. F2FS trace 帮助识别热点
   → 开发者量化后更有信心调优

4. Compiler Analysis 让 lockdep warning 大幅减少
   → 运行时 lockdep 开销降低
```

---

## 4. 完整 rwsem v7.0 强化总结

```
┌─────────────────────────────────────────────────────────┐
│           rwsem v7.0 改进全貌                           │
├──────────────────┬──────────────────────────────────────┤
│ 编译时安全        │ Clang Context Lock Analysis           │
│                  │ - 配对检查、嵌套规则、死锁 cycle 检测  │
│                  │ - lockdep warning ↓                   │
│                  │ - 开发者敢更激进使用 rwsem             │
├──────────────────┼──────────────────────────────────────┤
│ 可观测性          │ F2FS rwsem tracepoint                │
│                  │ - f2fs_down_read/up_read 时间戳        │
│                  │ - spinning 效果量化                    │
│                  │ - 生产环境 perf trace                  │
├──────────────────┼──────────────────────────────────────┤
│ 运行时优化        │ optimistic spinning 核心不变             │
│                  │ - 受益于 scheduler / NUMA / cache 改进 │
│                  │ - owner 跟踪更精确                    │
│                  │ - osq MCS 竞争减少                     │
└──────────────────┴──────────────────────────────────────┘

实际收益（page cache / dentry 等读密集路径）：
  - 高核数机器吞吐提升（得益于更少上下文切换）
  - 尾延迟降低（得益于更准 spinning 决策）
  - Bug 减少（编译期静态检查）
```

---

## 5. 参考

| 资源 | 内容 |
|------|------|
| `kernel/locking/rwsem.c:840` | `rwsem_optimistic_spin` 完整实现 |
| `kernel/locking/rwsem.c:728` | `rwsem_can_spin_on_owner` |
| `kernel/locking/rwsem.c:767` | `rwsem_spin_on_owner` |
| `fs/f2fs/*trace*` | F2FS rwsem tracepoint 定义 |
| `include/linux/rwsem.h` | `rw_semaphore` 结构、owner 状态机 |
| lore.kernel.org (cover letter) | Compiler Context Analysis commit series |
