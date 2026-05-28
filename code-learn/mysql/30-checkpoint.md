# 30. InnoDB 检查点 (Checkpoint)

> 本文分析 InnoDB 检查点机制，包括 Fuzzy Checkpoint、Sharp Checkpoint、自适应调度、检查点写入和崩溃恢复流程。核心文件：`log0chkp.cc`、`log0log.cc`、`log0recv.cc`。

---

## 1. 概述

检查点（Checkpoint）是 InnoDB 崩溃恢复的锚点：它标识 redo log 中 `last_checkpoint_lsn` 之前的修改已全部安全地刷入数据文件。故障恢复时只需从 `last_checkpoint_lsn` 处开始回放 redo record。

InnoDB 支持以下检查点策略：

| 类型 | 触发条件 | 说明 |
|------|----------|------|
| **Fuzzy Checkpoint** | `log_checkpointer` 后台线程周期性执行 | 仅确保 checkpoint_lsn 之前的脏页已刷盘 |
| **Sharp Checkpoint** | 服务器正常关闭（`srv_shutdown`） | 刷所有脏页 |
| **强制 Checkpoint** | redo log 空间不足 | 由 `log_should_checkpoint()` 检测触发 |

---

## 2. 检查点的核心字段

```cpp
// log0log.h — log_t 中检查点相关字段
struct log_t {
  /** 最近一次检查点的 LSN */
  atomic_lsn_t last_checkpoint_lsn;

  /** 最近检查点的完成时间（用于自适应调度） */
  std::chrono::steady_clock::time_point last_checkpoint_time;

  /** 是否允许做检查点（关闭过程中禁用） */
  bool m_allow_checkpoints;
};
```

---

## 3. 检查点线程执行流程

`log_checkpointer` 后台线程调用 `log_checkpoint()` 执行实际的检查点操作：

```cpp
// log0chkp.cc:132 — log_checkpoint 线程主入口
// 调用路径：
// log_checkpointer() → log_consider_checkpoint() → log_checkpoint()

// log0chkp.cc:444
static void log_checkpoint(log_t &log) {
  ut_ad(log_checkpointer_mutex_own(log));

  /* Step 1: 确定本次检查点的目标 LSN */
  const lsn_t checkpoint_lsn = log_determine_checkpoint_lsn(log);

  /* Step 2: 刷 page archive 缓存（如启用） */
  if (arch_page_sys != nullptr) {
    arch_page_sys->flush_at_checkpoint(checkpoint_lsn);
  }

  /* Step 3: 对所有脏页执行 fsync（确保数据落盘） */
  buf_flush_fsync();                          // line 461

  /* Step 4: 验证 redo log 已刷到 checkpoint_lsn */
  ut_a(log.flushed_to_disk_lsn.load() >= checkpoint_lsn);

  /* Step 5: 将检查点信息写入 redo log 文件 */
  const dberr_t err = log_files_next_checkpoint(log, checkpoint_lsn); // line 493

  /* Step 6: 更新检查点统计 */
  MONITOR_INC(MONITOR_LOG_CHECKPOINTS);        // line 500
}
```

---

## 4. 检查点调度

### 4.1 是否触发检查点

```cpp
// log0chkp.cc:119
static bool log_should_checkpoint(log_t &log) {
  // 以下任一条件满足时触发：
  // 1. 自上次检查点以来写入的 redo 数据超过阈值（~10% log file size）
  // 2. redo 文件可用空间不足一半
  //   (由 log_free_check / log_write_up_to 检测)
  // 3. 管理员执行 FLUSH LOGS / CHECKPOINT
  // 4. 调用 log_make_latest_checkpoint()
}
```

### 4.2 自适应间隔

```cpp
// log0chkp.cc:136
static std::chrono::steady_clock::duration log_checkpoint_time_elapsed(
    const log_t &log) {
  // 返回自上次检查点以来的时间间隔
  // 调度器使用此值动态调整检查点频率：
  // - 写入压力大 → 缩短间隔
  // - 空闲 → 延长间隔
}
```

### 4.3 请求同步检查点

```cpp
// log0chkp.cc:581
void log_request_checkpoint(log_t &log, bool sync) {
  log_request_checkpoint_low(log, LSN_MAX);    // 请求尽可能高的 LSN

  if (sync) {
    log_wait_for_checkpoint(
        log, log.last_checkpoint_lsn.load());   // 同步等待完成
  }
}
```

---

## 5. 检查点写入

`log_files_next_checkpoint`（`log0chkp.cc:337`）将检查点信息写入 redo log 文件：

### 5.1 文件布局

```
+-------------------+
| Block 0: Header   |  ← LOG_HEADER_SIZE
+-------------------+
| Block 1: Chkpt 1  |  ← 第一个检查点块
+-------------------+
| Block 2: Chkpt 2  |  ← 第二个检查点块（交替写入）
+-------------------+
| Block 3+ : Records |  ← 实际 redo record
+-------------------+
```

双检查点块的交替策略保证原子性：启动时读取序号更**大**的有效检查点。

### 5.2 检查点内容

```cpp
// log0chkp.cc:427
dberr_t log_files_write_checkpoint_low(...) {
  // 写入内容：
  // 1. checkpoint_lsn（检查点 LSN）
  // 2. log file 文件的起始 LSN
  // 3. 校验和（checksum）
  // 4. 序号（双块交替使用）
}
```

---

## 6. 检查点与 flush list

Buffer Pool 中的脏页按照修改时间（LSN 顺序）排列在 **flush list** 中：

```
Flush List（从 old 到 new）：
  ┌─────┐   ┌─────┐   ┌─────┐        ┌─────┐
  │ p1  │ → │ p2  │ → │ p3  │ → ... → │ pN  │
  │LSN  │   │LSN  │   │LSN  │        │LSN  │
  │ 100 │   │ 200 │   │ 300 │        │1000 │
  └─────┘   └─────┘   └─────┘        └─────┘
    oldest_lsn                              newest_lsn
     ↑                                       ↑
  已刷盘区域                              最新修改
  可以推进 checkpoint_lsn
```

`log_determine_checkpoint_lsn()` 读取 flush list 中 `oldest_lsn`，结合已刷盘的 redo，计算安全的 checkpoint_lsn。

---

## 7. 崩溃恢复

```cpp
// log0recv.cc — 恢复入口
recv_recovery_from_checkpoint_start()
  ├─ 打开 redo log 文件
  ├─ Step 1: 读取最后有效的检查点（双块比较序号）
  │   └─ recv_find_start_point()
  │       ├─ 读取 LOG_CHECKPOINT_1 / LOG_CHECKPOINT_2
  │       ├─ 选择序号更大的有效块
  │       └─ 获得 last_checkpoint_lsn
  ├─ Step 2: 从 checkpoint_lsn 开始扫描 redo record
  │   └─ recv_scan_log_recs()
  │       ├─ 读取 redo block
  │       ├─ 解析 MLOG 记录
  │       └─ 应用到 Buffer Pool
  └─ Step 3: 完成后使所有恢复的页可写入
      └─ recv_recovery_finish()
```

---

## 8. 参数调优

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `innodb_log_checkpoint_freq` | 自动 | 每写入多少 redo 后触发一次检查点 |
| `innodb_log_checkpoint_now` | — | 手动触发检查点 |
| `innodb_flush_log_at_trx_commit` | 1 | 事务提交时的刷盘策略，影响检查点推进 |
| `innodb_log_file_size` | 504M | redo 日志总大小，越大检查点间隔越长 |
| `innodb_log_group_home_dir` | ./ | redo 日志文件目录 |

---

## 9. 总结

1. **Fuzzy Checkpoint**：后台线程异步执行，不阻塞用户事务，仅确保 `checkpoint_lsn` 前的脏页已刷盘。
2. **双检查点块交替写入**：`LOG_CHECKPOINT_1` / `LOG_CHECKPOINT_2` 提供写入原子性，启动时读序号大的有效块。
3. **自适应调度**：`log_should_checkpoint` + `log_checkpoint_time_elapsed` 动态调整检查点频率。
4. **Flush List 配合**：脏页按 LSN 排序，`log_determine_checkpoint_lsn()` 使用 `oldest_lsn` 计算可推进点。
5. **崩溃恢复锚点**：`last_checkpoint_lsn` 是 recovery 起点，检查点越新恢复所需回放的 redo 越少。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `log0chkp.cc` | 119 | `log_should_checkpoint()` |
| `log0chkp.cc` | 132 | `log_checkpoint()` 主函数声明 |
| `log0chkp.cc` | 136 | `log_checkpoint_time_elapsed()` |
| `log0chkp.cc` | 337 | `log_files_next_checkpoint()` |
| `log0chkp.cc` | 427 | `log_files_write_checkpoint_low()` |
| `log0chkp.cc` | 444 | `log_checkpoint()` 完整实现 |
| `log0chkp.cc` | 536 | `log_wait_for_checkpoint()` |
| `log0chkp.cc` | 581 | `log_request_checkpoint()` |
| `log0chkp.cc` | 628 | `log_make_latest_checkpoint()` |
