# 06-memtable-freezer — OceanBase Memtable 冻结与 SSTable 持久化

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

OceanBase 的 LSM-Tree 存储引擎将最新写入缓存在 Memtable（内存表）中，通过**冻结（freeze）** 机制将 Memtable 切换到只读状态并最终转换为 SSTable 持久化到磁盘。

### 解决的核心问题

1. **内存有界**：Memtable 不能无限增长，需要周期性冻结以释放内存
2. **快照隔离**：冻结时刻的 `freeze_snapshot_version` 定义了 MVCC 可见性的边界
3. **LSM-Tree 分层**：冻结后的 Memtable 作为 Minor Compaction 的输入，生成 Minor SSTable

### 三种冻结类型

| 类型 | 触发者 | 作用范围 | 频率 | 转换产物 |
|------|--------|---------|------|---------|
| **LS Freeze（Logstream Freeze）** | `ObFreezer::logstream_freeze` | Logstream 内所有 Tablet | 周期性/内存阈值 | Mini SSTable |
| **Tablet Freeze（批量 Tablet 冻结）** | `ObFreezer::tablet_freeze` | 指定 Tablet | 按需（迁移/分裂） | Mini SSTable |
| **Major Freeze** | RootServer 调度 | 全库所有分区 | 全局合并周期 | Major SSTable |

**doom-lsp 确认**：核心冻结代码分布在以下文件：

| 文件 | 行数 | 职责 |
|------|------|------|
| `storage/ls/ob_freezer.h` | ~414 | `ObFreezer` 类声明，冻结协调器 |
| `storage/ls/ob_freezer.cpp` | ~2000+ | 冻结发起、日志提交、等待完成 |
| `storage/ls/ob_freezer_define.h` | ~50 | `ObFreezeSourceFlag` 冻结来源枚举 |
| `storage/ob_i_tablet_memtable.h` | ~480 | `ObITabletMemtable` 冻结状态机 |
| `storage/memtable/ob_memtable.h` | ~611 | `ObMemtable::finish_freeze` 等 |
| `storage/memtable/ob_memtable.cpp` | ~3500+ | `ready_for_flush`, `is_frozen_memtable` 等 |
| `storage/checkpoint/ob_freeze_checkpoint.h` | ~130 | `ObFreezeCheckpoint` Checkpoint 单元基类 |
| `storage/checkpoint/ob_data_checkpoint.h` | ~270 | `ObDataCheckpoint` 调度 flush |

---

## 1. 核心数据结构

### 1.1 `ObFreezeCheckpoint` — Checkpoint 单元基类

```cpp
// ob_freeze_checkpoint.h:81-130 - doom-lsp 确认
class ObFreezeCheckpoint : public common::ObDLinkBase<ObFreezeCheckpoint>
{
  // ════════ 位置枚举 ════════
  // LS_FROZEN  = 1: 刚冻结，在 data_checkpoint 的 frozen_list
  // NEW_CREATE = 2: 新创建
  // ACTIVE     = 4: 活跃，可写入
  // PREPARE    = 8: 就绪可 flush
  // OUT        = 16: 已从 data_checkpoint 摘除

  ObFreezeCheckpointLocation location_;  // @L99 — 在 data_checkpoint 中的位置
  ObDataCheckpoint *data_checkpoint_;    // @L100 — 所属的 data_checkpoint

  virtual bool rec_scn_is_stable() = 0;    // @L105 — rec_scn 是否稳定
  virtual bool ready_for_flush() = 0;      // @L107 — 是否满足 flush 条件
  virtual int flush(share::ObLSID ls_id) = 0;  // @L103 — 执行 flush 到 SSTable
  virtual bool is_frozen_checkpoint() = 0; // @L111 — 是否已冻结
  virtual int finish_freeze();             // @L119 — 冻结完成处理

  int add_to_data_checkpoint(ObDataCheckpoint *data_checkpoint);  // @L114 — 注册到 data_checkpoint
};
```

`ObITabletMemtable` 继承自 `ObFreezeCheckpoint`（`ob_i_tablet_memtable.h:149` — doom-lsp 确认），所以每个 Memtable 实例都天然是一个 Checkpoint 单元，可以被 DataCheckpoint 统一管理。

### 1.2 `TabletMemtableFreezeState` — Memtable 冻结状态机

```cpp
// ob_i_tablet_memtable.h:116-137 - doom-lsp 确认
enum TabletMemtableFreezeState : int64_t {
  INVALID        = 0,   // 未初始化
  ACTIVE         = 1,   // 活跃（可写入）
  FREEZING       = 2,   // 正在冻结中
  READY_FOR_FLUSH = 3,  // 可以持久化到 SSTable
  FLUSHED        = 4,   // 已 flush 完成
  RELEASED       = 5,   // 已释放
  FORCE_RELEASED = 6,   // 强制释放
  MAX_FREEZE_STATE
};
```

状态机流转方向：

```
INVALID → ACTIVE → FREEZING → READY_FOR_FLUSH → FLUSHED → RELEASED
                                                             ↓
                                                      FORCE_RELEASED（异常路径）
```

### 1.3 `ObFreezer` — 冻结协调器

```cpp
// ob_freezer.h:147-270 - doom-lsp 确认
class ObFreezer
{
  uint32_t freeze_flag_;              // @L253 — 最高位: 冻结进行中, 低31位: freeze_clock
  share::SCN freeze_snapshot_version_; // @L256 — 冻结快照版本
  share::SCN max_decided_scn_;        // @L259 — 最大已决定日志 SCN

  ObLS *ls_;                          // @L261 — 所属 LogStream
  ObFreezerStat stat_;                // @L262 — 冻结统计

  // ════════ freeze_clock ════════
  // freeze_flag_ 的低 31 位构成 freeze_clock。
  // 每次冻结开始（set_freeze_flag）时，freeze_clock 递增 1。
  // Memtable 创建时记录当时的 freeze_clock，冻结时通过比较
  // freezer::freeze_clock > memtable::freeze_clock 判断是否需要冻结。
  uint32_t get_freeze_clock() { return ATOMIC_LOAD(&freeze_flag_) & (~(1 << 31)); }
  // @L230

  // ════════ 冻结入口 ════════
  int logstream_freeze(const int64_t trace_id);          // @L153
  int tablet_freeze(const int64_t trace_id,              // @L155
                    const ObIArray<ObTabletID> &tablet_ids,
                    const bool need_rewrite_meta,
                    ObIArray<ObTableHandleV2> &frozen_memtable_handles,
                    ObIArray<ObTabletID> &freeze_failed_tablets);
};
```

**`freeze_flag_` 编码**（ob_freezer.h:249 — doom-lsp 确认）：

```
freeze_flag_ (32-bit) = [1 bit freeze_mark | 31 bits freeze_clock]

freeze_mark（第 31 位）:
  1 = 冻结正在进行中，阻止并发冻结
  0 = 未在进行冻结

freeze_clock（低 31 位）:
  每次 set_freeze_flag() = freeze_clock + 1，表示全 LS 范围的版本推进
```

### 1.4 `ObMemtable` 的冻结相关字段

```cpp
// ob_memtable.h:407-456, 579 - doom-lsp 确认
class ObMemtable : public ObITabletMemtable
{
  // ════════ 冻结状态 ════════
  bool transfer_freeze_flag_;          // @L579 — transfer 冻结标志
  share::SCN recommend_snapshot_version_; // @L 
  // ...（其余字段继承自 ObITabletMemtable）

  // ════════ 冻结方法 ════════
  virtual int set_frozen() override     // @L255
    { local_allocator_.set_frozen(); return OB_SUCCESS; }
  virtual bool is_frozen_memtable() override;  // @L258
  virtual int finish_freeze();                 // @L456
  virtual void set_allow_freeze(const bool allow_freeze) override;  // @L254
};
```

`ObITabletMemtable` 中的冻结相关字段（`ob_i_tablet_memtable.h:427-477` — doom-lsp 确认）：

```cpp
// ob_i_tablet_memtable.h - 冻结相关字段（doom-lsp 确认）
mutable uint32_t freeze_clock_;          // @L427 — 创建时的 freezer_clock 快照
share::SCN freeze_scn_;                  // @L432 — 冻结时的 SCN 边界
bool allow_freeze_ : 1;                  // @L452 — 是否允许冻结
bool is_tablet_freeze_ : 1;             // @L454 — 是否是 tablet 级冻结
TabletMemtableFreezeState freeze_state_; // @L477 — 冻结状态机状态

// 相关访问方法
void set_freeze_clock(const uint32_t freeze_clock)   // @L330
uint32_t get_freeze_clock() const                     // @L365
void set_freeze_state(const TabletMemtableFreezeState state) // @L339
bool allow_freeze() const                             // @L363
void set_is_tablet_freeze(bool is_tablet_freeze)      // @L (通过宏)
```

---

## 2. 数据流：从内存阈值检测到 SSTable

### 2.1 整体流程

```
  ┌────────────────────────────────────────────────────┐
  │  Step 1: 冻结触发                                   │
  │  - 内存阈值（memstore_limit_percentage）             │
  │  - 事务层（冻结旧的 Memtable，创建新的活跃 Memtable）   │
  │  - User/minor/major freeze 命令                     │
  └──────────────────────┬─────────────────────────────┘
                         ▼
  ┌────────────────────────────────────────────────────┐
  │  Step 2: ObFreezer 发起冻结                         │
  │  - set_freeze_flag() → freeze_clock + 1            │
  │  - 记录 freeze_snapshot_version、max_decided_scn     │
  │  - submit_log_for_freeze() → 写冻结日志              │
  └──────────────────────┬─────────────────────────────┘
                         ▼
  ┌────────────────────────────────────────────────────┐
  │  Step 3: Memtable 标记冻结                          │
  │  - is_frozen_memtable() → freezer.freeze_clock      │
  │    与 memtable.freeze_clock 比较                     │
  │  - set_frozen() → local_allocator 标记只读           │
  │  - set_freeze_state(FREEZING)                       │
  └──────────────────────┬─────────────────────────────┘
                         ▼
  ┌────────────────────────────────────────────────────┐
  │  Step 4: ready_for_flush 等待                        │
  │  条件:                                              │
  │  - is_frozen_memtable() == true                     │
  │  - write_ref_cnt == 0（无正在写入的操作）              │
  │  - unsubmitted_cnt == 0（无未提交的日志）              │
  │  - 被冻结 Memtable 的 end_scn <= LS right boundary   │
  └──────────────────────┬─────────────────────────────┘
                         ▼
  ┌────────────────────────────────────────────────────┐
  │  Step 5: flush → SSTable                           │
  │  - DataCheckpoint 调度 flush                       │
  │  - ObMemtableCompactWriter 扫描所有行并编码           │
  │  - 生成 Mini SSTable 数据块                          │
  │  - set_freeze_state(FLUSHED)                       │
  └────────────────────────────────────────────────────┘
```

### 2.2 Step 1: 冻结触发

冻结的触发分为三个层次：

**1) 事务层主动触发（Memstore 内存阈值）**

当活跃 Memtable 的内存使用达到阈值时，`ObTabletMemtableMgr::create_memtable_` 会在创建新 Memtable 之前，检查当前活跃 Memtable 的 `freeze_clock` 是否等于 LS 当前的 `freeze_clock`。如果相等，说明该 Memtable 是在当前冻结周期内创建的，需要先推进 `freeze_clock`（即发起新冻结）再创建新 Memtable。

```cpp
// ob_tablet_memtable_mgr.cpp:218-258 - doom-lsp 确认
int ObTabletMemtableMgr::create_memtable_(...)
{
  // freeze_clock 是冻结协调的核心
  const uint32_t logstream_freeze_clock = freezer_->get_freeze_clock();  // @L218

  // 检查边界 Memtable：如果当前活跃 Memtable 的 freeze_clock 与 LS 一致
  // 说明需要推进冻结时钟（即发起冻结）
  if (has_memtable_() && OB_FAIL(check_boundary_memtable_(logstream_freeze_clock))) {
    // @L227 — 触发冻结或等待
  } else if (OB_FAIL(create_memtable_(arg, logstream_freeze_clock, time_guard))) {
    // @L251 — 创建新 Memtable（记录当前的 freeze_clock）
  }
}
```

**2) LS Freeze（Logstream 级冻结）**

`ObFreezer::logstream_freeze` 是冻结的主入口，由 LS 的冻结任务调度：

```cpp
// ob_freezer.cpp:498-544 - doom-lsp 确认
int ObFreezer::logstream_freeze(int64_t trace_id)
{
  int ret = OB_SUCCESS;
  SCN freeze_snapshot_version;
  SCN max_decided_scn;

  // Step 1: 获取 LS 弱读 SCN 作为 freeze_snapshot_version
  if (OB_FAIL(get_ls_weak_read_scn(freeze_snapshot_version))) {
    // weak_read_scn 保证所有在此版本之前的写操作已提交
  }

  // Step 2: 获取最大已决定日志 SCN
  else if (OB_FAIL(decide_max_decided_scn(max_decided_scn))) {
  }

  // Step 3: 设置 freeze_flag（CAS 原子操作）
  // 成功 → freeze_clock + 1
  else if (OB_FAIL(set_freeze_flag())) {
  }

  // Step 4: 记录冻结版本并提交日志
  else {
    max_decided_scn_ = max_decided_scn;
    freeze_snapshot_version_ = freeze_snapshot_version;
    (void)submit_checkpoint_task();    // DataCheckpoint 开始处理
    (void)try_submit_log_for_freeze_(false); // 写冻结日志
  }
}
```

**3) Tablet Freeze（指定 Tablet 的冻结）**

```cpp
// ob_freezer.cpp:862-918 - doom-lsp 确认
int ObFreezer::tablet_freeze(const int64_t trace_id,
                             const ObIArray<ObTabletID> &tablet_ids,
                             const bool need_rewrite_meta,
                             ObIArray<ObTableHandleV2> &frozen_memtable_handles,
                             ObIArray<ObTabletID> &freeze_failed_tablets)
{
  // 对每个 tablet_id 调用 set_tablet_freeze_flag_
  for (int64_t i = 0; i < tablet_ids.count(); i++) {
    if (OB_TMP_FAIL(set_tablet_freeze_flag_(trace_id, tablet_id, ...))) {
      // 记录失败 tablet
    }
  }
  // 提交日志（如果成功冻结了任何 memtable）
  (void)submit_log_if_needed_(frozen_memtable_handles);
}
```

### 2.3 Step 2: `freeze_clock` 的推进

**`set_freeze_flag()`**（ob_freezer.cpp:1491-1509 — doom-lsp 确认）：

```cpp
int ObFreezer::set_freeze_flag()
{
  uint32_t old_v = 0;
  uint32_t new_v = 0;

  do {
    old_v = ATOMIC_LOAD(&freeze_flag_);
    if (is_freeze(old_v)) {
      ret = OB_EAGAIN;  // 已有冻结在进行
      break;
    }
    // freeze_clock + 1, 同时设置冻结标记位
    new_v = (old_v + 1) | (1 << 31);
  } while (ATOMIC_CAS(&freeze_flag_, old_v, new_v) != old_v);

  return ret;
}
```

**`unset_freeze_()`**（ob_freezer.cpp:1514-1537 — doom-lsp 确认）：

```cpp
void ObFreezer::unset_freeze_()
{
  freeze_snapshot_version_.reset();  // 清空冻结快照版本
  max_decided_scn_.reset();          // 清空最大决定 SCN
  set_need_resubmit_log(false);      // 清除重提日志标记

  // 清除冻结标记位（第31位清0），保留 freeze_clock 的值
  do {
    old_v = ATOMIC_LOAD(&freeze_flag_);
    new_v = old_v & (~(1 << 31));
  } while (ATOMIC_CAS(&freeze_flag_, old_v, new_v) != old_v);
}
```

**为什么 freeze_clock 递增而非覆盖？**

每次冻结递增 freeze_clock，使得：
- 新创建的 Memtable 记录当前的 `freeze_clock`
- `is_frozen_memtable()` 通过比较 `freezer->freeze_clock > memtable->freeze_clock` 判断
- 确保旧 Memtable 在新一轮冻结中不会被错误地跳过

### 2.4 Step 3: Memtable 冻结标记

**`is_frozen_memtable()`**（ob_memtable.cpp:3213-3246 — doom-lsp 确认）：

```cpp
bool ObMemtable::is_frozen_memtable()
{
  const uint32_t logstream_freeze_clock = OB_NOT_NULL(freezer_)
      ? freezer_->get_freeze_clock() : 0;
  const uint32_t memtable_freeze_clock = get_freeze_clock();

  // 特殊路径：如果 memtable 不允许被冻结但冻结时钟已推进，
  // 同步 memtable 的 freeze_clock 以避免无限等待
  if (!allow_freeze() && logstream_freeze_clock > memtable_freeze_clock) {
    ATOMIC_STORE(&freeze_clock_, logstream_freeze_clock);
  }

  // 核心判断：
  // 1) logstream_freeze_clock > get_freeze_clock() — LS 冻结推进已超过本 Memtable
  // 2) get_is_tablet_freeze() — 本 Memtable 被标记为 tablet 级冻结
  const bool bool_ret = logstream_freeze_clock > get_freeze_clock()
                        || get_is_tablet_freeze();

  if (bool_ret && 0 == get_frozen_time()) {
    set_frozen_time(ObClockGenerator::getClock());  // 记录冻结时间
  }

  return bool_ret;
}
```

**`set_frozen()`** — 标记分配器为冻结状态，新写入不再能从本地分配器中获取内存（ob_memtable.h:255 — doom-lsp 确认）：

```cpp
// ob_memtable.h:255 - doom-lsp 确认
virtual int set_frozen() override
  { local_allocator_.set_frozen(); return OB_SUCCESS; }
```

### 2.5 Step 4: `ready_for_flush` — 等待冻结就绪

```cpp
// ob_memtable.cpp:1677-1770 - doom-lsp 确认
bool ObMemtable::ready_for_flush()
{
  bool bool_ret = ready_for_flush_();  // 调用内部核心逻辑

  if (bool_ret) {
    // DML 统计上报（冻结完成后一次性上报）
    report_residual_dml_stat_();
    local_allocator_.set_frozen();  // 再次确保分配器冻结
  }
  return bool_ret;
}

bool ObMemtable::ready_for_flush_()
{
  bool is_frozen = is_frozen_memtable();
  int64_t write_ref_cnt = get_write_ref();
  int64_t unsubmitted_cnt = get_unsubmitted_cnt();

  // 核心条件：已冻结 && 无写入引用 && 无未提交日志
  bool bool_ret = is_frozen && 0 == write_ref_cnt && 0 == unsubmitted_cnt;

  if (bool_ret) {
    // Step 1: 解析 snapshot_version（确定可见性边界）
    resolve_snapshot_version_();

    // Step 2: 解析 max_end_scn
    resolve_max_end_scn_();

    // Step 3: 获取 LS 当前右边界，确保 end_scn <= right_boundary
    get_ls_current_right_boundary_(current_right_boundary);
    bool_ret = (current_right_boundary >= get_max_end_scn());

    // Step 4: 解析左边界（resolve_left_boundary_for_active_memtable_）
    bool_ret = get_resolved_active_memtable_left_boundary();

    // Step 5: 推进状态机
    set_freeze_state(TabletMemtableFreezeState::READY_FOR_FLUSH);
  }
}
```

**三个关键前置条件的解释**：

| 条件 | 含义 | 为什么等待 |
|------|------|-----------|
| `is_frozen_memtable()` | freezer 的 freeze_clock 已推进超过本 Memtable 的 freeze_clock 或本 Memtable 被标记为 tablet_freeze | 确保冻结已"到达"本 Memtable |
| `write_ref_cnt == 0` | 没有正在进行的写操作（如 mvcc_write） | 写操作可能在冻结瞬间仍在进行，需要等待它们完成 |
| `unsubmitted_cnt == 0` | 没有未提交的日志 | 所有写入该 Memtable 的事务的日志必须已提交 |

### 2.6 Step 5: DataCheckpoint 调度 flush

`ObDataCheckpoint` 在 `ls_freeze` 阶段（submit_checkpoint_task 调用）将所有冻结的 Memtable 从 `frozen_list` 转移到 `prepare_list`，然后通过 `traversal_flush_` 逐个 flush：

```cpp
// ob_data_checkpoint.h:121-156 - doom-lsp 确认
class ObDataCheckpoint
{
  int flush(share::SCN recycle_scn, int64_t trace_id, bool need_freeze = true);
  int traversal_flush_();

  // 位置转移
  int transfer_from_ls_frozen_to_prepare_without_src_lock_(
      ObFreezeCheckpoint *ob_freeze_checkpoint);   // @L171
  int transfer_from_active_to_prepare_(
      ObFreezeCheckpoint *ob_freeze_checkpoint);   // @L174
};
```

`finish_freeze` 在 `ObMemtable` 中的实现：

```cpp
// ob_memtable.cpp:3325-3331 - doom-lsp 确认
int ObMemtable::finish_freeze()
{
  int ret = OB_SUCCESS;
  if (OB_FAIL(ObFreezeCheckpoint::finish_freeze())) {
    TRANS_LOG(WARN, "fail to finish_freeze", KR(ret));
  } else {
    report_memtable_diagnose_info(TabletMemtableUpdateFreezeInfo(*this));
  }
  return ret;
}
```

`ObFreezeCheckpoint::finish_freeze()` 将 Memtable 移入 data_checkpoint 的 prepare_list，等待 flush 线程处理。

### 2.7 从 Memtable 到 Min SSTable 的转换

冻结完成后，`ObMemtableCompactWriter` 将 Memtable 中的行数据编码为 SSTable 的块格式：

```cpp
// ob_memtable_compact_writer.h:30-65 - doom-lsp 确认
class ObMemtableCompactWriter : public common::ObCellWriter
{
public:
  int init();
  void reset();

  // 逐列追加编码
  int append(uint64_t column_id, const common::ObObj &obj,
             common::ObObj *clone_obj = nullptr);

  // 行结束（写入 END_FLAG）
  int row_finish();

  int64_t get_buf_size() { return buf_size_; }
};
```

`ObMemtableBlockRowScanner`（ob_memtable_block_row_scanner.h/cpp）负责扫描 Memtable 的行数据，逐行调用 `ObMemtableCompactWriter` 进行编码，最终生成 SSTable 的宏块和微块数据。

### 2.8 Freeze 完成后的并发等待

`wait_ls_freeze_finish`（ob_freezer.cpp:575-610 — doom-lsp 确认）：

```cpp
int ObFreezer::wait_ls_freeze_finish()
{
  PendTenantReplayHelper pend_replay_helper(*this, ls_);

  // 轮询等待：所有冻结的 Memtable 从 frozen_list 移到 prepare_list
  while (!get_ls_data_checkpoint()->ls_freeze_finished()) {
    // 每 100ms 检查一次
    if (TC_REACH_TIME_INTERVAL(100LL * 1000LL /* 10 ms */)) {
      // 每 5 秒检查重提日志条件
      if (time_counter >= 50 && time_counter % 50 == 0) {
        resubmit_log_if_needed_(start_time, false, false);
      }
    }
    ob_throttle_usleep(100, ret, get_ls_id().id());
  }

  stat_.end_set_freeze_stat(ObFreezeState::FINISH, ..., ret);
  unset_freeze_();  // 清除冻结标记
}
```

---

## 3. Memtable 冻结状态机

### 3.1 完整状态流转

```
                    ┌──────────────────────┐
                    │    INVALID (0)        │  ObITabletMemtable 构造后的初始状态
                    └─────────┬────────────┘
                              │ init()
                              ▼
                    ┌──────────────────────┐
                    │    ACTIVE (1)         │  可写入，接收新事务
                    │  freeze_clock = N     │  创建时记录当前 LS freeze_clock
                    └─────────┬────────────┘
                              │ is_frozen_memtable() == true
                              │ （freezer.freeze_clock > memtable.freeze_clock）
                              ▼
                    ┌──────────────────────┐
                    │    FREEZING (2)       │  已冻结，只读
                    │  等待 write_ref=0     │  等待正在进行中的写操作完成
                    │  等待 unsubmitted=0   │  等待日志同步完成
                    └─────────┬────────────┘
                              │ ready_for_flush() == true
                              │ （所有条件满足）
                              ▼
                    ┌──────────────────────┐
                    │  READY_FOR_FLUSH (3)  │  可 flush
                    │  resolve snapshot     │  解析右边界
                    │  resolve end_scn      │  确定 SCN 范围
                    └─────────┬────────────┘
                              │ flush() 开始
                              ▼
                    ┌──────────────────────┐
                    │    FLUSHED (4)        │  已写入 SSTable
                    └─────────┬────────────┘
                              │ flush 完成后释放
                              ▼
                    ┌──────────────────────┐
                    │    RELEASED (5)       │  内存已释放
                    │   或 FORCE_RELEASED(6)│  异常路径强制释放
                    └──────────────────────┘
```

### 3.2 状态判断方法

```cpp
// ob_i_tablet_memtable.h - doom-lsp 确认
bool is_active_memtable()   { return !is_frozen_memtable(); }                // @L250
bool is_frozen_checkpoint() { return is_frozen_memtable(); }                 // @L287
bool is_active_checkpoint() { return is_active_memtable(); }                 // @L286
bool is_can_flush()         { return FREEZE_STATE == READY_FOR_FLUSH         // @L250
                              && SCN::max_scn() != get_end_scn(); }
```

---

## 4. 并发控制

### 4.1 冻结期间写入如何保证不丢失？

冻结不是"立刻停止所有写入"，而是：
1. `is_frozen_memtable()` 变为 `true` 后，新写入操作仍然可以写入旧 Memtable（因为写操作在 `mvcc_write_` 中已持有行锁，正在进行的写操作必须完成）
2. `write_ref_cnt` 跟踪正在进行的写操作数量
3. `ready_for_flush_()` 等待 `write_ref_cnt == 0` 后才允许 flush

```
冻结前: 活跃写入 → 旧 Memtable (ACTIVE, freeze_clock=N)
冻结中: freezer.freeze_clock = N+1
        ┌─ 旧 Memtable: is_frozen_memtable() = true, 但仍有写入操作进行中
        │  新 Memtable: 创建时 freeze_clock = N+1, 接收所有新写入
        └─ write_ref_cnt 逐渐归零 → ready_for_flush()
冻结后: 旧 Memtable → flush → SSTable
```

```cpp
// ob_memtable.cpp:1694-1699 - doom-lsp 确认
bool ObMemtable::ready_for_flush_()
{
  bool is_frozen = is_frozen_memtable();
  int64_t write_ref_cnt = get_write_ref();
  int64_t unsubmitted_cnt = get_unsubmitted_cnt();
  bool bool_ret = is_frozen && 0 == write_ref_cnt && 0 == unsubmitted_cnt;
  // ...
}
```

### 4.2 冻结期间的读操作

冻结对读操作没有影响——`ObMvccIterator` 的读操作不需要写引用计数。读操作通过 `snapshot_version` 决定可见性，冻结后 Memtable 中的数据仍然可读，直到 flush 完成后数据转移到 SSTable。

### 4.3 freeze_clock 与 snapshot_version 的关系

**`freeze_clock`** 是 LS 级别的单调递增计数器，用于判断 Memtable 是否需要冻结。

**`freeze_snapshot_version`** 是决定 flush 后 SSTable 可见性边界的 SCN。它被设置为 freeze 时刻的 LS weak_read_scn，保证 flush 后该版本之前的所有事务在 SSTable 中可见。

两者的区别：

| 属性 | freeze_clock | freeze_snapshot_version |
|------|-------------|------------------------|
| 类型 | uint32_t（低31位） | share::SCN（64位） |
| 用途 | 判断 Memtable 是否该冻结 | 确定 flush 后数据的可见性 |
| 递增时机 | 每次 freeze 递增 | 每次 freeze 更新为 weak_read_scn |
| 存储位置 | freeze_flag_ 的低31位 | ObFreezer 的独立成员 |

### 4.4 条件变量（CV）与等待机制

`ObFreezer::wait_ls_freeze_finish` 使用轮询方式等待冻结完成（非条件变量）。核心等待逻辑通过 `ob_throttle_usleep` 实现：

```cpp
// ob_freezer.cpp:581-600 - doom-lsp 确认
while (!get_ls_data_checkpoint()->ls_freeze_finished()) {
  ob_throttle_usleep(100, ret, get_ls_id().id());  // 100μs 轮询
}
```

`wait_memtable_ready_for_flush_` 同理，等待单个 Memtable 就绪。

为什么不使用条件变量（CV）？因为冻结完成的时间不确定——它依赖于写操作完成和日志提交，这些事件没有统一的"完成通知"。轮询是更简单可靠的选择。

### 4.5 冻结后的回调链处理

Memtable 中被冻结的行数据可能还有未完成的回调链（`ObTxCallbackList`）。`ObITransCallback` 的回调在事务提交时处理，与冻结异步进行。冻结只确保 "没有新的写入操作分配到本 Memtable"，已有的未提交事务通过 `unsubmitted_cnt` 跟踪。

```cpp
// ob_mvcc_trans_ctx.cpp:90 - doom-lsp 确认
int ObITransCallback::before_append_cb(const bool is_replay)
{
  // 回调追加时检查 is_replay 和 scn 有效性
  // 与冻结无关——回调的提交与冻结是独立流程
}
```

`rec_scn_is_stable()` 确保冻结的 Memtable 的 rec_scn（日志回放 SCN）不再变小：

```cpp
// ob_memtable.cpp:3213-3227 - doom-lsp 确认
bool ObMemtable::rec_scn_is_stable()
{
  bool rec_scn_is_stable = false;
  // 对于已冷冻的 Memtable：write_ref == 0 && unsubmitted_cnt == 0
  if (OB_ISNULL(freezer_)) {
    rec_scn_is_stable = is_frozen_memtable()
                        && get_write_ref() == 0
                        && get_unsubmitted_cnt() == 0;
  }
  // 对于活跃 Memtable：max_consequent_callbacked_scn >= rec_scn
  else {
    rec_scn_is_stable = (max_consequent_callbacked_scn >= get_rec_scn());
  }
  return rec_scn_is_stable;
}
```

---

## 5. 冻结前后对比

### 5.1 冻结前

```
freeze_clock = 42                          freezer
  │
  ├── Memtable-1 (ACTIVE, freeze_clock=42) ← 写入操作 → 用户
  │     write_ref_cnt=3, unsubmitted_cnt=2
  │
  └── Memtable-0 (FROZEN, freeze_clock=41) ← 正在 flush
        write_ref_cnt=0, unsubmitted_cnt=0
```

### 5.2 冻结中

```
freeze_clock → 43（set_freeze_flag 递增）
freeze_snapshot_version = weak_read_scn_42

freezer:
  freeze_flag_ = 0x8000002B  (bit31=1, freeze_clock=43)

  ├── Memtable-2: 创建中 (freeze_clock=43) — 新写入都到这里
  │
  ├── Memtable-1 (FREEZING, freeze_clock=42) — 等待 write_ref 归零
  │     write_ref_cnt=1, unsubmitted_cnt=0
  │     is_frozen_memtable()=true ✓
  │
  └── Memtable-0 (READY_FOR_FLUSH, freeze_clock=41) — 正在 flush
```

### 5.3 冻结完成

```
freeze_clock = 43

  ├── Memtable-2 (ACTIVE, freeze_clock=43) ← 所有新写入
  │
  ├── Memtable-1 (READY_FOR_FLUSH, freeze_clock=42) → 等待 flush 调度
  │
  └── Memtable-0 (FLUSHED, freeze_clock=41) → 已释放
```

### 5.4 LSM-Tree 中的数据流

```
Memtable-2 (ACTIVE)
     │
     ▼  (冻结 + flush)
Memtable-1 → Mini SSTable (level 0)
     │
     ▼  Mini Merge
Memtable-0 → Mini SSTable (level 0) → Minor Compaction → Minor SSTable
                                                              │
                                                              ▼
                                                      Major Compaction → Major SSTable
```

---

## 6. 源码索引

### `ob_freezer.h` / `ob_freezer.cpp`
| 符号 | 行号 | 说明 |
|------|------|------|
| `class ObFreezer` | L147 | Freezer 核心类 |
| `freeze_flag_` | L253 | 冻结标记 + freeze_clock |
| `freeze_snapshot_version_` | L256 | 冻结快照版本 |
| `max_decided_scn_` | L259 | 最大已决定 SCN |
| `get_freeze_clock()` | L230 | 读取 freeze_clock（低31位） |
| `ObFreezer::logstream_freeze()` | L498 | LS 级冻结入口 |
| `ObFreezer::tablet_freeze()` | L862 | Tablet 级冻结入口 |
| `ObFreezer::set_freeze_flag()` | L1491 | CAS 递增 freeze_clock + 设冻结标记 |
| `ObFreezer::set_freeze_flag_without_inc_freeze_clock()` | L1472 | 只设标记不递增时钟 |
| `ObFreezer::unset_freeze_()` | L1514 | 清除冻结标记 |
| `ObFreezer::submit_checkpoint_task()` | L560 | 触发 DataCheckpoint ls_freeze |
| `ObFreezer::try_submit_log_for_freeze_()` | L550 | 尝试提交冻结日志 |
| `ObFreezer::wait_ls_freeze_finish()` | L575 | 等待 LS 冻结完成 |
| `ObFreezer::set_tablet_freeze_flag_()` | L1014 | 为单个 Tablet 设冻结标记 |
| `ObFreezer::tablet_freeze_()` | L964 | 批量 Tablet 冻结核心逻辑 |

### `ob_i_tablet_memtable.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `enum TabletMemtableFreezeState` | L116 | 冻结状态机枚举 |
| `class ObITabletMemtable` | L149 | Memtable 冻结接口 |
| `freeze_clock_` | L427 | 创建时的 freeze_clock |
| `freeze_scn_` | L432 | 冻结 SCN |
| `allow_freeze_` | L452 | 允许冻结标记 |
| `is_tablet_freeze_` | L454 | Tablet 级冻结标记 |
| `freeze_state_` | L477 | 当前冻结状态 |
| `is_active_memtable()` | L250 | 是否活跃（可写） |
| `is_frozen_checkpoint()` | L287 | 是否已冻结 |
| `is_can_flush()` | L250 | 是否可 flush |
| `set_freeze_clock()` | L330 | 设置 freeze_clock |
| `set_freeze_state()` | L339 | 设置冻结状态 |
| `set_is_tablet_freeze()` | L(宏) | 标记 tablet 冻结 |

### `ob_memtable.h` / `ob_memtable.cpp`
| 符号 | 行号 | 说明 |
|------|------|------|
| `ObMemtable::set_frozen()` | L255 | 冻结分配器 |
| `ObMemtable::is_frozen_memtable()` | L258 / cpp:3213 | 冻结判断（freeze_clock 比较） |
| `ObMemtable::finish_freeze()` | L456 / cpp:3325 | 冻结完成处理 |
| `ObMemtable::ready_for_flush()` | cpp:1677 | 就绪判断 + DML 统计上报 |
| `ObMemtable::ready_for_flush_()` | cpp:1694 | 核心就绪逻辑 |
| `ObMemtable::rec_scn_is_stable()` | cpp:3213 | rec_scn 稳定性检查 |
| `ObMemtable::print_ready_for_flush()` | cpp:1780 | 冻结就绪状态打印 |
| `struct TabletMemtableUpdateFreezeInfo` | h:188 | 冻结诊断信息更新 |

### `ob_freeze_checkpoint.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `enum ObFreezeCheckpointLocation` | L60 | Checkpoint 位置枚举 |
| `class ObFreezeCheckpoint` | L81 | Checkpoint 单元基类 |
| `finish_freeze()` | L110 | 完成冻结 |
| `add_to_data_checkpoint()` | L114 | 注册到 data_checkpoint |
| `ready_for_flush()` | L107 | 是否可 flush |
| `is_frozen_checkpoint()` | L111 | 是否冻结 |

### `ob_data_checkpoint.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `class ObDataCheckpoint` | L74 | DataCheckpoint 调度类 |
| `prepare_list_` | L207 | 就绪 flush 列表 |
| `traversal_flush_()` | L156 | 遍历 prepare_list 执行 flush |
| `ls_freeze()` | (引用) | 冻结时调度 |
| `ls_freeze_finished()` | (引用) | 冻结是否完成 |

### `ob_memtable_compact_writer.h` / `.cpp`
| 符号 | 行号 | 说明 |
|------|------|------|
| `class ObMemtableCompactWriter` | h:30 | Memtable → SSTable 编码器 |
| `init()` | cpp:33 | 初始化（SPARSE 编码） |
| `append()` | cpp:67 | 追加列编码 |
| `row_finish()` | cpp:76 | 结束行编码 |

### `ob_freezer_define.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `enum class ObFreezeSourceFlag` | L32 | 冻结来源枚举 |

---

## 7. 设计决策分析

### 7.1 为什么需要 freeze，而不是直接写 SSTable？

**设计选择**：先冻结 Memtable（标记为只读），再通过后台异步 job flush 到 SSTable。

**原因**：
1. **写隔离**：冻结瞬间将 Memtable 切换为只读，新数据写入新 Memtable。如果直接写 SSTable，写入期间必须持有排他锁，影响所有写入操作
2. **批量效率**：冻结后可以批量 flush 多个 Memtable，合并为单个 SSTable，比逐行写入 SSTable 效率更高
3. **故障恢复**：冻结日志（`submit_log_for_freeze`）是持久化的，宕机后可以重放冻结进度。直接写 SSTable 的中间状态更难恢复

### 7.2 freeze_clock 的作用是什么？

`freeze_clock` 是**冻结的逻辑时钟**，它解决了"如何通知所有 Memtable 该冻结了"的问题：

- 每次 `set_freeze_flag()` 递增 freeze_clock（ob_freezer.cpp:1491-1509）
- Memtable 创建时记录当时的 freeze_clock（`ob_i_tablet_memtable.h:330`）
- `is_frozen_memtable()` 通过 `logstream_freeze_clock > memtable_freeze_clock` 判断（ob_memtable.cpp:3213）

**这比逐 Memtable 设标志位更好**：
- 原子 CAS 一次 freeze_flag_，所有 Memtable 同时"感知"到冻结
- 新创建的 Memtable 自动使用新 freeze_clock，不受旧冻结影响
- 不需要遍历所有 Memtable 设标记

### 7.3 冻结期间写入如何保证不丢失？

使用 **write_ref_cnt（写引用计数）** 机制：

```cpp
// ob_i_tablet_memtable.h - 写引用计数（doom-lsp 确认）
virtual int64_t inc_write_ref() override { return inc_write_ref_(); }  // @L277
virtual int64_t dec_write_ref() override { return dec_write_ref_(); }  // @L278
virtual int64_t get_write_ref() const override { return ATOMIC_LOAD(&write_ref_cnt_); } // @L279
```

- 写入开始时调用 `inc_write_ref()`（引用计数 +1）
- 写入结束时调用 `dec_write_ref()`（引用计数 -1）
- `ready_for_flush_()` 等待 `write_ref_cnt == 0`

**关键时序**：
1. **冻结前**写入操作 A 开始 → `inc_write_ref` → write_ref_cnt=1
2. **冻结中**freezer 推进 freeze_clock → 旧 Memtable 变为 FROZEN
3. **冻结中**写入操作 A 仍然在旧 Memtable 上执行 → 写入完全有效
4. **冻结中**写入操作 A 完成 → `dec_write_ref` → write_ref_cnt=0
5. **冻结后**`ready_for_flush_()` 看到 write_ref_cnt=0 → 允许 flush

这样确保了冻结时刻正在进行的写入操作不会丢失。

### 7.4 为什么需要 `unsubmitted_cnt`？

`unsubmitted_cnt` 跟踪尚未提交日志的事务数量。冻结时，Memtable 中可能包含未提交的数据，这些数据在 flush 前必须有完整的日志同步。否则，flush 到 SSTable 后发生宕机，未同步的日志会导致数据不一致。

### 7.5 为什么 `rec_scn_is_stable()` 要判断 write_ref 和 unsubmitted？

`rec_scn`（日志回放 SCN）在回调链提交时会变小——当回调链中的最后一条日志被确认提交后，`rec_scn` 更新为新位置。如果 `rec_scn` 在 flush 过程中变化，flush 的数据范围就会不一致。

`rec_scn_is_stable()` 的两个条件都确保"不再有回调操作会影响本 Memtable 的 rec_scn"：
- `write_ref == 0`：没有正在进行的写操作，不会创建新回调
- `unsubmitted_cnt == 0`：所有已创建的回调都已提交

### 7.6 LS Freeze 与 Tablet Freeze 的区别

| 维度 | LS Freeze | Tablet Freeze |
|------|-----------|---------------|
| **协调方式** | 全局 freeze_clock 递增 | 单个 Tablet `set_is_tablet_freeze` |
| **并发级别** | high_priority_freeze_cnt | low_priority_freeze_cnt |
| **日志提交** | 一次冻结日志覆盖 LS 内所有 Tablet | 为每个冻结的 Memtable 提交日志 |
| **触发场景** | 内存阈值、周期性冻结 | 迁移、分裂、备份 |
| **影响范围** | LS 内所有 Tablet | 指定 Tablet |

```cpp
// ob_freezer.h - doom-lsp 确认
int64_t high_priority_freeze_cnt_;  // LS freeze：高优先级（互斥）
int64_t low_priority_freeze_cnt_;   // Tablet freeze：低优先级（可并发）

class ObLSFreezeGuard {
  // 独占：LS freeze 期间阻止其他冻结
  ~ObLSFreezeGuard() { parent_.set_ls_freeze_end_(); }
};

class ObTabletFreezeGuard {
  // 共享：tablet freeze 可以重叠
};
```

### 7.7 冻结日志的作用

每次 freeze 需要提交一条 TRANS_SERVICE_LOG_BASE_TYPE 的日志（通过 `submit_log_for_freeze`）。这条日志的作用：

1. **持久化冻结边界**：日志中包含 freeze_snapshot_version，宕机后新选主可以正确恢复
2. **驱动 Paxos 同步**：日志在 Paxos 中复制，确保所有副本的冻结进度一致
3. **推进右边界**：冻结日志写入后，LS 的 right_boundary 推进，依赖此值的 `ready_for_flush` 才能通过

```cpp
// ob_freezer.cpp:622-635 - doom-lsp 确认
void ObFreezer::resubmit_log_if_needed_(..., const bool is_tablet_freeze, ...)
{
  // 如果日志提交失败，需要重试
  (void)submit_log_for_freeze(is_tablet_freeze, is_try);
}
```

### 7.8 空 Memtable 的冻结处理

如果 Tablet 在冻结时没有活跃 Memtable（无数据写入），`set_tablet_freeze_flag_` 返回 `OB_ENTRY_NOT_EXIST`。此时根据 `need_rewrite_meta` 决定是否创建空 Memtable：

```cpp
// ob_freezer.cpp:1032-1035 - doom-lsp 确认
if (ret == OB_ENTRY_NOT_EXIST) {
  if (need_rewrite_meta) {
    ret = handle_no_active_memtable_(tablet_id, tablet, freeze_snapshot_version);
  } else {
    ret = OB_SUCCESS;
    // 不需要冻结空 Tablet
  }
}
```

---

## 8. 总结

OceanBase 的 Memtable 冻结机制可以总结为：

1. **触发**：冻结由内存阈值、事务层推进、用户命令等多种来源触发（`ObFreezeSourceFlag` 定义了 17 种来源）
2. **核心协调**：`ObFreezer` 通过 `freeze_clock`（递增计数器）和 `freeze_snapshot_version`（MVCC 边界）协调冻结
3. **状态机**：Memtable 经历 `ACTIVE → FREEZING → READY_FOR_FLUSH → FLUSHED → RELEASED` 的状态流转
4. **并发安全**：冻结不阻塞正在进行的写操作（通过 `write_ref_cnt` 等待），读操作完全不受影响
5. **持久化**：冻结日志提交后，DataCheckpoint 将就绪的 Memtable flush 到 Mini SSTable
6. **编码转换**：`ObMemtableCompactWriter` 将内存行数据编码为 SSTable 块格式

---

*分析工具：doom-lsp（clangd LSP 18.x） | 分析日期：2026-05-03 | 代码仓库：OceanBase CE*
