# 48 — Data Checkpoint — 数据检查点与日志截断

> 基于 OceanBase CE 主线源码
> 分析入口：`src/storage/checkpoint/`（9 个文件）
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

OceanBase 的 LSM-Tree 引擎将数据写入缓存在 Memtable 中，经过冻结（Freeze）后最终持久化为 SSTable。**Data Checkpoint（数据检查点）** 就是协调这个过程的核心模块——它管理所有 Checkpoint 单元的生命周期，推动内存数据落盘，并最终让 PALF 日志可以被安全截断。

### 解决的核心问题

1. **日志空间管理**：PALF 日志持续增长，需要一个 checkpoint SCN 来标识"此 SCN 之前的数据已全部持久化，日志可以截断"
2. **故障恢复起点**：系统崩溃后，从 checkpoint SCN 对应的位置开始回放日志，而非从 PALF 起始位置
3. **数据一致性**：确保 checkpoint SCN 之前的所有数据变更都已持久化到 SSTable，replay 后能得到正确状态
4. **协调多类型 Checkpoint 单元**：内存中有 TX Ctx Memtable、TX Data Memtable、Lock Memtable、MDS Table、Data Memtable 等多种 Checkpoint 单元，各有不同的冻结和 flush 路径

### 与前文的关联

| 前文 | 关联点 |
|------|--------|
| **文章 06（Freezer）** | Memtable 冻结完成后通过 `ObFreezeCheckpoint` 注册到 `ObDataCheckpoint`，由 Data Checkpoint 调度 flush |
| **文章 13（Clog）** | 日志回放的起点取决于 checkpoint SCN；`ObCheckpointExecutor::update_clog_checkpoint()` 负责将 checkpoint 位置写回 LS Meta |
| **文章 34（SSTable Merge）** | Mini Merge 的输入是 Data Checkpoint flush 出的 Mini SSTable；Merge 完成后 checkpoint SCN 推进 |
| **文章 47（Locality）** | LS 级别的副本分布不直接影响 checkpoint，但影响故障恢复时的数据分布 |

### 模块架构总览

```
                     ObCheckPointService（Timers & Task Scheduler）
                                │
                   ┌────────────┴────────────┐
                   │                         │
          ObCheckpointExecutor          ObDataCheckpoint
          (日志截断主控)                   (数据持久化调度)
                   │                         │
                   │              ┌──────────┼──────────┐
                   ▼              ▼          ▼          ▼
             PALF Log      ObFreezeCheckpoint（各 Checkpoint 单元）
                                    │
                        ┌───────────┼───────────┐
                        ▼           ▼           ▼
                   TX Data     TX Ctx      Lock Memtable
                   Memtable    Memtable      / MDS Table
```

---

## 1. 核心数据结构

### 1.1 `ObCommonCheckpoint` — 检查点基类

`ObCommonCheckpoint`（`ob_common_checkpoint.h:88-102`）是所有检查点单元的抽象基类，定义了两个核心接口：

```cpp
// ob_common_checkpoint.h:88-102 — doom-lsp 确认
class ObCommonCheckpoint
{
public:
  virtual share::SCN get_rec_scn() = 0;       // @L91 — 获取当前检查点记录的 SCN
  virtual int flush(share::SCN recycle_scn,    // @L92 — 触发 flush，推进到 recycle_scn
                    const int64_t trace_id,
                    bool need_freeze = true) = 0;
  virtual ObTabletID get_tablet_id() const = 0; // @L94
  virtual bool is_flushing() const = 0;         // @L100
};
```

Checkpoint 类型枚举（`ob_common_checkpoint.h:28-38` — doom-lsp 确认）标识了不同类型的 Checkpoint 单元：

```cpp
enum ObCommonCheckpointType
{
  INVALID_BASE_TYPE = 0,
  TX_CTX_MEMTABLE_TYPE,    // @L31 — 事务上下文 Memtable（事务层内部状态）
  TX_DATA_MEMTABLE_TYPE,   // @L32 — 事务数据 Memtable（行数据）
  LOCK_MEMTABLE_TYPE,      // @L33 — 锁 Memtable（行锁状态）
  MDS_TABLE_TYPE,          // @L34 — MDS（元数据服务）表
  DATA_CHECKPOINT_TYPE,    // @L35 — Data Checkpoint 自身
  TEST_COMMON_CHECKPOINT,  // @L37 — 单元测试
  MAX_BASE_TYPE
};
```

每种类型通过 `ObCheckpointExecutor` 注册自己的 `ObICheckpointSubHandler`，由执行器统一回调 flush。

### 1.2 `ObFreezeCheckpoint` — 可冻结的 Checkpoint 单元

`ObFreezeCheckpoint`（`ob_freeze_checkpoint.h:81-130`）继承自 `ObDLinkBase`（双向链表节点），是**可冻结**的 Checkpoint 单元基类。`ObITabletMemtable` 继承自它，这意味着每个 Memtable 实例本身就是一个 Checkpoint 单元。

```cpp
// ob_freeze_checkpoint.h:81-130 — doom-lsp 确认
class ObFreezeCheckpoint : public common::ObDLinkBase<ObFreezeCheckpoint>
{
  // ════════ 位置枚举（DataCheckpoint 中的链表位置）════════
  // LS_FROZEN  = 1  在 ls_frozen_list 中（刚冻结，等待处理）
  // NEW_CREATE = 2  在 new_create_list 中（新创建，rec_scn 可能未稳定）
  // ACTIVE     = 4  在 active_list 中（rec_scn 稳定，数据仍可能写入）
  // PREPARE    = 8  在 prepare_list 中（就绪，随时可 flush 到 SSTable）
  // OUT        = 16 已摘除（已 flush 完成）

  ObFreezeCheckpointLocation location_;          // @L119 — 当前所在链表位置
  ObDataCheckpoint *data_checkpoint_;            // @L120 — 所属的 DataCheckpoint

  virtual bool rec_scn_is_stable() = 0;          // @L96 — rec_scn 是否不再变小
  virtual bool ready_for_flush() = 0;            // @L98 — 是否满足 flush 条件
  virtual bool is_frozen_checkpoint() = 0;       // @L100 — 是否是已冻结的 checkpoint
  virtual bool is_active_checkpoint() = 0;       // @L102 — 是否是活跃 checkpoint（无需 flush）
  virtual int flush(share::ObLSID ls_id) = 0;    // 实际执行 flush 到 SSTable
  virtual int finish_freeze();                   // @L110 — 冻结完成，转移到 prepare_list

  int add_to_data_checkpoint(ObDataCheckpoint *data_checkpoint);  // @L106 — 注册到 DataCheckpoint
  bool is_in_prepare_list_of_data_checkpoint();  // @L107 — 是否已在 prepare_list 中
};
```

**位置枚举（`ObFreezeCheckpointLocation`）** 使用 1/2/4/8 的幂 2 编码（`ob_freeze_checkpoint.h:31-37`），这允许通过位掩码同时锁定多个链表：

```cpp
enum ObFreezeCheckpointLocation
{
  LS_FROZEN   = 1,   // bit 0
  NEW_CREATE  = 2,   // bit 1
  ACTIVE      = 4,   // bit 2
  PREPARE     = 8,   // bit 3
  OUT         = 16,  // bit 4（摘除状态，不属于任何链表）
};
```

### 1.3 `ObDataCheckpoint` — 数据检查点调度器

`ObDataCheckpoint`（`ob_data_checkpoint.h:74-228`）继承自 `ObCommonCheckpoint`，是 Data Checkpoint 的核心调度器。它管理 4 个双向链表（`ObCheckpointDList`），每个链表持有 `ObFreezeCheckpoint` 节点：

```cpp
// ob_data_checkpoint.h:74-228 — doom-lsp 确认
class ObDataCheckpoint : public ObCommonCheckpoint
{
  // ════════ 4 个核心链表 ════════
  ObCheckpointDList new_create_list_;    // @L205 — 新创建的 checkpoint，rec_scn 可能未稳定（无序）
  ObCheckpointDList active_list_;        // @L206 — rec_scn 已稳定，等待冻结决定（有序）
  ObCheckpointDList prepare_list_;       // @L207 — 就绪可 flush（有序，按 rec_scn 升序）
  ObCheckpointDList ls_frozen_list_;     // @L210 — 临时缓冲区，LS freeze 期间中转用

  // ════════ 每个 checkpoint 区域有独立的读写锁 ════════
  struct ObCheckpointLock {
    common::SpinRWLock ls_frozen_list_lock_;     // @L215
    common::SpinRWLock new_create_list_lock_;    // @L216
    common::SpinRWLock active_list_lock_;        // @L217
    common::SpinRWLock prepare_list_lock_;       // @L218
  } lock_;                                       // @L223

  // ════════ 关键方法 ════════
  int flush(share::SCN recycle_scn,              // @L121 — 外部入口：推进 checkpoint 到 recycle_scn
            int64_t trace_id, bool need_freeze = true);
  int ls_freeze(share::SCN rec_scn);             // @L125 — LS 级冻结入口
  void road_to_flush(share::SCN rec_scn);        // @L127 — 推进所有链表中的 checkpoint 到可 flush 状态
  share::SCN get_rec_scn();                      // @L117 — 所有链表中最小的 rec_scn（即当前 checkpoint 位置）
  share::SCN get_active_rec_scn();               // @L118 — 仅 new_create + active 链表的最小 rec_scn

  static const int64_t LOOP_TRAVERSAL_INTERVAL_US = 50000;  // @L188 — 50ms
  static const int64_t TABLET_FREEZE_PERCENT = 10;           // @L192 — Tablet 冻结阈值
  static const int64_t MAX_FREEZE_CHECKPOINT_NUM = 50;       // @L195 — 最大 checkpoint 数
};
```

### 1.4 `ObCheckpointExecutor` — 检查点执行器

`ObCheckpointExecutor`（`ob_checkpoint_executor.h:60-126`）负责**协调所有 Checkpoint 单元的推进**，并最终更新 PALF 日志的 checkpoint 位置：

```cpp
// ob_checkpoint_executor.h:60-126 — doom-lsp 确认
class ObCheckpointExecutor
{
  ObLS *ls_;                                             // @L107 — 所属 LS
  logservice::ObILogHandler *loghandler_;                // @L108 — PALF 日志处理器
  ObICheckpointSubHandler *handlers_[MAX_LOG_BASE_TYPE]; // @L109 — 已注册的 handler 数组

  // ════════ 关键接口 ════════
  int register_handler(const ObLogBaseType &type,         // @L73 — 注册 checkpoint 子 handler
                       ObICheckpointSubHandler *handler);
  int update_clog_checkpoint();                            // @L77 — 更新日志 checkpoint SCN
  int advance_checkpoint_by_flush(const share::SCN input_recycle_scn);  // @L84 — 通过 flush 推进 checkpoint
  void get_min_rec_scn(int &log_type, share::SCN &min_rec_scn);        // @L91 — 获取最小 rec_scn

  // ════════ 内部方法 ════════
  int calculate_recycle_scn_(const SCN max_decided_scn, SCN &recycle_scn);             // @L99
  int calculate_min_recycle_scn_(const palf::LSN clog_checkpoint_lsn, SCN &min_recycle_scn); // @L100
  int calculate_expected_recycle_scn_(const palf::LSN clog_checkpoint_lsn, SCN &expected_recycle_scn); // @L101
  int check_need_flush_(const SCN max_decided_scn, const SCN recycle_scn);              // @L98

  static const int64_t CLOG_GC_PERCENT = 60;  // @L104 — 日志 GC 百分比阈值
};
```

### 1.5 `ObCheckpointDList` 与 `ObCheckpointIterator`

`ObCheckpointDList`（`ob_data_checkpoint.h:33-53`）是对 `ObDList<ObFreezeCheckpoint>` 的包装，提供有序/无序插入、min rec_scn 查找等功能：

```cpp
struct ObCheckpointDList
{
  ObDList<ObFreezeCheckpoint> checkpoint_list_;  // @L53 — 实际链表

  int insert(ObFreezeCheckpoint *item, bool ordered = true);  // @L44 — 有序/无序插入
  share::SCN get_min_rec_scn_in_list(bool ordered = true);    // @L46 — 获取最小 rec_scn
  ObFreezeCheckpoint *get_first_greater(const share::SCN rec_scn);  // @L47 — 二分查找
  int get_need_freeze_checkpoints(const share::SCN rec_scn,         // @L50 — 批量获取待冻结 checkpoint
                                  ObIArray<ObFreezeCheckpoint*> &fcs);
};
```

`ObCheckpointIterator` 提供迭代器模式，遍历链表中的 checkpoint 节点（`ob_data_checkpoint.h:57-70`）。

---

## 2. 检查点推进流程

### 2.1 整体状态迁移

每个 `ObFreezeCheckpoint` 在 `ObDataCheckpoint` 中的状态流转是一个**四阶段流水线**：

```
                    ┌──────────┐
                    │ Memtable │
                    │  创建时   │
                    └────┬─────┘
                         │ add_to_data_checkpoint()
                         ▼
               ┌─────────────────┐
               │  NEW_CREATE_LIST │  rec_scn 可能未稳定
               │  （无序链表）     │  · rec_scn_is_stable() = false
               └────────┬────────┘
                    │ check_can_move_to_active_in_newcreate()
                    ▼
               ┌─────────────────┐
               │   ACTIVE_LIST    │  rec_scn 已稳定，等待冻结
               │   （有序链表）     │  · rec_scn_is_stable() = true
               └────────┬────────┘
                    │ ls_freeze() 触发
                    ▼
               ┌─────────────────┐
               │  LS_FROZEN_LIST  │  中转缓冲区
               │   （有序链表）     │  · road_to_flush() 处理
               └────────┬────────┘
                    │ ready_for_flush() = true
                    ▼
               ┌─────────────────┐
               │  PREPARE_LIST    │  就绪，等待 flush
               │   （有序链表）     │  · traversal_flush_() 处理
               └────────┬────────┘
                    │ flush() 完成
                    ▼
               ┌─────────────────┐
               │      OUT         │  已从 DataCheckpoint 摘除
               │    （结束状态）    │  · remove_from_data_checkpoint()
               └─────────────────┘
```

### 2.2 `road_to_flush()` — 核心推进方法

`ObDataCheckpoint::road_to_flush()`（`ob_data_checkpoint.cpp:191-227`）是 LS freeze 完成后的主要推进路径。它按顺序执行 5 个子步骤：

```cpp
// ob_data_checkpoint.cpp:191-227 — doom-lsp 确认
void ObDataCheckpoint::road_to_flush(SCN rec_scn)
{
  // Step 1: new_create_list → ls_frozen_list
  // 将 new_create_list 中所有 checkpoint 批量迁到 ls_frozen_list
  pop_new_create_to_ls_frozen_();                          // @L205

  // Step 2: ls_frozen_list → active_list
  // 遍历 ls_frozen_list，rec_scn 已稳定的移到 active_list，
  // 是 active_checkpoint 的退回 new_create_list 等待下次冻结
  ls_frozen_to_active_(last_time);                          // @L210

  // Step 3: active_list → ls_frozen_list
  // 将 active_list 中 rec_scn <= rec_scn 的 checkpoint
  // 移到 ls_frozen_list（即只保留 rec_scn 更大的）
  pop_active_list_to_ls_frozen_(last);                      // @L215

  // Step 4: 收集诊断信息
  add_diagnose_info_for_ls_frozen_();                        // @L218

  // Step 5: ls_frozen_list → prepare_list
  // 遍历 ls_frozen_list，ready_for_flush() 为 true 的
  // 通过 finish_freeze() 移到 prepare_list
  ls_frozen_to_prepare_(last_time);                          // @L222
  set_ls_freeze_finished_(true);                             // @L226
}
```

#### Step 1: `pop_new_create_to_ls_frozen_()`（`ob_data_checkpoint.cpp:229-246`）

```
          new_create_list                          ls_frozen_list
  ┌──────────────────────┐    transfer_()    ┌──────────────────────┐
  │ Checkpoint_A (S1)    │ ──────────────────→│ Checkpoint_A (S1)    │
  │ Checkpoint_B (S2)    │ ──────────────────→│ Checkpoint_B (S2)    │
  │ Checkpoint_C (S3)    │ ──────────────────→│ Checkpoint_C (S3)    │
  └──────────────────────┘   批量全移          └──────────────────────┘
```

将 new_create_list 的所有 checkpoint 一次性迁移到 ls_frozen_list。这个操作持 WLOCK(LS_FROZEN | NEW_CREATE)，确保原子性。

#### Step 2: `ls_frozen_to_active_()`（`ob_data_checkpoint.cpp:261-317`）

遍历 ls_frozen_list，对每个 checkpoint 做分类处理：

```
  ls_frozen_list
  ┌──────────────────────┐
  │ Checkpoint_A (S1)    │──→ is_active_checkpoint() = true
  │                      │    └→ 退回 new_create_list（避免阻塞 minor merge）
  │ Checkpoint_B (S2)    │──→ rec_scn_is_stable() = true
  │                      │    └→ active_list（进入等待）
  │ Checkpoint_C (S3)    │──→ 两者都不是 → 等待（rec_scn 未稳定）
  └──────────────────────┘
```

**关键设计**：`is_active_checkpoint()` 返回 true 的 checkpoint 会被退回 `new_create_list`，而不是留在 ls_frozen_list 中继续等待。这是因为活跃 checkpoint 不应阻塞 LS freeze 推进，退回到 new_create_list 后会在下次 freeze 时重新进入。

这个步骤是**忙等待循环**，每隔 50ms（`LOOP_TRAVERSAL_INTERVAL_US`）检查一次 ls_frozen_list 是否清空，超时 3 秒会打印告警日志（`ob_data_checkpoint.cpp:292`）。

#### Step 3: `pop_active_list_to_ls_frozen_()`（`ob_data_checkpoint.cpp:248-259`）

将 active_list 中 `rec_scn <= rec_scn`（传入的目标 SCN）的所有 checkpoint 迁移到 ls_frozen_list：

```
  active_list（有序, 按 rec_scn 升序）
  ┌──────────────────────────────┐
  │ Checkpoint_D (S1)            │──→ pop to ls_frozen_list
  │ Checkpoint_E (S2)            │──→ pop to ls_frozen_list
  │ Checkpoint_F (S3 = rec_scn)  │──→ pop to ls_frozen_list
  ├──────────────────────────────┤
  │ Checkpoint_G (S4)            │──→ 保留（S4 > rec_scn）
  │ Checkpoint_H (S5)            │──→ 保留
  └──────────────────────────────┘
```

使用 `get_first_greater(rec_scn)` 二分查找找到分界点，然后将分界点之前的所有节点批量迁移。

#### Step 4: `ls_frozen_to_prepare_()`（`ob_data_checkpoint.cpp:319-376`）

遍历 ls_frozen_list，`ready_for_flush()` 为 true 的通过 `finish_freeze()` 迁移到 prepare_list：

```cpp
// ob_data_checkpoint.cpp:342-359 — doom-lsp 确认
if (ob_freeze_checkpoint->ready_for_flush()) {
  if (OB_FAIL(ob_freeze_checkpoint->finish_freeze())) {
    // 迁移到 prepare_list
  }
} else if (ob_freeze_checkpoint->is_active_checkpoint()) {
  // 退回 active_list，避免阻塞
  transfer_from_ls_frozen_to_active_without_src_lock_();
}
```

**准备 flush 的条件**（来自 `ObMemtable::ready_for_flush()`）：
1. `is_frozen_memtable()` — Memtable 已被冻结标记
2. `write_ref_cnt == 0` — 无正在执行的写入操作
3. `unsubmitted_cnt == 0` — 无未提交的日志
4. 被冻结 Memtable 的边界 SCN 不超过 LS 的右边界

### 2.3 `flush()` — 外部入口

`ObDataCheckpoint::flush()`（`ob_data_checkpoint.cpp:122-155`）是 Data Checkpoint 对外的统一 flush 接口，由 `ObCheckPointService` 的定时任务调用：

```cpp
// ob_data_checkpoint.cpp:122-155 — doom-lsp 确认
int ObDataCheckpoint::flush(SCN recycle_scn, int64_t trace_id, bool need_freeze)
{
  if (is_tenant_freeze()) {
    // 租户级全局冻结 → 直接触发 logstream_freeze
    ls_->logstream_freeze(...);
  } else if (need_freeze) {
    SCN active_rec_scn = get_active_rec_scn();
    if (active_rec_scn > recycle_scn) {
      // active 链表中最小的 rec_scn 已经超过 recycle_scn → 无需冻结
      return;
    }
    // 按需冻结：选择 logstream_freeze 或 tablet_freeze
    freeze_base_on_needs_(trace_id, recycle_scn);
  } else {
    // 仅执行 prepare_list 的 flush
    traversal_flush_();
  }
}
```

### 2.4 按需冻结策略：`freeze_base_on_needs_()`

`freeze_base_on_needs_()`（`ob_data_checkpoint.cpp:439-477`）实现了**智能冻结选择**——根据待冻结 checkpoint 的比例决定采用 LS Freeze（全量）还是 Tablet Freeze（部分）：

```cpp
// ob_data_checkpoint.cpp:439-477 — doom-lsp 确认
int ObDataCheckpoint::freeze_base_on_needs_(int64_t trace_id, SCN recycle_scn)
{
  int64_t wait_flush_num = new_create_list + active_list 的 checkpoint 总数;
  bool logstream_freeze = true;

  if (wait_flush_num > MAX_FREEZE_CHECKPOINT_NUM) {       // @L452 — > 50 个才检查
    get_need_flush_tablets_(recycle_scn, need_flush_tablets);
    int need_flush_num = need_flush_tablets.count();
    // 如果待 flush 比例 < TABLET_FREEZE_PERCENT(10%) → 使用精确的 Tablet Freeze
    logstream_freeze = (need_flush_num * 100 / wait_flush_num) > TABLET_FREEZE_PERCENT;
  }

  if (logstream_freeze) {
    ls_->logstream_freeze(...);    // 全 LS 冻结（大范围）
  } else {
    ls_->tablet_freeze(..., need_flush_tablets, ...);  // 仅特定 Tablet 冻结（精准）
  }
}
```

这种设计避免了对少量待冻 checkpoint 进行全 LS 冻结的开销——当需要冻结的 Tablet 数占总数的比例低于 10% 时，使用 Tablet Freeze 替代 Logstream Freeze。

---

## 3. 日志截断机制

### 3.1 `ObCheckpointExecutor` 的角色

`ObCheckpointExecutor` 是连接 Data Checkpoint 与 PALF 日志截断的桥梁。它协调所有已注册的 Checkpoint SubHandler（包括 Data Checkpoint、TX Ctx Memtable 等），推进最小的 rec_scn，并将其设为 PALF 的 checkpoint 位置。

**Handler 注册机制**（`ob_checkpoint_executor.cpp:48-69`）：

```cpp
// ob_checkpoint_executor.cpp:48-69 — doom-lsp 确认
int ObCheckpointExecutor::register_handler(
    const ObLogBaseType &type,
    ObICheckpointSubHandler *handler)
{
  handlers_[type] = handler;  // 按类型索引存储
}

// unregister_handler 将对应位置置 NULL
```

### 3.2 `update_clog_checkpoint()` — 日志 checkpoint 更新

`ObCheckpointExecutor::update_clog_checkpoint()`（`ob_checkpoint_executor.cpp:140-200`）是日志截断的核心路径：

```cpp
// ob_checkpoint_executor.cpp:140-200 — doom-lsp 确认
int ObCheckpointExecutor::update_clog_checkpoint()
{
  // Step 1: 从 Freezer 获取最大连续回调 SCN
  SCN max_decided_scn;
  freezer->get_max_consequent_callbacked_scn(max_decided_scn);  // @L155

  // Step 2: 收集所有 Handler 的最小 rec_scn，与 max_decided_scn 取最小值
  SCN checkpoint_scn = max_decided_scn;                         // @L164
  get_min_rec_scn(min_rec_scn_service_type_index, checkpoint_scn); // @L165
  // checkpoint_scn = min(max_decided_scn, min(所有 handler.rec_scn))

  // Step 3: 对比当前 LS Meta 中的 checkpoint SCN
  const SCN checkpoint_scn_in_ls_meta = ls_->get_clog_checkpoint_scn(); // @L169

  // Step 4: 通过 PALF 定位 checkpoint SCN 对应的 LSN
  loghandler_->locate_by_scn_coarsely(checkpoint_scn, clog_checkpoint_lsn); // @L179

  // Step 5: 写回 LS Meta（写入 SLOG 持久化）
  ls_->set_clog_checkpoint(clog_checkpoint_lsn, checkpoint_scn, true); // @L187
}
```

关键逻辑：`checkpoint_scn = min(max_decided_scn, min(所有 handler.rec_scn))`。这意味着 checkpoint 位置受限于两个因素：

1. **最大已决定的日志 SCN** — Freezer 保证所有在此 SCN 之前的日志事务都已 callback
2. **所有 Checkpoint 单元的最小 rec_scn** — 所有内存状态都已持久化到 SSTable

### 3.3 `advance_checkpoint_by_flush()` — 通过 flush 推进

`advance_checkpoint_by_flush()`（`ob_checkpoint_executor.cpp:202-236`）在日志磁盘压力大时主动触发，**优先通过 flush 推进 checkpoint**以避免日志磁盘写满：

```cpp
// ob_checkpoint_executor.cpp:202-236 — doom-lsp 确认
int ObCheckpointExecutor::advance_checkpoint_by_flush(SCN input_recycle_scn)
{
  // Step 1: 获取最大已决策 SCN
  loghandler_->get_max_decided_scn(max_decided_scn);   // @L214

  // Step 2: 计算 recycle_scn（4 种情况，见下文）
  calculate_recycle_scn_(max_decided_scn, recycle_scn); // @L218

  // Step 3: 检查是否需要 flush
  check_need_flush_(max_decided_scn, recycle_scn);      // @L219

  // Step 4: 调用所有 handler 的 flush
  for (int i = 1; i < MAX_LOG_BASE_TYPE; i++) {
    if (handlers_[i] != nullptr) {
      handlers_[i]->flush(recycle_scn);                 // @L225
    }
  }
}
```

#### 3.3.1 `calculate_recycle_scn_()` — 4 种回收 SCN 计算策略

`calculate_recycle_scn_()`（`ob_checkpoint_executor.cpp:291-345`）实现了 4 种不同场景下的回收 SCN 计算方式：

```
CASE 1: checkpoint 未推进，复用上次的 recycle_scn
  ┌────────────────────────────────────────────┐
  │ prev_clog_checkpoint_lsn == clog_checkpoint_lsn  │
  │ → 使用上次的 prev_recycle_scn 再试一次           │
  │ → 超过 1000 次复用 → 强制设为 MAX SCN          │
  └────────────────────────────────────────────┘

CASE 2: min_recycle_scn > max_decided_scn（跳过本轮）
  ┌────────────────────────────────────────────┐
  │ checkpoint_lsn ──── min_recycle_lsn ─── end_lsn  │
  │                           ▲                      │
  │                     max_decided_scn 太靠近左侧   │
  │ → 跳过，等待日志推进                              │
  └────────────────────────────────────────────┘

CASE 3: max_decided_scn < expected_recycle_scn
  ┌────────────────────────────────────────────┐
  │                     max_decided_scn  ── expected_recycle_scn  │
  │ → recycle_scn = max_decided_scn                               │
  │ （用当前已决定的最大 SCN 推进）                                 │
  └────────────────────────────────────────────┘

CASE 4: max_decided_scn ≥ expected_recycle_scn
  ┌────────────────────────────────────────────┐
  │       expected_recycle_scn ── max_decided_scn        │
  │ → recycle_scn = expected_recycle_scn                  │
  │ （目标已低于预期值，用预期值推进）                        │
  └────────────────────────────────────────────┘
```

**CLOG_GC_PERCENT（60%）** 是 `expected_recycle_scn` 的计算依据：`expected_recycle_scn` 对应的是从 checkpoint_lsn 到 end_lsn 的 60% 位置处的 SCN。这意味着日志会被使用到 60% 后才触发回收，留出 40% 的缓冲空间。

#### 3.3.2 `calculate_min_recycle_scn_()` — 最小回收阈值

`calculate_min_recycle_scn_()`（`ob_checkpoint_executor.cpp:378-403`）考虑了多 LS 环境中日志回收的协作问题：

```cpp
// ob_checkpoint_executor.cpp:378-403 — doom-lsp 确认
int64_t ls_min_recycle_clog_percentage =
    MIN(DEFAULT_MIN_LS_RECYCLE_CLOG_PERCENTAGE(5%),     // 单个 LS 至少 5%
        MAX_TENANT_RECYCLE_CLOG_PERCENTAGE(30%) / ls_count);  // 租户级 30% ÷ LS 数
```

**关键设计**：如果租户有 20 个 LS，每个 LS 使用 4.9% 的日志空间，那么总计 98% 的日志空间被使用，但按照旧逻辑（每个 LS 需要达到 5% 才回收）却无法触发任何回收。新逻辑通过 `NEED_FLUSH_CLOG_DISK_PERCENT(30%) / ls_count` 计算出每个 LS 的最小回收阈值为 30% / 20 = 1.5%，确保总能触发日志回收。

---

## 4. 检查点与日志截断的关系

### 4.1 整体数据流

```
                      ╔══════════════════════════════╗
                      ║      用户事务写入 Memtable     ║
                      ╚═══════════════╤══════════════╝
                                      │
                                      ▼
                     ┌─────────────────────────────┐
                     │  ObFreezer 发起 LS Freeze    │
                     │  · freeze_clock + 1          │
                     │  · submit_log_for_freeze()   │
                     └─────────────┬───────────────┘
                                   │
                                   ▼
                    ┌──────────────────────────────┐
                    │  DataCheckpoint 状态转移      │
                    │  road_to_flush(rec_scn)       │
                    │                              │
                    │  NEW_CREATE → LS_FROZEN       │
                    │  LS_FROZEN → ACTIVE          │
                    │  ACTIVE → LS_FROZEN           │
                    │  LS_FROZEN → PREPARE          │
                    └─────────────┬────────────────┘
                                  │
                                  ▼
                    ┌──────────────────────────────┐
                    │  traversal_flush_()           │
                    │  · 遍历 prepare_list          │
                    │  · 执行 ObMemtable::flush()   │
                    │  · 生成 Mini SSTable          │
                    └─────────────┬────────────────┘
                                  │ free_checkpoint() 后
                                  ▼
                    ┌──────────────────────────────┐
                    │  ObCheckpointExecutor         │
                    │  update_clog_checkpoint()     │
                    │                              │
                    │  1. 收集所有 handler 的最小    │
                    │     rec_scn                   │
                    │  2. 取 min(decided_scn,       │
                    │     min_rec_scn)              │
                    │  3. 写回 LS Meta (SLOG)       │
                    └─────────────┬────────────────┘
                                  │
                                  ▼
              ╔═══════════════════════════════════════╗
              ║          PALF 日志截断                 ║
              ║                                       ║
              ║  ┌────┬────┬────┬────┬────┬────┬────┐ ║
              ║  │ S1 │ S2 │ S3 │ S4 │ S5 │ S6 │ S7 │ ║
              ║  └────┴────┴────┴────┴────┴────┴────┘ ║
              ║       ▲                                ║
              ║       │ checkpoint_scn = S5             ║
              ║       │ → S1~S5 可安全截断             ║
              ╚═══════╧═══════════════════════════════╝
```

### 4.2 Checkpoint SCN 的推进策略

Checkpoint SCN 的推进受两个因素共同约束：

```
checkpoint_scn = min(max_decided_scn, min_handler_rec_scn)
                    │                    │
                    ▼                    ▼
              Freezer 保证               各 Checkpoint 单元
              所有此 SCN 之前的           的最小 rec_scn
              日志已 callback             （表示已 flush 完成的最大 SCN）
```

**为什么需要取两者最小值？**
- 即便所有内存数据都已持久化（handler_rec_scn 很大），如果 max_decided_scn 很小（日志尚未全部 callback），checkpoint 推进可能导致丢失未 callback 的日志
- 反之，即便所有日志都已 callback（max_decided_scn 很大），如果有内存数据尚未持久化（handler_rec_scn 较小），checkpoint 推进会导致重启时数据不一致

---

## 5. 并发控制

### 5.1 细粒度读写锁

`ObDataCheckpoint` 使用 4 个 `SpinRWLock` 分别保护 4 个链表（`ob_data_checkpoint.h:212-223`）：

```cpp
struct ObCheckpointLock {
  common::SpinRWLock ls_frozen_list_lock_;      // bit 0
  common::SpinRWLock new_create_list_lock_;     // bit 1
  common::SpinRWLock active_list_lock_;         // bit 2
  common::SpinRWLock prepare_list_lock_;        // bit 3
};
```

`ObCheckpointLockGuard`（`ob_data_checkpoint.h:238-304`）通过位掩码实现**多锁一次性获取/释放**：

```cpp
#define RLOCK(flag) ObCheckpointLockGuard lock_guard(*this, ~0x80 & flag, "[data_checkpoint]")
#define WLOCK(flag) ObCheckpointLockGuard lock_guard(*this, 0x80 | flag, "[data_checkpoint]")
```

- `flag` 的 bit 0-3 指示要锁哪些链表（LS_FROZEN / NEW_CREATE / ACTIVE / PREPARE）
- bit 7（`0x80`）区分读锁/写锁
- 例如 `WLOCK(LS_FROZEN | ACTIVE)` 同时对 ls_frozen_list 和 active_list 加写锁

**锁顺序**：构造函数中按 LS_FROZEN → NEW_CREATE → ACTIVE → PREPARE 的顺序加锁，析构函数中逆序释放，避免死锁。

### 5.2 `unlink_()` 的乐观实现

`ObDataCheckpoint::unlink_()`（`ob_data_checkpoint.cpp:401-426`）处理了 checkpoint 在竞争中被移动的竞态条件：

```cpp
// ob_data_checkpoint.cpp:401-426 — doom-lsp 确认
do {
  WLOCK(location);
  // double check: 获取锁后验证 location 是否变化
  if (ob_freeze_checkpoint->location_ == location) {
    // 安全摘除
    list->unlink(ob_freeze_checkpoint);
  } else {
    ret = OB_EAGAIN;  // 位置已变化，重试
  }
} while (OB_EAGAIN == ret);
```

这种**乐观锁重试模式**在处理竞态时很常见——先假设位置不变，加锁后 double-check，若已变化则释放锁重试。

---

## 6. 与前面文章的关联

### 6.1 文章 06（Freezer）— 冻结触发

Freezer 负责识别需要冻结的 Memtable 并发出冻结命令。Data Checkpoint 是 Freezer 的**下游**：

- Freezer 通过 `ObFreezeCheckpoint::add_to_data_checkpoint()` 将冻结后的 Memtable 注册到 DataCheckpoint 的 `new_create_list`
- Freezer 的 `submit_checkpoint_task()` 触发 `ObDataCheckpoint::ls_freeze()`
- Freezer 的 `max_decided_scn` 被 `ObCheckpointExecutor` 用来计算 checkpoint SCN 的上限

```
  Freezer                          DataCheckpoint
 ┌──────────┐                    ┌──────────────────┐
 │ Freeze   │─ add_to_data_─→     │ new_create_list   │
 │ Memtable │  checkpoint()       │                  │
 └──────────┘                    │ road_to_flush()   │
                                 │ ls_frozen_list    │
                                 │ active_list       │
                                 │ prepare_list      │
                                 └──────────────────┘
```

### 6.2 文章 13（Clog）— 日志回放

Clog（PALF 日志）是故障恢复的基石。Data Checkpoint 提供了**日志回放的起点**：

- 重启时，LS 从 `clog_checkpoint_lsn` 位置开始回放日志
- `checkpoint_scn` 之前的日志可以安全截断，因为数据已持久化到 SSTable
- 回放只需要 replay `checkpoint_scn` 之后的日志，缩短了恢复时间

### 6.3 文章 34（SSTable Merge）— 合并策略

SSTable Merge 消费 Data Checkpoint 的产出：

- `ObDataCheckpoint::traversal_flush_()` 中执行 `tablet_memtable->flush()` 生成 Mini SSTable
- Mini SSTable 作为 Mini Merge 的输入，最终合并为更高层次的 SSTable
- Merge 完成后推进 `rec_scn`，使 Data Checkpoint 可以推进 checkpoint

---

## 7. 设计决策

### 7.1 Data Checkpoint vs Freeze Checkpoint

| 维度 | Data Checkpoint | Freeze Checkpoint |
|------|-----------------|-------------------|
| 基类 | `ObCommonCheckpoint` | `ObFreezeCheckpoint`（继承 `ObDLinkBase`） |
| 是否可冻结 | 否（调和调度器） | 是（每个 Memtable 实例） |
| 生命周期 | 与 LS 共存亡 | 与 Memtable 绑定 |
| 是否有链表演进 | 管理其他 checkpoint 的状态转移 | 在 DataCheckpoint 的链表中流转 |
| rec_scn 变化 | 只会推进（always forward） | 冻结后可继续减小（tx_data 的场景） |

### 7.2 四链表设计的意义

Data Checkpoint 使用 4 个链表而非 1 个，核心考量：

1. **减少锁竞争**：不同的操作可以并行操作不同的链表
2. **流水线处理**：每个链表对应一个处理阶段，可以批量处理（如 `pop_new_create_to_ls_frozen_` 一次转移整个链表）
3. **细粒度调度控制**：`road_to_flush` 可以独立控制每个阶段的节奏，插入了诊断和超时检测

### 7.3 检查点对故障恢复速度的影响

Checkpoint SCN 越接近最新日志，重启后需要回放的日志越少，恢复速度越快。但推进 checkpoint 需要：
- 冻结所有 need-freeze 的 Memtable（耗时取决于写入负载）
- 等待 frozen Memtable 达到 `ready_for_flush` 条件（取决于写入引用计数）
- flush 到 SSTable（I/O 耗时）

OceanBase 通过两个策略平衡推进速度和日志安全：
1. **`CLOG_GC_PERCENT = 60%`** — 日志使用到 60% 才触发回收，留出 40% 缓冲（约 320MB × 40% 的日志空间）
2. **`advance_checkpoint_by_flush()`** — 在日志磁盘压力较大时主动调用 `handlers_[i]->flush()` 推进

### 7.4 Table Freeze vs Logstream Freeze 的选择

`freeze_base_on_needs_()` 中的二分选择（`ob_data_checkpoint.cpp:439-477`）：

- **Logstream Freeze**：冻结 LS 中所有 Tablet 的 Memtable，写冻结日志，范围大但可能"大炮打蚊子"
- **Tablet Freeze**：只冻结特定 Tablet 的 Memtable，更精准但需要额外计算目标

当需要冻结的 Tablet 占总数 < 10%（`TABLET_FREEZE_PERCENT`）时，选择 Tablet Freeze。这个阈值是静态的，未来可以根据实际负载自适应调整。

---

## 8. 源码索引

| 文件 | 行数 | 职责 |
|------|------|------|
| `storage/checkpoint/ob_common_checkpoint.h` | ~110 | Checkpoint 基类、类型枚举、VTInfo |
| `storage/checkpoint/ob_data_checkpoint.h` | ~320 | Data Checkpoint 主实现（含 CheckpointDList/Iterator/LockGuard） |
| `storage/checkpoint/ob_data_checkpoint.cpp` | ~480 | Data Checkpoint 实现：状态转移、flush 调度、按需冻结 |
| `storage/checkpoint/ob_freeze_checkpoint.h` | ~130 | Freeze Checkpoint 单元基类、位置枚举 |
| `storage/checkpoint/ob_freeze_checkpoint.cpp` | ~60 | Freeze Checkpoint 实现：注册、摘除 |
| `storage/checkpoint/ob_checkpoint_executor.h` | ~130 | Checkpoint 执行器：日志截断主控 |
| `storage/checkpoint/ob_checkpoint_executor.cpp` | ~410 | 执行器实现：update_clog_checkpoint、advance_checkpoint_by_flush |
| `storage/checkpoint/ob_checkpoint_diagnose.h` | ~60 | 诊断结构体 |
| `storage/tx_storage/ob_checkpoint_service.h` | ~250 | CheckPoint Service（定时任务调度器） |
| `storage/tx_storage/ob_checkpoint_service.cpp` | ~500 | 定时任务：checkpoint、traversal_flush、clog_disk_usage 检查 |

**关键常量汇总**：

| 常量 | 值 | 位置 | 含义 |
|------|-----|------|------|
| `LOOP_TRAVERSAL_INTERVAL_US` | 50000 (50ms) | `ob_data_checkpoint.h:188` | 状态轮询间隔 |
| `TABLET_FREEZE_PERCENT` | 10% | `ob_data_checkpoint.h:192` | Tablet Freeze 触发阈值 |
| `MAX_FREEZE_CHECKPOINT_NUM` | 50 | `ob_data_checkpoint.h:195` | 直接 freeze 的 checkpoint 数上限 |
| `CLOG_GC_PERCENT` | 60% | `ob_checkpoint_executor.h:104` | 日志回收百分比 |
| `ADD_SERVER_HISTORY_INTERVAL` | 10 min | `ob_checkpoint_executor.h:105` | Server Event 记录间隔 |
| `NEED_FLUSH_CLOG_DISK_PERCENT` | 30% | `ob_checkpoint_service.h:87` | 租户级日志回收总阈值 |
| `DEFAULT_MIN_LS_RECYCLE_CLOG_PERCENTAGE` | 5% | `ob_checkpoint_executor.cpp:381` | 单个 LS 的最小回收阈值 |
| `MAX_DATA_CHECKPOINT_FLUSH_COUNT` | 10000 | `ob_data_checkpoint.cpp:341` | 单次 traversal_flush 上限 |

---

## 附录：参考资料

- **文章 06** — Memtable 冻结机制：`06-memtable-freezer-analysis.md`
- **文章 13** — Clog 日志回放：`13-clog-analysis.md`
- **文章 34** — SSTable Merge 策略：`34-sstable-merge-analysis.md`
- **OceanBase 源码**：`src/storage/checkpoint/`
