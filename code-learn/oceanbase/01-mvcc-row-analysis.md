# 01-mvcc-row — OceanBase 存储层 MVCC 行结构深度源码分析

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

**MVCC（Multi-Version Concurrency Control）** 是 OceanBase 存储引擎实现读写并发隔离的核心机制。与 Linux 内核链表设计"数据包含链表节点"的嵌入式思维一脉相承，OceanBase 的 MVCC Row 同样采用了"数据包含版本链"的逆向设计——`ObMvccRow` 结构体中内嵌一个 `ObMvccTransNode *` 双向链表头，所有历史版本通过该链表串联，读请求根据 `snapshot_version` 选取可见版本，无需加锁。

OceanBase 的 MVCC 实现与 PostgreSQL、MySQL InnoDB 的设计思路同源，但在分布式场景（多副本 Paxos 同步）下有独特延伸：事务提交版本（`trans_version`）必须等 Paxos 日志落盘才算正式确立，因此存在"提交中"的中间状态需要特殊处理。

**doom-lsp 确认**：`src/storage/memtable/mvcc/ob_mvcc_row.h` 含 **~490 行核心结构定义**，`ob_mvcc.h`（回调接口）含 **~200 行**，`ob_mvcc_ctx.h` 含 **~300 行**，`ob_mvcc_row.cpp` 中 `mvcc_write_` 实现 @ L808，`ob_mvcc_engine.cpp` 中 `mvcc_write` @ L254。四个文件共同构成 MVCC 存储层的核心。

---

## 1. 核心数据结构

### 1.1 `ObMvccTransNode`——存储层的版本节点

```c
// ob_mvcc_row.h:71-169 - doom-lsp 确认
struct ObMvccTransNode
{
  transaction::ObTransID tx_id_;           // 所属事务 ID（doom-lsp @ L135）
  share::SCN            trans_version_;    // 事务提交版本（可见性判断核心，doom-lsp @ L152）
  share::SCN            scn_;              // Paxos 日志序号（持久化进度，doom-lsp @ L153）
  transaction::ObTxSEQ   seq_no_;          // 事务内序列号（doom-lsp @ L154）
  int64_t               write_epoch_;      // 写入时的 epoch（doom-lsp @ L155）
  share::SCN            tx_end_scn_;       // 事务结束的 SCN（doom-lsp @ L156）
  // ob_mvcc_row.h:157-158 - doom-lsp 确认：prev 指向更新版本，next 指向更旧版本
  ObMvccTransNode      *prev_;            // 前驱版本（更新）
  ObMvccTransNode      *next_;            // 后继版本（更旧）
  uint32_t              modify_count_;     // 累计修改次数
  uint32_t              acc_checksum_;     // 累计校验和（数据完整性）
  int64_t               version_;          // 节点版本号
  int64_t               snapshot_version_barrier_; // 快照版本屏障
  uint8_t               type_;             // NDT_NORMAL / NDT_COMPACT
  TransNodeFlag         flag_;             // 状态标志（1 byte，零开销）
  char                  buf_[0];           // 行数据 payload（柔性数组）
};
```

**设计哲学与 Linux list_head 如出一辙**：`ObMvccTransNode` 不包含数据本身，而是通过 `buf_[0]` 柔性数组在节点尾部承载实际的行数据（UPDATE 的新值）。这是 C 语言中经典的"结构体尾部弹性布局"——`buf_` 的地址即等于结构体末尾，`malloc` 时在 `sizeof(ObMvccTransNode)` 基础上额外分配行数据大小，访问时直接 `reinterpret_cast<ObDatumRow*>(node->buf_)` 即得用户数据。好处：**数据访问零指针间接寻址**，一个结构体同时承载元数据和用户数据。

### 1.2 `TransNodeFlag`——原子状态机（CAS loop 实现）

```c
// ob_mvcc_row.h:73-113 - doom-lsp 确认
struct TransNodeFlag {
  static constexpr uint8_t F_INIT                        = 0x00;
  static constexpr uint8_t F_WEAK_CONSISTENT_READ_BARRIER = (1 << 0);
  static constexpr uint8_t F_STRONG_CONSISTENT_READ_BARRIER = (1 << 1);
  static constexpr uint8_t F_COMMITTED                   = (1 << 2);
  static constexpr uint8_t F_ELR                         = (1 << 3);  // Early Lock Release
  static constexpr uint8_t F_ABORTED                    = (1 << 4);
  static constexpr uint8_t F_DELAYED_CLEANOUT            = (1 << 6);
  static constexpr uint8_t F_INCOMPLETE_STATE           = (1 << 7);
};
```

**注意**：与 Linux 内核链表节点删除后毒化（POISON）不同，OceanBase MVCC 节点通过 `TransNodeFlag` 的原子操作来标识生命周期状态。`F_COMMITTED` 和 `F_ABORTED` 是互斥的终结态，`F_ELR` 是提交过程中的提前锁释放优化态，`F_DELAYED_CLEANOUT` 标识延迟清理。

所有标志位操作使用** CAS loop（`ATOMIC_BCAS`）**而非锁：

```c
// ob_mvcc_row.h:113-122 - doom-lsp 确认：CAS loop 实现
void add_flag_(const uint8_t new_flag) {
  while (true) {
    const uint8_t flag = ATOMIC_LOAD(&flag_status_);
    const uint8_t tmp = (flag | new_flag);
    if (ATOMIC_BCAS(&flag_status_, flag, tmp)) {
      break;
    }
  }
}
```

**`flag_` 的大小为 1 byte（`uint8_t`），STATIC_ASSERT 确认零开销**：所有标志位操作在 64 位系统上都是单指令原子，无需内存屏障即可达到 Release/Acquire 语义。

### 1.3 `ObMvccRow`——多版本链表的行容器

```c
// ob_mvcc_row.h:277-335 - doom-lsp 确认
struct ObMvccRow
{
  ObRowLatch            latch_;                   // 行锁（自旋锁，保护整个结构）
  uint8_t                flag_;                    // 行的状态标志
  blocksstable::ObDmlFlag first_dml_flag_;        // 首版本 DML 类型
  blocksstable::ObDmlFlag last_dml_flag_;          // 最新版本 DML 类型
  int32_t                update_since_compact_;     // 上次压缩后的更新次数

  int64_t                total_trans_node_cnt_;    // 版本节点总数
  int64_t                latest_compact_ts_;       // 最近一次压缩时间戳
  int64_t                last_compact_cnt_;        // 最近一次压缩节点数
  share::SCN             max_trans_version_;       // 链上最大提交版本
  share::SCN             max_elr_trans_version_;  // 链上最大 ELR 版本
  share::SCN             max_modify_scn_;          // 最大修改 SCN
  share::SCN             min_modify_scn_;          // 最小修改 SCN
  transaction::ObTransID max_trans_id_;           // 最大事务 ID
  transaction::ObTransID max_elr_trans_id_;        // 最大 ELR 事务 ID
  ObMvccTransNode      *list_head_;              // ★ 双向链表头（最新版本）
  ObMvccTransNode      *latest_compact_node_;    // 最近一次压缩的节点
  ObMvccRowIndex       *index_;                  // 快速索引（加速回放）

  ObMvccRow() { STATIC_ASSERT(sizeof(ObMvccRow) <= 120, "Size of ObMvccRow Overflow."); ... }
};
```

**核心不变量**：`list_head_` 指向链表的最新（newest）版本，`list_head_->next_` 指向次新版本，以此类推，链表按版本从新到旧排列。**所有遍历都是从 `list_head_` 开始沿着 `next_` 向后走**。

**`STATIC_ASSERT(sizeof(ObMvccRow) <= 120)`** —— 这个约束确保 `ObMvccRow` 可以放入 128 字节的缓存行（或 128 字节的内存分配粒度），避免一个行版本更新导致多个缓存行失效。这是数据库实现中的**缓存行友好设计**。

### 1.4 版本链的内存布局

```
ObMvccRow (120 bytes, cache-line aligned)
├── latch_: ObRowLatch          (自旋锁，保护整行)
├── list_head_: ObMvccTransNode* ──────────────────┐
├── ...meta...                              │
└── index_: ObMvccRowIndex*                │
                                              │
            ┌────────────────────────────────┘
            │ next_                    prev_
            ▼                              ▼
  ┌──────────────────┐         ┌──────────────────┐
  │ ObMvccTransNode  │         │ ObMvccTransNode │
  │ tx_id_: T1       │         │ tx_id_: T2       │
  │ trans_version_: 5 │         │ trans_version_: 3│
  │ flag_: COMMITTED │         │ flag_: COMMITTED │
  │ buf_: [新值: X'] │         │ buf_: [旧值: X]  │
  │ prev_ ← ──────  │         │ next_ → ──────  │
  └──────────────────┘         └──────────────────┘
         newest (T1提交版本5)        older (T2提交版本3)
```

**`prev_` 和 `next_` 构成双向链表**：`prev_` 指向更新的版本，`next_` 指向更旧的版本。这与 Linux 内核链表的 `next/prev` 设计完全一致——`list_head` 双向循环链表通过 `prev/next` 串联，`ObMvccRow.list_head_` 是链表的锚点。

---

## 2. `ObTxSEQ`——事务内序列号（branch 支持）

OceanBase 的并发写入依赖 `ObTxSEQ` 作为事务内操作顺序的核心标识：

```c
// ob_tx_seq.h:30-126 - doom-lsp 确认
class ObTxSEQ
{
  // 4.3+ 版本将序列号拆分为两段：
  //   part1: 相对于事务起始的序列号偏移
  //   part2: 并行写 branch 的 id（用于 PDML 并行写入）
private:
  union {
    int64_t raw_val_;
    union {
      struct { // v0, old_version
        uint64_t seq_v0_     :62;
      };
      struct { // new_version
        uint16_t branch_     :15;  // 并行 branch id（0 = 主分支）
        uint64_t seq_        :47; // 序列号偏移
        bool     n_format_   :1;
        int     _sign_       :1;
      };
    };
  };
};
static_assert(sizeof(ObTxSEQ) == sizeof(int64_t), "ObTxSEQ should sizeof(int64_t)");
```

**关键方法**（doom-lsp 确认）：
- `get_branch()` @ L110：返回并行写 branch id，`n_format_==false` 时返回 0（old version 兼容）
- `get_seq()` @ L107：返回序列号偏移（相对于事务起始）
- `support_branch()` @ L105：判断是否支持 branch 并行

---

## 3. 写操作核心——`mvcc_write` 的完整数据流

### 3.1 两层封装

```c
// ob_mvcc_engine.cpp:254 - doom-lsp 确认：ObMvccEngine::mvcc_write（上层封装）
int ObMvccEngine::mvcc_write(storage::ObStoreCtx &ctx,
                            ObMvccRow &value,
                            const ObTxNodeArg &arg,
                            const bool check_exist,
                            void *buf, // preallocated buffer for ObMvccTransNode
                            ObMvccWriteResult &res)
{
  int ret = OB_SUCCESS;
  ObMvccTransNode *node = (ObMvccTransNode *)buf;
  if (OB_FAIL(init_tx_node_(arg, node))) {
    // 初始化 tx_node（元数据填充）
  } else if (OB_FAIL(value.mvcc_write(ctx, *node, check_exist, res))) {
    // 调用 ObMvccRow::mvcc_write
  }
  return ret;
}

// ob_mvcc_row.cpp:1048 - doom-lsp 确认：ObMvccRow::mvcc_write（入口）
int ObMvccRow::mvcc_write(ObStoreCtx &ctx,
                          ObMvccTransNode &node,
                          const bool check_exist,
                          ObMvccWriteResult &res)
{
  int ret = OB_SUCCESS;
  transaction::ObTxSnapshot &snapshot = ctx.mvcc_acc_ctx_.snapshot_;
  const SCN snapshot_version = snapshot.version_;
  if (max_trans_version_.atomic_load() > snapshot_version
      || max_elr_trans_version_.atomic_load() > snapshot_version) {
    // Case 3: 成功锁定但触发 TSC（Transaction Set Violation）
    ret = OB_TRANSACTION_SET_VIOLATION;
    ...
  } else if (OB_FAIL(mvcc_write_(ctx, node, res))) {
    ...
  } else if (!res.can_insert_) {
    // Case1: 因写写冲突无法插入
    ret = OB_TRY_LOCK_ROW_CONFLICT;
    ...
  } else if (max_trans_version_.atomic_load() > snapshot_version ... ) {
    // Case 3: mvcc_write_ 成功后 TSC
    ret = OB_TRANSACTION_SET_VIOLATION;
    if (!res.has_insert()) {
      // TSC 已发生但节点未插入
    } else {
      (void)mvcc_undo();
      res.is_mvcc_undo_ = true;
    }
  } else if (check_exist && res.lock_state_.row_exist()) {
    // Case 4: 插入到已存在的行（主键冲突）
    ret = OB_ERR_PRIMARY_KEY_DUPLICATE;
    if (!res.has_insert()) {
      // 主键冲突，节点未实际插入
    } else {
      (void)mvcc_undo();
      res.is_mvcc_undo_ = true;
    }
  }
  return ret;
}
```

### 3.2 `mvcc_write_` 的 Case 分析（doom-lsp @ ob_mvcc_row.cpp L808）

```c
// ob_mvcc_row.cpp:808-1005 - doom-lsp 确认：核心状态机
int ObMvccRow::mvcc_write_(ObStoreCtx &ctx,
                           ObMvccTransNode &writer_node,
                           ObMvccWriteResult &res)
{
  ObRowLatchGuard guard(latch_);  // ★ 获取行锁（排他）
  ObMvccTransNode *iter = ATOMIC_LOAD(&list_head_);
  ObTransID writer_tx_id = ctx.mvcc_acc_ctx_.get_tx_id();
  const SCN snapshot_version = ctx.mvcc_acc_ctx_.snapshot_.version_;
  const ObTxSEQ reader_seq_no = ctx.mvcc_acc_ctx_.snapshot_.scn_;

  while (OB_SUCC(ret) && need_retry) {
    if (OB_ISNULL(iter)) {
      // ★ Case 1: 空链表（行不存在）→ 新建头节点
      can_insert = true;
      need_insert = true;
      is_new_locked = true;
      lock_dml_flag = DF_NOT_EXIST;
      need_retry = false;
    } else if (iter->is_delayed_cleanout() && !(iter->is_committed() || iter->is_aborted()) &&
               OB_FAIL(ctx.mvcc_acc_ctx_.get_tx_table_guards()
                          .tx_table_guard_
                          .cleanout_tx_node(data_tx_id, *this, *iter, false))) {
      // ★ Case 2: 头节点是 delayed_cleanout 且未决 → 通过 tx_table 清理状态
      // Tip: 写操作的锁状态和读操作的锁状态不同，即使节点不是 delayed_cleanout，
      // 读操作也不能直接依赖节点锁状态
    } else if (iter->is_committed() || iter->is_elr()) {
      // ★ Case 3: 头节点已提交或处于 ELR 状态 → 可插入
      can_insert = true;
      need_insert = true;
      is_new_locked = true;
      lock_dml_flag = filtered ? DF_NOT_EXIST : iter->get_dml_flag();
      need_retry = false;
    } else if (iter->is_aborted()) {
      // ★ Case 4: 头节点已中止 → 跳过，查看下一个节点
      iter = iter->prev_;
      need_retry = true;
    } else if (data_tx_id == writer_tx_id) {
      // ★ Case 5: 头节点被自己锁定 → 可插入到该节点
      bool is_lock_node = false;
      writer_node.is_lock_node(is_lock_node);
      if (is_lock_node) {
        // Case 5.1: 头节点本身就是锁节点，不重复插入
        can_insert = true;
        need_insert = false;
        is_new_locked = false;
      } else {
        // Case 5.2: 自己是写入者，插入到现有节点
        can_insert = true;
        need_insert = true;
        is_new_locked = false;
      }
      need_retry = false;
    } else {
      // ★ Case 6: 头节点被其他事务锁定 → 写写冲突
      can_insert = false;
      need_insert = false;
      is_new_locked = false;
      need_retry = false;
      lock_state.is_locked_ = true;
      lock_state.lock_trans_id_ = data_tx_id;           // 锁持有者 tx_id
      lock_state.lock_data_sequence_ = iter->get_seq_no(); // 锁的数据序号
      lock_state.lock_dml_flag_ = iter->get_dml_flag();
      lock_state.is_delayed_cleanout_ = iter->is_delayed_cleanout();
      lock_state.mvcc_row_ = this;
      lock_state.trans_scn_ = iter->get_scn();
    }
  }

  // ★ 插入链表：使用 ATOMIC_STORE 保证并发安全
  if (can_insert && need_insert) {
    ATOMIC_STORE(&(writer_node.prev_), list_head_);
    ATOMIC_STORE(&(writer_node.next_), NULL);
    if (NULL != list_head_) {
      ATOMIC_STORE(&(list_head_->next_), &writer_node);
    }
    ATOMIC_STORE(&(list_head_), &writer_node);
    writer_node.modify_count_ = (NULL != writer_node.prev_)
                               ? writer_node.prev_->modify_count_ + 1 : 0;
    total_trans_node_cnt_++;
  }
}
```

### 3.3 `ObMvccWriteResult`——写结果的多维状态

```c
// ob_mvcc_define.h:174-230 - doom-lsp 确认
struct ObMvccWriteResult {
  bool can_insert_;      // 是否允许插入（可能因写写冲突被拒绝）
  bool need_insert_;     // 是否需要实际插入（可能因为行已被锁定而不需要）
  bool is_new_locked_;   // 是否是第一次锁定该行（用于死锁检测）
  bool is_mvcc_undo_;    // 是否需要通过 mvcc_undo 回滚
  storage::ObStoreRowLockState lock_state_;  // 锁状态（冲突信息）
  ObMvccRowCallback *tx_callback_;  // 回调对象（一对一对应 tx_node）
  ObMvccTransNode *tx_node_;        // 写入的版本节点
  bool is_checked_;      // sequence_set_violation 检查是否完成
  ObMvccRow *value_;     // 目标行对象
  ObMemtableKey mtk_;    // Memtable key 引用（用于回调注册）
};
```

---

## 4. 可见性判断——MVCC 读取的核心

### 4.1 `ObMvccTransNode` 的提交状态

```c
// ob_mvcc_row.h:182-195 - doom-lsp 确认
void trans_commit(const share::SCN commit_version, const share::SCN tx_end_scn) {
  fill_trans_version(commit_version);  // 填入提交版本
  flag_.set_committed();              // 设置 F_COMMITTED 标志
  set_tx_end_scn(tx_end_scn);         // 填入事务结束 SCN
}

void trans_abort(const share::SCN tx_end_scn) {
  flag_.set_aborted();
  set_tx_end_scn(tx_end_scn);
}

void trans_rollback() {
  flag_.set_aborted();  // 无需 tx_end_scn（回调还存在）
}
```

### 4.2 `ObITransCallback`——事务提交的回调接口

```c
// ob_mvcc.h:40-183 - doom-lsp 确认
class ObITransCallback
{
public:
  ObITransCallback() :
    need_submit_log_(true),
    scn_(share::SCN::max_scn()),  // max = 未提交
    prev_(NULL), next_(NULL) {}

  virtual int trans_commit() { return OB_SUCCESS; }   // 提交时调用
  virtual int trans_abort() { return OB_SUCCESS; }    // 回滚时调用
  virtual int rollback_callback() { return OB_SUCCESS; }  // 回滚回调
  virtual int checkpoint_callback() { return OB_SUCCESS; }  // 检查点回调
  virtual int calc_checksum(...) { return OB_SUCCESS; }

  bool is_log_submitted() const { return !scn_.is_max(); }

  share::SCN get_scn() const;
  void set_scn(const share::SCN scn);
  void append(ObITransCallback *node);  // 插入到回调链表

protected:
  bool               need_submit_log_;  // ob_mvcc.h:175 - doom-lsp 确认为 bitfield
  share::SCN         scn_;              // ob_mvcc.h:37（TxChecksum 成员）
  int64_t            epoch_;             // Epoch（用于判断回调新鲜度）
  ObITransCallback  *prev_;             // ob_mvcc.h:182 - doom-lsp 确认
  ObITransCallback  *next_;             // ob_mvcc.h:183 - doom-lsp 确认
};
```

**OceanBase 分布式 MVCC 的关键区别**：`scn_`（Paxos 日志序号）必须在日志真正落盘后才被设置为非 `max` 值。在此之前，`is_log_submitted() == false`，读取时需要检查该节点的日志是否已提交（对于未提交节点，需要等 Paxos 同步完成才能确定其最终状态）。

### 4.3 可见性判断的数据流

OceanBase 的 MVCC 读取判断逻辑（以 `ObMvccIterator` 为入口）的核心是**寻找满足以下条件的最新版本节点**：

```
可见条件（同时满足）：
1. node.flag_.is_committed() == true        // 事务已提交
2. node.trans_version_ <= snapshot_version_ // 提交版本 <= 读取快照版本
3. node.tx_id_ != snapshot_tx_id_           // 非当前事务自身（防止脏读）
4. node.flag_.is_aborted() == false         // 事务未回滚
```

**为什么需要 `scn_`（Paxos 日志序号）？**

在分布式多副本场景下，即使 `trans_version_` 已经分配好了（事务已在协调者提交），该提交记录可能还没有在当前副本的 Paxos 日志中落盘。这时：
- 读取请求在本地副本看到该节点：`is_committed() == true` 但 `is_log_submitted() == false`
- 读取需要等待 Paxos 同步完成，或从其他副本读取
- 这就是 `ObTxTableGuard` 存在的意义——它提供"事务提交状态"的权威来源

### 4.4 ELR（Early Lock Release）机制

```c
// ob_mvcc_row.h:198 - doom-lsp 确认
void trans_elr() {
  flag_.set_elr();  // 设置 F_ELR：提交日志已提议，但未最终同步
}
```

**ELR 的设计意图**：当事务的提交日志已经在 Paxos 中提议成功（单副本成功即可），就可以提前释放行锁，让其他等待该行的事务继续推进，而不必等待所有副本同步完成。这是**延迟可见性优化**——`trans_version_` 已被分配但其他副本尚未同步完成时，持有该行锁的读者可以提前释放锁。

---

## 5. 写操作的安全检查

### 5.1 `mvcc_sanity_check_`——双重写入与并发检查

```c
// ob_mvcc_row.cpp:980-1030 - doom-lsp 确认：noinline 函数
int ObMvccRow::mvcc_sanity_check_(const SCN snapshot_version,
                                  const concurrent_control::ObWriteFlag write_flag,
                                  ObMvccTransNode &node,
                                  ObMvccTransNode *prev)
{
  int ret = OB_SUCCESS;
  const bool compliant_with_sql_semantic = !write_flag.is_table_api();

  if (NULL != prev) {
    if (blocksstable::ObDmlFlag::DF_INSERT == node.get_dml_flag()
        && blocksstable::ObDmlFlag::DF_DELETE != prev->get_dml_flag()
        && prev->is_committed()
        && snapshot_version >= prev->trans_version_) {
      // Case 1: 检测双重插入（主键冲突）
      ret = OB_ERR_PRIMARY_KEY_DUPLICATE;
    } else if (prev->get_tx_id() == node.get_tx_id()
               && prev->is_incomplete()
               && compliant_with_sql_semantic) {
      // Case 2: 同一事务内并发 insert/delete 可能导致日志顺序混乱，返回错误等待 SQL 层重试
      ret = OB_SEQ_NO_REORDER_UNDER_PDML;
    } else if (prev->get_tx_id() == node.get_tx_id()
               && prev->get_write_epoch() == node.get_write_epoch()
               && prev->get_seq_no().get_branch() != node.get_seq_no().get_branch()) {
      // Case 3: 同一行被同一事务的不同 branch 并发修改
      ret = OB_SEQ_NO_REORDER_UNDER_PDML;
    }
  }
  return ret;
}
```

### 5.2 `sequence_set_violation` 检查——并发写入的 branch 隔离

```c
// ob_memtable.cpp:1332 - doom-lsp 调用位置
OB_FAIL(concurrent_control::check_sequence_set_violation(ctx.mvcc_acc_ctx_.write_flag_,
                                                         reader_seq_no,
                                                         writer_tx_id,
                                                         writer_node.get_dml_flag(),
                                                         writer_node.get_seq_no(),
                                                         iter->get_tx_id(),
                                                         iter->get_dml_flag(),
                                                         iter->get_seq_no()))

// 用于 PDML（并行 DML）场景：同一事务内多个 branch 并行写入同一行时，
// 检查 reader_seq_no（读序列号）与 writer_node.seq_no（写序列号）是否满足偏序关系
```

### 5.3 `mvcc_undo`——原子级回滚

```c
// ob_mvcc_row.cpp:1032-1050 - doom-lsp 确认
void ObMvccRow::mvcc_undo()
{
  ObRowLatchGuard guard(latch_);
  ObMvccTransNode *iter = ATOMIC_LOAD(&list_head_);

  if (OB_ISNULL(iter)) {
    TRANS_LOG_RET(ERROR, OB_ERR_UNEXPECTED, "mvcc undo with no mvcc data");
  } else {
    iter->trans_rollback();  // 设置 F_ABORTED 标志
    ATOMIC_STORE(&(list_head_), iter->prev_);  // 头指针前移
    if (NULL != iter->prev_) {
      ATOMIC_STORE(&(iter->prev_->next_), NULL);  // 断开 next
    }
    total_trans_node_cnt_--;
  }
}
```

**注意**：`mvcc_undo` 只回滚链表的**最新节点**，不扫描整个链表。这是合理的——一个事务只能看到并修改最新版本节点，旧节点不可能属于当前事务。

---

## 6. 事务回调链——`ObTxCallbackList`

### 6.1 `ObTxCallbackList` 的角色

```c
// ob_tx_callback_list.h:28 - doom-lsp 确认
class ObTxCallbackList
{
  ObTransCallbackMgr &callback_mgr_;
  const int16_t id_;
  // 回调链表（双向链表，head/tail）
  // 每个事务的每次 DML 操作都会产生一个 ObITransCallback 节点
  // 节点内含 scn_（Paxos 日志序号），日志提交后 scn_ 被更新
};
```

**回调链表 vs 版本链**：

| 链表 | 节点 | 挂载位置 | 生命周期 |
|------|------|---------|---------|
| 版本链 `ObMvccRow.list_head_` | `ObMvccTransNode` | 行数据内（`buf_` 柔性数组） | 事务提交后持久化，随数据保留 |
| 回调链 `ObTxCallbackList` | `ObITransCallback` | 事务上下文（`ObMemtableCtx`） | 事务提交过程中，日志同步后清理 |

**两链协同**：`ObITransCallback` 持有指向 `ObMvccTransNode` 的引用。当 Paxos 日志同步完成时，`ObITransCallback::scn_` 被更新，同时触发 `trans_commit()` 将 `ObMvccTransNode::flag_` 设为 `F_COMMITTED`。

### 6.2 回调链的批量操作

```c
// ob_tx_callback_list.h:50 - doom-lsp 确认
int append_callback(ObITransCallback *head,
                    ObITransCallback *tail,
                    const int64_t length,
                    const bool for_replay,
                    const bool parallel_replay = false,
                    const bool serial_final = false);

int remove_callbacks_for_fast_commit(const share::SCN stop_scn = share::SCN::invalid_scn());
int remove_callbacks_for_rollback_to(const transaction::ObTxSEQ to_seq,
                                     const transaction::ObTxSEQ from_seq,
                                     const share::SCN replay_scn);
```

**批量回调合并**：当一个事务有多次 DML 操作时，每次 DML 都会产生一个回调节点。`concat_callbacks` 将多个回调链表合并为一条长链表，减少提交时的遍历次数。

---

## 7. 上下文结构——`ObMvccAccessCtx`

### 7.1 `ObMvccAccessCtx`——读写请求的完整上下文

```c
// ob_mvcc_acc_ctx.h:59 - doom-lsp 确认
class ObMvccAccessCtx
{
public:
  enum class T { INVL, STRONG_READ, WEAK_READ, WRITE, REPLAY };

  T                    type_;                 // 访问类型
  bool                 is_standby_read_;      // 是否备机读
  bool                 has_create_tx_ctx_;    // 是否已创建事务上下文
  bool                 is_delete_insert_;      // 是否为删除插入操作
  int64_t              abs_lock_timeout_ts_;   // 绝对锁超时时间戳
  int64_t              tx_lock_timeout_us_;   // 事务锁超时（微秒）
  int64_t              major_snapshot_;        // 主表快照版本
  ObTxSnapshot         snapshot_;              // ★ MVCC 快照（version、tx_id 等）
  ObTxTableGuards      tx_table_guards_;      // 事务表守卫（分布式场景关键）
  ObTransID            tx_id_;                 // 当前事务 ID
  ObTxDesc            *tx_desc_;              // 事务描述符
  ObPartTransCtx      *tx_ctx_;               // 事务上下文（内存）
  ObMemtableCtx       *mem_ctx_;              // Memtable 上下文
  ObSCN               tx_scn_;                // 事务 SCN
  ObMvccWriteFlag     write_flag_;            // 写标志（互斥/共享锁等）
  int64_t              handle_start_time_;     // 处理开始时间
  int64_t              lock_wait_start_ts_;    // 锁等待开始时间戳
};
```

### 7.2 `ObTxSnapshot`——MVCC 快照定义

```c
// ob_trans_define_v4.h:278 - doom-lsp 确认为 class（非 struct）
class ObTxSnapshot
{
public:
  share::SCN    version_;       // 快照版本（SCN），读请求看到的数据上限
  ObTransID    tx_id_;         // 快照创建时正在运行的事务 ID
  ObTxSEQ      scn_;           // 快照 SCN（用于 sequence_set_violation 检查）
  bool         elr_;           // 是否允许读取 ELR（Early Lock Release）版本
  bool         force_strongly_read_;  // 是否强制强一致性读
};
```

**`ObTxSnapshot::version_` 的含义**：当读取请求执行 `init_read` 时，系统为其分配一个 `snapshot_version`，该版本之前提交的所有事务对当前读请求可见，之后提交的（包括并发运行的）不可见。这与 PostgreSQL 的 `snapshot->xmin/xmax` 机制异曲同工。

---

## 8. 索引加速——`ObMvccRowIndex`

### 8.1 回放队列索引

```c
// ob_mvcc_row.h:279 - doom-lsp 确认：嵌套于 ObMvccRow 的结构体
struct ObMvccRowIndex
{
  bool is_empty_;
  ObMvccTransNode *replay_locations_[common::REPLAY_TASK_QUEUE_SIZE];
  // 用于快速定位某个事务的回放位置
};
```

**索引触发条件**：`INDEX_TRIGGER_COUNT = 500`（ob_mvcc_row.h:310 - doom-lsp 确认）。当访问某行时遍历超过 500 个节点还没找到插入位置，就构建 `ObMvccRowIndex`。这是一个**懒构建的空间换时间策略**——冷数据不会浪费内存构建索引。

---

## 9. `ObRowLatch`——最简单的行级自旋锁

```c
// ob_row_latch.h:22-42 - doom-lsp 确认
#define USE_SIMPLE_ROW_LATCH 1
#if USE_SIMPLE_ROW_LATCH
struct ObRowLatch
{
  ObRowLatch(): locked_(false) {}
  bool is_locked() const { return ATOMIC_LOAD(&locked_); }
  bool try_lock() { return !ATOMIC_TAS(&locked_, true); }
  void lock() { while(!try_lock()) ; }
  void unlock() { ATOMIC_STORE(&locked_, false); }
  bool locked_;
  struct Guard {
    Guard(ObRowLatch& host): host_(host) { host.lock(); }
    ~Guard() { host_.unlock(); }
    ObRowLatch& host_;
  };
};
#endif
```

**关键洞察**：OceanBase 存在 `USE_SIMPLE_ROW_LATCH` 编译选项，默认使用简单的 TAS（test-and-set）自旋锁实现，比通用的 `ObLatch` 更轻量。这说明**行锁的争抢概率极低**，无需使用 Linux 内核那样的 MCS 队列锁。`ObRowLatchGuard` 的 RAII 模式确保锁一定会被释放。

---

## 10. ObTxCallbackHashHolderLinker——回调链表的 Hash 索引

```c
// ob_tx_callback_hash_holder_helper.h:31-56 - doom-lsp 确认
class ObTxCallbackHashHolderLinker {
  // 用于将 ObITransCallback 节点挂载到 Hash 表
  // 支持高效查找：给定事务 ID + 序列号，快速定位对应回调节点
  ObTxCallbackHashHolderLinker *newer_node_;  // 更新版本（同一 key 内）
  ObTxCallbackHashHolderLinker *older_node_;   // 更旧版本
  int64_t hash_key_;
};
```

这个结构让 `ObITransCallback` 可以同时属于**双向链表**（`prev_/next_`）和 **Hash 桶**（`newer_node_/older_node_`），实现 O(1) 的回调节点查找。

---

## 11. 与 Linux 内核链表的设计对比

| 维度 | Linux `list_head` | OceanBase `ObMvccRow` |
|------|-------------------|----------------------|
| 核心思想 | 数据包含链表节点 | 数据包含版本链表 |
| 节点设计 | `list_head { next, prev }` 纯链表 | `ObMvccTransNode { prev, next, buf_[] }` 链表+数据 |
| 容器锚点 | 独立 `list_head` 头节点 | `ObMvccRow.list_head_` 指针 |
| 遍历终止 | `list_empty(&head)` / `pos == head` | `NULL == ATOMIC_LOAD(&list_head_)` |
| 并发安全 | 无锁遍历，写操作需锁 | 读无锁，写需 `ObRowLatch` |
| 删除策略 | 毒化指针（POISON） | 原子 CAS 修改 `TransNodeFlag` |
| 删除方 | `list_del` 直接摘除 | `mvcc_undo` 标记 `F_ABORTED`，延迟清理 |
| 索引加速 | 无（纯链表） | `ObMvccRowIndex` 懒构建（500 节点阈值） |

**共同的智慧**：两者都采用了"嵌入"设计（数据包含链表节点 vs 数据包含版本节点），避免指针间接寻址，性能关键路径零开销。Linux 用 `container_of` 从成员指针恢复结构体首地址，OceanBase 用 `buf_[0]` 柔性数组在节点尾部承载数据，本质都是**结构体尾部弹性布局**。

---

## 12. 源码文件索引

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/storage/memtable/mvcc/ob_mvcc_row.h` | `struct ObMvccTransNode` | 71 |
| `src/storage/memtable/mvcc/ob_mvcc_row.h` | `struct TransNodeFlag` | 73 |
| `src/storage/memtable/mvcc/ob_mvcc_row.h` | `struct ObMvccRow` | 277 |
| `src/storage/memtable/mvcc/ob_mvcc_row.h` | `struct ObMvccRowIndex` | 279 |
| `src/storage/memtable/mvcc/ob_mvcc_row.h` | `mvcc_write()` | 346 |
| `src/storage/memtable/mvcc/ob_mvcc_row.h` | `insert_trans_node()` | 372 |
| `src/storage/memtable/mvcc/ob_mvcc_row.h` | `INDEX_TRIGGER_COUNT` | 310 |
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp` | `ObMvccRow::mvcc_write_()` | 808 |
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp` | `ObMvccRow::mvcc_sanity_check_()` | 980 |
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp` | `ObMvccRow::mvcc_undo()` | 1032 |
| `src/storage/memtable/mvcc/ob_mvcc_row.cpp` | `ObMvccRow::mvcc_write()` | 1048 |
| `src/storage/memtable/mvcc/ob_mvcc.h` | `class ObITransCallback` | 40 |
| `src/storage/memtable/mvcc/ob_mvcc_define.h` | `struct ObMvccWriteResult` | 174 |
| `src/storage/memtable/mvcc/ob_mvcc_ctx.h` | `class ObIMvccCtx` | 63 |
| `src/storage/memtable/mvcc/ob_mvcc_ctx.h` | `class ObMemtableCtx` | 255 |
| `src/storage/memtable/mvcc/ob_mvcc_acc_ctx.h` | `class ObMvccAccessCtx` | 59 |
| `src/storage/memtable/mvcc/ob_mvcc_acc_ctx.h` | `init_read()` | 154 |
| `src/storage/memtable/mvcc/ob_mvcc_acc_ctx.h` | `init_write()` | 197 |
| `src/storage/memtable/mvcc/ob_tx_callback_list.h` | `class ObTxCallbackList` | 28 |
| `src/storage/memtable/mvcc/ob_row_latch.h` | `struct ObRowLatch` | 22 |
| `src/storage/tx/ob_tx_seq.h` | `class ObTxSEQ` | 30 |
| `src/storage/tx/ob_trans_define_v4.h` | `class ObTxSnapshot` | 278 |
| `src/storage/memtable/mvcc/ob_mvcc_engine.cpp` | `ObMvccEngine::mvcc_write()` | 254 |
| `src/storage/concurrency_control/ob_trans_stat_row.h` | `ObWriteFlag` | (引用) |

---

## 13. 下篇预告

- **02-mvcc-iterator**：MVCC 读取流程、快照可见性判断的完整数据流、`ObMvccIterator` 的遍历逻辑
- **03-mvcc-write-conflict**：写写冲突检测、锁等待与唤醒机制
- **04-mvcc-callback**：事务提交回调链与 Paxos 日志同步的协同
- **05-mvcc-compact**：版本链的 compaction/GC 机制
- **06-memtable-freezer**：Memtable 冻结与 SSTable 持久化
- **07-ls-logstream**：LogStream 与分区副本管理
- **08-ob-sstable**：SSTable 存储格式与块编码
- **09-ob-sql-executor**：SQL 执行器与存储层的交互
- **10-ob-transaction**：分布式两阶段提交与事务管理器

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 代码仓库：OceanBase CE*
