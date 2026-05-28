# 30. InnoDB 检查点（Checkpoint）— 源码分析

> 本文分析 InnoDB 检查点机制，包括 Fuzzy Checkpoint、Sharp Checkpoint、自适应刷新（Adaptive Flush）、Doublewrite Buffer 和检查点 LSN 的协调。核心源文件：`buf0buf.cc`、`buf0flu.cc`、`log0log.cc`、`log0write.cc`、`srv0srv.cc`。

---

## 0. 概述

检查点（Checkpoint）是 InnoDB 用于**限制崩溃恢复时间**的核心机制。它告诉 InnoDB：在此之前的所有已提交修改都已经安全写入磁盘，恢复可以从检查点 LSN 开始，无需扫描更早的 redo log。

### 检查点的基本原理

```
时间线:
  ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
  │ WAL │ WAL │ WAL │ 脏页│ WAL │ 脏页│ 脏页│ WAL │
  │     │     │     │刷盘 │     │刷盘 │刷盘 │     │
  └─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
  0    100   200   300   400   500   600   700   800  LSN

  检查点 LSN = 300
  → 所有 LSN < 300 的 WAL 日志可以删除
  → 崩溃时从 LSN 300 开始恢复
  → redo log 只需保留 [300, 800] 部分
```

---

## 1. 检查点类型

### 1.1 Sharp Checkpoint

将所有脏页刷盘（shutdown 时）：

```cpp
// log0log.cc
void log_checkpoint(bool shutdown) {
  if (shutdown) {
    /* 关闭时的完整检查点 */
    /* 1. 等待所有活跃事务完成 */
    /* 2. 将所有脏页写入磁盘 */
    /* 3. 将所有 redo log 刷入磁盘 */
    /* 4. 写入检查点标记到日志文件头 */
    /* 5. 关闭 redo log */

    /* 这保证了关闭后的恢复 = redo log apply */
  }
}
```

### 1.2 Fuzzy Checkpoint（运行中）

```cpp
// log0log.cc
void log_checkpoint(bool shutdown) {
  if (!shutdown) {
    /* 运行时模糊检查点 */

    /* ──── 步骤 1：确定 oldest_lsn ──── */
    /* = 最旧脏页（Buffer Pool 中修改最早但未刷盘）的 LSN */
    lsn_t oldest_lsn = buf_pool_get_oldest_modification();

    /* ──── 步骤 2：确保所有 LSN < oldest_lsn 的日志已写入 redo log 文件 ──── */
    /* 这是通过 log_write_up_to(oldest_lsn) 完成的 */

    /* ──── 步骤 3：写入检查点信息到 redo log 文件头 ──── */
    log_write_checkpoint_info(oldest_lsn);

    /* ──── 步骤 4：截断 redo log ──── */
    /* = 释放 oldest_lsn 之前的 redo log 空间 */
    log_files_release_before(oldest_lsn);
  }
}
```

**模糊检查点的关键**：不需要等待所有脏页刷盘——只需确定最旧的脏页 LSN，然后截断之前的日志。

```
检查点 LSN = 300
脏页列表（未刷盘）:
  page 100   LSN: 600  (最近修改)
  page 200   LSN: 450  (中间修改)
  page 50    LSN: 300  (最旧的脏页)

→ 最旧脏页 LSN = 300
→ 截断 LSN < 300 的日志
→ 但 page 100、200 的日志 LSN > 300 还没有刷盘也没关系
→ 它们的日志还保留在 redo log 中
```

---

## 2. 自适应刷新（Adaptive Flush）

为了避免脏页堆积过多导致检查点变慢，InnoDB 在后台线程中执行自适应刷新：

```cpp
// buf0flu.cc
ulint buf_flush_page_cleaner_thread(void *arg) {

  while (!shutdown) {
    /* ──── 步骤 1：计算脏页比例 ──── */
    ulint dirty_pct = buf_get_modified_ratio_pct();
    /* = 脏页数量 * 100 / Buffer Pool 总页面数 */

    /* ──── 步骤 2：判断是否需要加速刷新 ──── */
    if (dirty_pct > srv_max_buf_pool_modified_pct) {
      /* 脏页比例超过阈值（默认 75%）→ 紧急刷新 */
      n_pages = PCT_IO(100);  /* 使用全部 IO 容量 */
    } else {
      /* 根据最近的 redo log 生成速度估算刷盘速率 */
      n_pages = af_get_pages_for_flush();
      /* 公式: n_pages = (recent_log_speed * af_avg_time_per_page) */
    }

    /* ──── 步骤 3：从 flush_list 中选最旧的脏页 LSN → 批量刷写 ──── */
    buf_flush_list(n_pages);
  }
}
```

### 自适应刷新算法的细节

```cpp
// buf0flu.cc — af_get_pages_for_flush()
ulint af_get_pages_for_flush() {
  /* 1. 计算最近 redo log 的生成速度 */
  lsn_t log_lsn = log_get_current_lsn();
  lsn_t checkpoint_lsn = log_get_checkpoint_lsn();
  lsn_t lsn_gap = log_lsn - checkpoint_lsn;

  /* 2. 如果 LSN 差距太大 → 加快刷新 */
  if (lsn_gap > srv_adaptive_flushing_lwm * log_buffer_size) {
    /* srv_adaptive_flushing_lwm 默认 10% */
    /* → 强制加速刷新 */
    return PCT_IO(100);
  }

  /* 3. 估算需要的刷盘页数 */
  /* 基于过去 N 秒的日志生成速度 */
  ulint pages_flushed = buf_flush_get_desired_flush_rate();

  return pages_flushed;
}
```

---

## 3. redo log 文件管理与检查点协调

### 3.1 redo log 文件组

```
ib_logfile0            ← 当前活动的日志文件
ib_logfile1            ← 备用
...
ib_logfileN

日志文件组循环使用:

    检查点 LSN ─┐
                │
  [   日志文件组   ]
  ┌────────┬────────┬────────┐
  │ 可重用 │ 活跃区│  可重用 │
  └────────┴────────┴────────┘
            ↑
    当前写入位置
```

当检查点发生时，检查点 LSN 之前的日志文件可以被重用。

### 3.2 避免检查点阻塞

```cpp
// log0write.cc
void log_checkpoint(bool shutdown) {
  if (!shutdown) {
    /* 运行时检查点不应阻塞太久 */

    /* 如果脏页太多 → 检查点可能阻塞 */
    /* 解决方案: 多次触发小检查点，而不是一次大检查点 */

    /* 阈值: innodb_max_dirty_pages_pct_lwm (默认 10%) */
    /* 当脏页比例低于此值时，允许更激进的检查点 */

    if (dirty_pct < srv_max_dirty_pages_pct_lwm) {
      /* 脏页不多 → 执行完整检查点 */
    } else {
      /* 脏页较多 → 先加速刷脏再检查点 */
      buf_flush_ahead();
    }
  }
}
```

---

## 4. Doublewrite Buffer 与检查点的关系

Doublewrite Buffer 在检查点刷盘时保护页面写入的原子性：

```
检查点触发 buf_flush_list():
  1. 脏页写入 doublewrite buffer（连续写入）
  2. 然后写入实际表空间文件（离散写入）
  3. 如果步骤 2 崩溃 → 恢复时从 doublewrite buffer 恢复

检查点时间线:
  LSN 500: 写入 doublewrite buffer (page 100, 200, 300)
  LSN 510: page 100 完成
  LSN 520: page 200 完成
  LSN 530: page 300 完成
  → 检查点 LSN 更新到 500（所有写入在 doublewrite 中已标记）
```

---

## 5. 恢复过程

```cpp
// log0recv.cc — 恢复入口
dberr_t recv_recovery_from_checkpoint_start(void) {
  /* ──── 步骤 1：读取检查点信息 ──── */
  /* 从 redo log 文件头读取检查点 LSN 和相关信息 */

  /* ──── 步骤 2：扫描 redo log ──── */
  /* 从检查点 LSN 开始扫描所有 redo 记录 */

  /* ──── 步骤 3：Apply redo log ──── */
  /* 将每条 redo 记录应用到相应的表空间页面 */

  /* ──── 步骤 4：恢复终点 ──── */
  /* 当 redo log 扫描到末尾时，恢复完成 */
  /* 执行 redo 应用后的表空间恢复到崩溃时状态 */

  /* ──── 步骤 5：UNDO 回滚 ──── */
  /* 回滚崩溃时未提交的事务 */
}
```

**恢复时间的决定因素**：

```
恢复时间 ≈ (检查点 LSN 到日志末尾的距离) / (恢复速度)

检查点频率 × 每次刷脏页数 → 影响检查点 LSN 到当前 LSN 的差距
如果检查点不频繁 → 恢复时间长
如果检查点太频繁 → 刷盘 I/O 开销大
```

---

## 6. 配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `innodb_max_dirty_pages_pct` | 90 | 脏页最大百分比（触紧急刷新） |
| `innodb_max_dirty_pages_pct_lwm` | 10 | 脏页低水位（触发自适应刷新） |
| `innodb_adaptive_flushing` | ON | 启用自适应刷新 |
| `innodb_adaptive_flushing_lwm` | 10 | 自适应刷新低水位（% redo log） |
| `innodb_flush_neighbors` | 0(8.0) | 是否一起刷新相邻页面 |
| `innodb_io_capacity` | 200 | 后台 I/O 吞吐估算 |
| `innodb_io_capacity_max` | 2000 | 后台 I/O 最大吞吐 |

---

## 7. 源码索引

| 函数/结构 | 文件 | 关键作用 |
|-----------|------|---------|
| `log_checkpoint()` | `log0log.cc` | 检查点主入口 |
| `buf_flush_page_cleaner_thread()` | `buf0flu.cc` | 页面清理线程 |
| `af_get_pages_for_flush()` | `buf0flu.cc` | 自适应刷页估算 |
| `buf_get_modified_ratio_pct()` | `buf0buf.cc` | 脏页比例计算 |
| `log_write_checkpoint_info()` | `log0write.cc` | 写入检查点信息 |
| `recv_recovery_from_checkpoint_start()` | `log0recv.cc` | 崩溃恢复入口 |
| `log_files_release_before()` | `log0log.cc` | 截断日志文件 |
