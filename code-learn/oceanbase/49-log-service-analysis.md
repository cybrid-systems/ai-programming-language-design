# 49 — Log Service — 日志生成、Append Callback 全链路

> 基于 OceanBase CE 主线源码
> 核心文件：`src/logservice/ob_log_service.h`、`src/logservice/ob_append_callback.h`、`src/storage/memtable/ob_redo_log_generator.h`
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

OceanBase 的事务引擎将数据变更缓存在 Memtable 中，但这些变更必须持久化为日志才能保证 ACID 的 Durability。**Log Service（日志服务）** 是连接事务层和日志复制层（PALF）的桥梁——它管理 Redo Log 的生成、提交回调和全生命周期。

### 解决的核心问题

1. **日志生成**：事务在 Memtable 上的每个数据变更（Insert/Update/Delete）都需要生成对应的 Redo Log，以便故障恢复时回放
2. **Append Callback 链**：日志提交后需要通知事务层哪些 callback 已提交，更新事务状态、推进 SCN、唤醒等待者
3. **时序追踪**：AppendCb 记录了从提交到 PALF → PALF 确认 → 回调执行的完整时序，用于性能诊断
4. **批处理优化**：多个 DML 操作可以合并成一条 Redo Log 提交，减少网络往返

### 与前文的关联

| 前文 | 关联点 |
|------|--------|
| **文章 04（Callback）** | `ObITransCallback` 定义了日志提交后的回调接口 `log_submitted_cb()` |
| **文章 11（PALF）** | PALF 提供了日志复制（Propose/Commit）的基础设施，LogService 在其之上构建 |
| **文章 13（Clog）** | Clog 是回放侧，LogService 是生成侧，两条路径以 PALF 为分界 |
| **文章 37（Memtable）** | Memtable 写入后通过 `ObITransCallback` 挂载到 callback list，等待生成 Redo Log |
| **文章 48（Data Checkpoint）** | Checkpoint 决定了 Redo Log 可以被截断的 SCN 位置 |

### 模块架构总览

```
                      ObLogService（日志服务顶层）
                            │
               ┌────────────┼────────────┐
               ▼            ▼            ▼
        ObLogHandler   PALF Env    Apply/Replay/CDC
               │                        │
               ▼                        ▼
          PALF 提交               AppendCb 回调队列
               │                        │
        ┌──────┴──────┐          ┌──────┴──────┐
        ▼             ▼          ▼             ▼
   PALF Propose    Commit     on_success   on_failure
   （Paxos）      回调通知      （log_submitted）（重试/回滚）

   事务层
        │
        ▼
   ObRedoLogGenerator.fill_redo_log()
        │
        ▼
   ObITransCallback（callback list）
        │
        ▼
   MVCC Write (RedoDataNode / ObMvccRowCallback)
```

---

## 1. ObLogService — 日志服务顶层

`ObLogService`（`ob_log_service.h` @ L95-L314）是整个日志服务的顶层入口，通过 MTL（Multi-Tenant Layer）管理每租户的日志服务实例。

### 1.1 顶层接口

```cpp
// ob_log_service.h:95-314 — doom-lsp 确认
class ObLogService
{
public:
  ObLogService();                                  // @L99
  virtual ~ObLogService();                         // @L100
  static int mtl_init(ObLogService* &logservice);  // @L101
  static void mtl_destroy(ObLogService* &logservice); // @L102
  int start();                                     // @L103
  void stop();                                     // @L104
  void wait();                                     // @L105
  void destroy();                                  // @L106
```

### 1.2 日志流管理

```cpp
  // 创建日志流（新建日志流对应的目录，以 PalfBaseInfo 为基线）
  // @L120-125
  int create_ls(const share::ObLSID &id,
                const common::ObReplicaType &replica_type,
                const share::ObTenantRole &tenant_role,
                const palf::PalfBaseInfo &palf_base_info,
                const bool allow_log_sync,
                ObLogHandler &log_handler,
                ObLogRestoreHandler &restore_handler);

  // 宕机重启恢复日志流
  // @L135-138
  int add_ls(const share::ObLSID &id,
             ObLogHandler &log_handler,
             ObLogRestoreHandler &restore_handler);

  // 获取 PALF Handle（用于提交日志）
  // @L140-141
  int open_palf(const share::ObLSID &id,
                palf::PalfHandleGuard &palf_handle);
```

- `create_ls()`：新建日志流，包括创建目录、初始化 PALF 句柄、注册副本类型等
- `add_ls()`：宕机重启时根据已有的 PALF 元数据恢复日志流
- `open_palf()`：获取 PALF 句柄，这是事务提交时调用 `append()` 的入口

### 1.3 PALF 环境初始化

```cpp
  // @L282-286
  int create_palf_env_(const palf::PalfOptions &options,
                       const char *base_dir,
                       const common::ObAddr &self,
                       common::ObILogAllocator *alloc_mgr,
                       rpc::frame::ObReqTransport *transport,
                       obrpc::ObBatchRpc *batch_rpc,
                       palf::ILogBlockPool *log_block_pool);
```

### 1.4 子服务暴露

```cpp
  ipalf::IPalfEnv *get_palf_env() { return palf_env_; }             // @L170
  ObLogReporterAdapter *get_reporter() { return &reporter_; }       // @L171
  cdc::ObCdcService *get_cdc_service() { return &cdc_service_; }    // @L172
  ObLogRestoreService *get_log_restore_service() { return &restore_service_; } // @L173
  ObLogReplayService *get_log_replay_service() { return &replay_service_; }   // @L174
  ObLogApplyService *get_log_apply_service() { return &apply_service_; }      // @L175
```

### 1.5 内部成员

```cpp
  // @L301-328
  ipalf::IPalfEnv *palf_env_;              // PALF 环境（日志复制引擎）
  ObLogApplyService apply_service_;        // 日志 Apply 服务（管理 AppendCb 回调队列）
  ObLogReplayService replay_service_;      // 日志回放服务（备库回放）
  ObRoleChangeService role_change_service_;// 角色切换服务
  ObLocationAdapter location_adapter_;     // 位置适配器
  ObLSAdapter ls_adapter_;                 // 日志流适配器
  obrpc::ObLogServiceRpcProxy rpc_proxy_;  // RPC 代理
  ObLogReporterAdapter reporter_;          // 上报适配器
  cdc::ObCdcService cdc_service_;          // CDC（Change Data Capture）
  ObLogRestoreService restore_service_;    // 日志恢复服务
  ObLogFlashbackService flashback_service_; // Flashback 服务
  ObLogMonitor monitor_;                   // 监控
```

---

## 2. ObRedoLogGenerator — Redo 日志生成器

`ObRedoLogGenerator`（`ob_redo_log_generator.h` @ L169-L219）是日志生成的核心类。它在事务提交时遍历 callback list，将每个未提交的 callback 序列化为 Redo Log 的日志条目。

### 2.1 回调辅助结构

#### ObCallbackScope — 回调范围

```cpp
// ob_redo_log_generator.h:25-43 — doom-lsp 确认
struct ObCallbackScope
{
  ObCallbackScope() : start_(nullptr), end_(nullptr), host_(nullptr), cnt_(0), data_size_(0) {}
  void reset() { ... }
  bool is_empty() const { return (nullptr == *start_) || (nullptr == *end_); }
  ObITransCallbackIterator start_;   // 起始 callback 迭代器
  ObITransCallbackIterator end_;     // 结束 callback 迭代器
  ObTxCallbackList *host_;           // 所属 callback list
  int32_t cnt_;                      // callback 数量
  int64_t data_size_;                // 序列化数据大小
};
```

`ObCallbackScope` 表示某个 callback list 中 `[start_, end_)` 范围内的 callback。每个 scope 对应一个 callback list 的一片连续 region。

#### ObRedoLogSubmitHelper — 提交辅助

```cpp
// ob_redo_log_generator.h:46-61 — doom-lsp 确认
struct ObRedoLogSubmitHelper
{
  ObRedoLogSubmitHelper() : callbacks_(), max_seq_no_(), data_size_(0), callback_redo_submitted_(true) {}
  void reset() { ... }
  ObSEArray<ObCallbackScope, 1> callbacks_; // 一条 Redo Log 中的 callbacks（可能跨多个 list）
  transaction::ObTxSEQ max_seq_no_;         // 最大序列号
  int64_t data_size_;                       // 序列化数据总量
  share::SCN log_scn_;                      // 日志 SCN（PALF 分配）
  bool callback_redo_submitted_;            // 是否需要提交标记
};
```

#### RedoLogEpoch — 日志纪元

```cpp
// ob_redo_log_generator.h:63-68 — doom-lsp 确认
struct RedoLogEpoch {
  RedoLogEpoch() : v_(0) {}
  RedoLogEpoch(int64_t v): v_(v) {}
  operator int64_t&() { return v_; }
  operator int64_t() const { return v_; }
  int64_t v_;  // 值从 0 递增，INT64_MAX 表示 "MAX"
};
```

Epoch 用于记录各个 callback list 当前的日志填充代次，"MAX" 表示该 list 的日志已全部提交。

#### ObTxFillRedoCtx — 填充上下文

```cpp
// ob_redo_log_generator.h:78-146 — doom-lsp 确认
struct ObTxFillRedoCtx
{
  ObTxFillRedoCtx() :
    tx_id_(),                                    // 事务 ID
    write_seq_no_(),                             // 写序列号（用于并行日志中选 list）
    skip_lock_node_(false),                      // 是否跳过 lock node
    all_list_(false),                            // 是否填充所有 callback list
    freeze_clock_(UINT32_MAX),                   // 冻结时钟（<= 该值的 memtable 需 flush）
    list_log_epoch_arr_(),                       // 每个 list 的日志纪元数组
    cur_epoch_(0), next_epoch_(0),               // 当前/下一纪元
    epoch_from_(0), epoch_to_(0),                // 填充范围
    list_(NULL),                                 // 当前填充的 callback list
    list_idx_(-1),                               // 从哪个 list 索引开始
    callback_scope_(NULL),                       // 当前填充的 callback scope
    buf_(NULL), buf_len_(-1), buf_pos_(-1),      // 目标缓冲区
    helper_(NULL),                               // 提交辅助
    last_log_blocked_memtable_(NULL),            // 最近阻塞的 memtable
    fill_count_(0),                              // 已填充 callback 数
    fill_round_(0),                              // 循环轮次
    is_all_filled_(false),                       // 是否全部填充完成
    reach_freeze_clock_(false),                  // 是否达到冻结时钟
    fill_time_(0)                                // 填充耗时
  {}
};
```

### 2.2 ObRedoLogGenerator 类

```cpp
// ob_redo_log_generator.h:169-219 — doom-lsp 确认
class ObRedoLogGenerator
{
public:
  ObRedoLogGenerator()
      : is_inited_(false),
        redo_filled_cnt_(0),
        redo_sync_succ_cnt_(0),
        redo_sync_fail_cnt_(0),
        callback_mgr_(nullptr),
        mem_ctx_(NULL),
        clog_encrypt_meta_(NULL)
  {}

  void reset();
  void reuse();
  int set(ObTransCallbackMgr *mgr, ObMemtableCtx *mem_ctx);       // @L190 — 绑定 callback manager
  int fill_redo_log(ObTxFillRedoCtx &ctx);                         // @L191 — 核心方法：填充 Redo Log
  int search_unsubmitted_dup_tablet_redo();                        // @L192 — 检查未提交的副本表
  int log_submitted(const ObCallbackScopeArray &callbacks, const share::SCN &scn);  // @L193
  int sync_log_succ(const ObCallbackScopeArray &callbacks, const share::SCN &scn);  // @L194
  void sync_log_fail(const ObCallbackScopeArray &callbacks, const share::SCN &scn); // @L195
```

### 2.3 fill_redo_log 核心流程

```cpp
// ob_redo_log_generator.cpp:253-302 — doom-lsp 确认
int ObRedoLogGenerator::fill_redo_log(ObTxFillRedoCtx &ctx)
{
  // 1. 准备全局变量
  ObMutatorWriter mmw;
  mmw.set_buffer(ctx.buf_, ctx.buf_len_ - ctx.buf_pos_); // 设置写入缓冲区
  transaction::ObCLogEncryptInfo encrypt_info;
  encrypt_info.init();
  ctx.helper_->reset();                                    // 重置 helper

  // 2. 构造填充回调 functor
  ObFillRedoLogFunctor functor(mem_ctx_, clog_encrypt_meta_, ctx, mmw, encrypt_info);

  // 3. 委托 callback_mgr_->fill_log() 遍历所有 callback list
  //    将未提交的 callback 序列化为 mutator row
  ret = callback_mgr_->fill_log(ctx, functor);

  // 4. 序列化元信息，完成 Redo Log
  if (ctx.fill_count_ > 0) {
    int64_t res_len = 0;
    uint8_t row_flag = ObTransRowFlag::NORMAL_ROW;
    if (OB_FAIL(mmw.serialize(row_flag, res_len, encrypt_info))) {
      ctx.fill_count_ = 0;  // 失败则标记填充数为 0
    } else {
      ctx.buf_pos_ += res_len;
    }
  }
}
```

### 2.4 callback_mgr_ 的 fill_log

`ObTransCallbackMgr::fill_log()` 是关键的多 list 调度方法：

```cpp
// ob_mvcc_trans_ctx.cpp:929-1028
int ObTransCallbackMgr::fill_log(ObTxFillRedoCtx &ctx, ObITxFillRedoFunctor &func)
{
  // 1. 根据 round-robin 策略选择优先填充的 callback list
  // 2. 计算出每个 list 中当前的 epoch 范围
  calc_list_fill_log_epoch_(list_idx, epoch_from, epoch_to); // @L967

  // 3. 从选中 list 的当前游标开始填充日志
  ctx.list_->fill_log(log_cursor, ctx, func);                // @L827

  // 4. 如果还有空间，填充其他 list 的 callback
  calc_next_to_fill_log_info_(next_log_epoch_arr, index, epoch_from, epoch_to); // @L1028

  // 5. 重复直到缓冲区满或所有 callback 已填充
}
```

#### 关于日志纪元和 list 调度

多条 callback list 的设计是为了支持并行 DML：同一事务的多个 DML 操作可能同时写入不同的 callback list，fill_log 时会按 list 为单位扫描：

1. 优先填充 `write_seq_no_` 对应的 list
2. 剩余缓冲区继续填充其他 list
3. `epoch_` 机制跟踪每个 list 的填充进度，避免重复填充

### 2.5 log_submitted — 日志已提交回调

```cpp
// ob_redo_log_generator.cpp:304-319
int ObRedoLogGenerator::log_submitted(const ObCallbackScopeArray &callbacks_arr,
                                      const share::SCN &scn)
{
  // 委托 callback_mgr_ 标记这些 callback 已提交
  int submitted_cnt = 0;
  ret = callback_mgr_->log_submitted(callbacks_arr, scn, submitted_cnt);
  ATOMIC_AAF(&redo_filled_cnt_, submitted_cnt);
}
```

最终调用到：

```cpp
// ob_mvcc_trans_ctx.cpp:1200-1253
int ObTransCallbackMgr::log_submitted(const ObCallbackScopeArray &callbacks,
                                      share::SCN scn, int &submitted)
{
  storage::ObIMemtable *last_mt = NULL;
  ARRAY_FOREACH(callbacks, i) {
    ObCallbackScope scope = callbacks.at(i);
    if (!scope.is_empty()) {
      do {
        ObITransCallback *iter = *cursor;
        // 调用每个 callback 的 log_submitted_cb()
        ret = iter->log_submitted_cb(scn, last_mt);  // @L1212
      } while (cursor++ != scope.end_);
      // 更新 callback list 的 log cursor
      ret = scope.host_->submit_log_succ(callbacks.at(i));  // @L1247
    }
  }
}
```

`ObITransCallback::log_submitted_cb()`（`ob_mvcc_trans_ctx.cpp:110-119`）：

```cpp
int ObITransCallback::log_submitted_cb(const SCN scn, storage::ObIMemtable *&last_mt)
{
  if (need_submit_log_) {
    if (OB_SUCC(log_submitted(scn, last_mt))) {
      set_scn(scn);                      // 记录提交 SCN
      need_submit_log_ = false;          // 标记已提交，不再需要生成日志
    }
  }
}
```

### 2.6 sync_log_succ — 日志同步完成

```cpp
int ObRedoLogGenerator::sync_log_succ(const ObCallbackScopeArray &callbacks_arr,
                                      const share::SCN &scn)
{
  ret = callback_mgr_->log_sync_succ(callbacks_arr, scn, sync_cnt);
  redo_sync_succ_cnt_ += sync_cnt;
}
```

### 2.7 sync_log_fail — 日志同步失败

```cpp
void ObRedoLogGenerator::sync_log_fail(const ObCallbackScopeArray &callbacks,
                                       const share::SCN &max_applied_scn)
{
  ret = callback_mgr_->log_sync_fail(callbacks, max_applied_scn, removed_cnt);
  redo_sync_fail_cnt_ += removed_cnt;
}
```

---

## 3. AppendCb — Append Callback 机制

`AppendCb`（`ob_append_callback.h` @ L23-L62）是连接 PALF 提交和事务回调的枢纽。当用户层通过 `ObLogHandler::append()` 提交日志到 PALF 后，"AppendCb" 会跟随日志一起提交——PALF 在日志被多数派确认后，会调用 `AppendCb::on_success()`。

### 3.1 AppendCbBase — 基类

```cpp
// ob_append_callback.h:24-48 — doom-lsp 确认
class AppendCbBase {
public:
  AppendCbBase() : __next_(NULL), __start_lsn_(), __scn_() {}
  virtual ~AppendCbBase() { __reset(); }

  void __reset() {
    __start_lsn_.reset(); __next_ = NULL; __scn_.reset();
  }

  const palf::LSN &__get_lsn() const { return __start_lsn_; }   // 日志在 PALF 中的 LSN
  void __set_lsn(const palf::LSN &lsn) { __start_lsn_ = lsn; }
  const share::SCN& __get_scn() const { return __scn_; }        // 日志的 SCN
  void __set_scn(const share::SCN& scn) { __scn_ = scn; }

  static AppendCb* __get_class_address(ObLink *ptr);           // ObLink ↔ AppendCb 转换
  static ObLink* __get_member_address(AppendCb *ptr);

  ObLink *__next_;    // 链表指针（用于 Apply Service 的队列管理）
private:
  palf::LSN __start_lsn_;    // 日志起始 LSN
  share::SCN __scn_;         // 日志 SCN
};
```

`AppendCbBase` 包含了：
- `__next_`：链表指针，将 `AppendCb` 连接成队列
- `__start_lsn_`：日志在 PALF 中的位置（提交时由 PALF 返回）
- `__scn_`：日志的 SCN
- `__get_class_address` 和 `__get_member_address`：`AppendCb` 和 `ObLink` 的地址转换，用于从 Apply Service 的 `ObSpLinkQueue` 中取出 callback

### 3.2 AppendCb — 虚基类

```cpp
// ob_append_callback.h:49-80 — doom-lsp 确认
class AppendCb : public AppendCbBase
{
public:
  AppendCb(): append_start_ts_(OB_INVALID_TIMESTAMP),
              append_finish_ts_(OB_INVALID_TIMESTAMP),
              cb_first_handle_ts_(OB_INVALID_TIMESTAMP) {}
  ~AppendCb() { reset(); }

  virtual int on_success() = 0;   // @L64 — PALF 多数派确认后调用
  virtual int on_failure() = 0;   // @L65 — PALF 提交失败后调用
  virtual const char *get_cb_name() const = 0;  // @L74

  // 时序追踪字段
  int64_t append_start_ts_;       // @L77 — 提交到 PALF 的起始时刻
  int64_t append_finish_ts_;      // @L78 — PALF 提交完成时刻（= 提交到 Apply Service 起始时刻）
  int64_t cb_first_handle_ts_;    // @L79 — CB 第一次被处理的时刻（不一定调用了 on_success）
};
```

### 3.3 AppendCb 的时序追踪

关键的三个时间戳：

```
append_start_ts_ → append_finish_ts_ → cb_first_handle_ts_
     │                    │                     │
  提交到 PALF        PALF 确认        Apply Service 首次取出处理
```

这三个时间戳用于性能诊断：
- `append_start_ts_` → `append_finish_ts_`：PALF 提交延迟（受 Paxos 多数派写影响）
- `append_finish_ts_` → `cb_first_handle_ts_`：队列等待延迟
- `cb_first_handle_ts_` → `on_success()` 返回：回调执行延迟

### 3.4 回调链的完整路径

当 PALF 的某条日志被多数派确认后：

```
PALF 多数派确认
    │
    ▼
PalfFSCb::update_end_lsn()          ← PALF 通知 Apply Service 位点推进
    │                                （palf_callback.h:30, applyservice L63-74: ObApplyFsCb）
    ▼
ObApplyStatus::update_palf_committed_end_lsn()
    │                                （记录最新已确认的 end_lsn/end_scn）
    ▼
ObApplyStatus::try_submit_cb_queues()
    │                                （尝试提交 cb_queue 中的任务到 apply 线程池）
    ▼
ObApplyServiceQueueTask::push()      ← 将 AppendCb 推入队列
    │                                （队列类型: ObSpLinkQueue）
    ▼
task_queue_ → apply 线程池处理
    │
    ▼
ObApplyStatus::try_handle_cb_queue()
    │                                （遍历 ObApplyServiceQueueTask 中的 Link 队列）
    ▼
AppendCb::on_success()              ← 对每个 AppendCb 调用
    │                                关键实现: 调用 ObITransCallback::log_submitted_cb()
    ▼
ObRedoLogGenerator::log_submitted()
    │
    ▼
ObITransCallback::log_submitted_cb()
    │
    ├── set_scn(scn)                ← 记录该 callback 的提交 SCN
    ├── need_submit_log_ = false    ← 标记不再需要生成日志
    └── trans_commit()              ← 通知事务层数据已持久化
                                      （如 ObMvccRowCallback 中填充 tnode 的 SCN）
```

对应的代码路径：

```cpp
// applyservice/ob_log_apply_service.cpp:446-529
int ObApplyStatus::try_handle_cb_queue(ObApplyServiceQueueTask *cb_queue, ...)
{
  // @L478: 小于确认日志位点的 cb 可以回调 on_success
  if (lsn <= palf_committed_end_lsn_ && scn <= palf_committed_end_scn_) {
    if (OB_FAIL(cb->on_success())) {    // @L486
      CLOG_LOG(ERROR, "cb on_success failed", KP(cb), K(ret));
    }
  } else {
    // 位点不足则留在队列中等待后续处理
  }
}
```

---

## 4. ObLogHandler::append — 日志提交入口

`ObLogHandler`（`ob_log_handler.h:222`）是日志流级别的提交接口：

```cpp
class ObLogHandler : public ObILogHandler, public ObLogHandlerBase
{
  // @L262-275
  int append(const void *buffer,          // 日志数据缓冲区
             const int64_t nbytes,        // 数据长度
             const share::SCN &ref_scn,   // 参考 SCN
             const bool need_nonblock,    // 是否需要非阻塞模式
             const bool allow_compress,   // 是否允许压缩
             AppendCb *cb,               // Append Callback（随日志一起提交）
             palf::LSN &lsn,             // [out] 日志的 LSN
             share::SCN &scn);           // [out] 日志的 SCN
};
```

- `need_nonblock`：如果为 true，当 PALF 队列满时返回 `OB_EAGAIN` 而非阻塞等待
- `allow_compress`：允许 PALF 对日志数据进行压缩
- `cb`：提交到 PALF 的 callback，PALF 在多数派确认或失败后回调 `on_success()/on_failure()`

---

## 5. 完整日志路径数据流

### 5.1 SQL 执行到日志提交

```
SQL 写操作 (INSERT/UPDATE/DELETE)
    │
    ▼
Memtable::set() / ObMemtableCtx::mvcc_write()
    │  创建 ObMvccRowCallback，写入 RedoDataNode
    │  callback 追加到 ObTxCallbackList
    ▼
事务提交 (start_commit)
    │
    ▼
ObMemtableCtx::fill_redo_log()      ← ob_memtable_context.cpp:650
    │  ObRedoLogGenerator::fill_redo_log()
    │  遍历 callback list，序列化 Redo Log 到缓冲区
    ▼
ObLogHandler::append(buffer, cb)    ← 写入 PALF
    │  cb = ... AppendCb 实例（内含 on_success 回调）
    ▼
PALF::submit_log()
    │  Paxos Propose → 多数派 Append → Commit
    ▼
PalfFSCb::update_end_lsn()          ← PALF 回调 Apply Service
    │
    ▼
ObApplyStatus::try_submit_cb_queues()
    │  将 AppendCb 推入回调队列
    ▼
ObApplyStatus::try_handle_cb_queue()
    │
    ├── AppendCb::on_success() → ObRedoLogGenerator::log_submitted()
    │   │                         → ObITransCallback::log_submitted_cb()
    │   │                           → set_scn(scn), need_submit_log_ = false
    │   │                           → trans_commit()（通知事务层）
    │   │                           → tx_commit()（推进版本，唤醒事务等待者）
    │   │
    │   └── ObRedoLogGenerator::sync_log_succ()
    │       → ObTxCallbackList::sync_log_succ()（更新 sync_scn, 推进游标）
    │
    ├── AppendCb::on_failure() → ObRedoLogGenerator::sync_log_fail()
    │                             → 清理未提交的 callback，回滚事务
    │
    └── AppendCb 统计打点（append_start_ts / append_finish_ts / cb_first_handle_ts）
```

### 5.2 回调链详图

```
PALF majority commit
    │
    ▼
PalfFSCb::update_end_lsn(id, end_lsn, end_scn, proposal_id)
    │                      ↑
    │               ObApplyFsCb (palf_callback.h:30)
    │
    ▼
ObApplyStatus::update_palf_committed_end_lsn(end_lsn, end_scn)
    │
    ▼
ObApplyStatus::try_submit_cb_queues()
    │  遍历所有 cb_queues_[0..APPLY_TASK_QUEUE_SIZE-1]
    │
    ▼
ObApplyServiceQueueTask::push(link)   // 将 AppendCb 作为 ObLink 入队
    │
    ▼  [apply 线程池处理]
    │
ObApplyStatus::try_handle_cb_queue(cb_queue)
    │
    │  循环：cb_queue->top() → pop()
    │              │
    │              ▼
    │    AppendCb::on_success()
    │         │
    │         ├── lsn ≤ palf_committed_end_lsn_ && scn ≤ palf_committed_end_scn_
    │         │        ? → 执行回调
    │         │        : → 留在队列中
    │         │
    │         ▼
    │    ObRedoLogGenerator::log_submitted()
    │         │
    │         ▼
    │    ObTransCallbackMgr::log_submitted()
    │         │
    │         ▼  [遍历 scope 中所有 callback]
    │    ObITransCallback::log_submitted_cb(scn, last_mt)
    │         │
    │         ├── log_submitted(scn, last_mt) // 虚函数，由子类实现
    │         │   ├── ObMvccRowCallback::log_submitted()
    │         │   │   ├── memtable_->set_rec_scn(scn)
    │         │   │   ├── memtable_->set_max_end_scn(scn)
    │         │   │   └── tnode_->fill_scn(scn) // 填充 tnode 的 SCN
    │         │   └── dec_unsubmitted_cnt_()    // 减少未提交计数
    │         │
    │         ├── set_scn(scn)
    │         └── need_submit_log_ = false
    │
    ▼
ObRedoLogGenerator::sync_log_succ()
    │
    ▼
ObTransCallbackMgr::log_sync_succ()
    │
    ▼
ObTxCallbackList::sync_log_succ(scn, sync_cnt)
    │ 更新 sync_scn，标记这些 callback 已同步
    │ tx_commit()（如果有 callback 已全部同步，触发事务 commit 回调）
    │
    ▼
trans_commit callback → 唤醒事务等待者
    （如事务提交后唤醒等待 commit 结果的客户线程）
```

### 5.3 FIFO 的日志数据结构

```
┌──────────────────────────────────────────────────────────────┐
│                    LogGroupEntry (PALF 层)                    │
├──────────────────────────────────────────────────────────────┤
│  Header: magic, version, log_proposal_id, compress_type...   │
├──────────────────────────────────────────────────────────────┤
│  ┌────────────────────────┐  ┌─────────────┐  ┌────────┐     │
│  │  LogEntry (Redo Log)   │  │  LogEntry   │  │  ...   │     │
│  │  ── mutator header      │  │  (其他日志)  │  │        │     │
│  │  ── RowDataNode 1       │  │              │  │        │     │
│  │  ── RowDataNode 2       │  │              │  │        │     │
│  │  ── RowDataNode N       │  │              │  │        │     │
│  │  ── meta footer         │  │              │  │        │     │
│  └────────────────────────┘  └─────────────┘  └────────┘     │
├──────────────────────────────────────────────────────────────┤
│  Trailer: checksum...                                        │
└──────────────────────────────────────────────────────────────┘
```

---

## 6. 与前面文章的关系

### 文章 04 — Callback（ObITransCallback）

这是整个回调链的起点。`ObITransCallback`（`ob_mvcc.h:40`）定义了：
- `log_submitted(scn, last_mt)`：日志提交时调用的虚函数
- `log_submitted_cb(scn, last_mt)`：外层包装函数，调用虚函数并更新状态
- `log_sync_fail(scn)`：日志同步失败时的回调

`ObRedoLogGenerator` 遍历的是 `ObITransCallback` 组成的 callback list，生成日志的核心数据来源就是 `ObMvccRowCallback`（`ObITransCallback` 子类）。

### 文章 11 — PALF

`ObLogHandler::append()` 是事务层调用 PALF 的入口。PALF 提供：
- `submit_log()`：Paxos 协议的 Propose 阶段
- 多数派 Append 后的 Commit
- `PalfFSCb::update_end_lsn()`：通知上层位点推进
- `PalfFSCb` 到 `ObApplyFsCb` → `ObApplyStatus` → 最终触发 `AppendCb::on_success()`

### 文章 13 — Clog（日志回放）

Clog（回放）和 LogService（生成）是 PALF 的两侧：
- 生成侧：事务引擎 → `ObRedoLogGenerator` → `ObLogHandler::append()` → PALF
- 回放侧：PALF → `ObLogReplayService` → 回放 Memtable（备库/故障恢复）

两者的交界是 PALF；PALF 确保日志在多数派上持久化后，主库通过 AppendCb 通知事务层，备库通过回放服务重放。

### 文章 37 — Memtable

当数据写入 Memtable 时，`ObMvccRowCallback` 被创建并挂载到 `ObTxCallbackList`：
- `ObMemtableCtx::mvcc_write()` → 创建 `ObMvccRowCallback`
- `ObTxCallbackList::append_callback()` → 追加到 callback list
- 事务提交时，`fill_redo_log()` 遍历 callback list 生成 Redo Log

### 文章 48 — Data Checkpoint

Checkpoint 决定了日志截断的 SCN：
- `ObMvccRowCallback::log_submitted()` 中调用 `memtable_->set_rec_scn(scn)`
- 这个 SCN 会被 `ObCommonCheckpoint::get_rec_scn()` 获取
- `ObDataCheckpoint` 推进 checkpoint SCN，PALF 才能安全截断该 SCN 之前的日志

---

## 7. 设计决策

### 7.1 Redo Log 与 Checkpoint 日志的区分

OceanBase 的日志体系中有两种日志：

| 类型 | 生成时机 | 内容 | 使用者 |
|------|---------|------|--------|
| **Redo Log** | 事务提交时 | `ObMvccRowCallback` 序列化的行数据 | 故障恢复时回放 |
| **Checkpoint 日志** | 数据检查点时 | Checkpoint SCN + 元数据 | PALF 日志截断 |

Redo Log 是事务粒度的，Checkpoint 日志是数据持久化粒度的。两者共同工作：Checkpoint 日志告诉 PALF "此 SCN 之前的数据已落盘"，PALF 才可安全回收日志空间。

### 7.2 Append Callback 与 ObITransCallback 的回调链设计

```
PALF commit → AppendCb::on_success()
                ↓
            RedoLogGenerator::log_submitted()
                ↓
            ObTransCallbackMgr::log_submitted()
                ↓  对每个 callback:
            ObITransCallback::log_submitted_cb()
                ↓
            子类实现 (如 ObMvccRowCallback::log_submitted())
                ↓
            更新 memtable SCN + 通知事务层
```

这种分层设计的好处：
- **AppendCb** 是 PALF 层回调，关注"日志是否已被多数派确认"
- **ObITransCallback** 是事务层回调，关注"我的数据变更是否已持久化"
- 两者通过 `ObRedoLogGenerator` 连接，`log_submitted()` 和 `sync_log_succ()` 是两个不同的阶段

`log_submitted` vs `sync_log_succ` 的区别：

| 阶段 | 触发条件 | 作用 |
|------|---------|------|
| `log_submitted` | AppendCb::on_success() | 标记 callback 已提交（分配 SCN），释放未提交计数 |
| `sync_log_succ` | AppendCb::on_success() 之后 | 确认日志已同步到多数派，标记 callback 可清理 |
| `sync_log_fail` | AppendCb::on_failure() | 清理未提交成功的 callback，回滚事务 |

### 7.3 日志批处理优化

`ObRedoLogGenerator::fill_redo_log()` 支持一次填充多个 callback 到同一条 Redo Log：
- `ObCallbackScope` 表示一个连续范围，可能包含多个 DML 操作的 callback
- `ObRedoLogSubmitHelper` 中的 `callbacks_` 数组可以跨多个 callback list
- 批处理减少了 PALF 提交的次数，降低了 Paxos 多数派写的网络开销

批处理的范围受两个因素限制：
1. **缓冲区大小**：`ctx.buf_len_` 决定了单次填充的最大数据量
2. **epoch 边界**：`epoch_from_` 到 `epoch_to_` 限制了本次填充的范围，避免重复

### 7.4 日志大小与写入延迟的权衡

- **小日志**：延迟低（PALF 提交快），但吞吐低（频繁 Paxos 往返）
- **大日志**：吞吐高（批处理多个 DML），但延迟高（单个日志大，PALF 复制慢）

OceanBase 通过 `fill_redo_log()` 中的缓冲区策略自动平衡：优先填满缓冲区，但如果 callback 范围小则立即提交。

### 7.5 非阻塞写入

`ObLogHandler::append()` 的 `need_nonblock` 参数允许事务层在 PALF 队列满时选择：
- `true`：返回 `OB_EAGAIN`，不上层线程等待，转而做其他工作（如 FLSR 策略）
- `false`：阻塞等待 PALF 队列有空位

这种设计避免了 PALF 背压时事务线程全部阻塞。

### 7.6 多条 Callback List 的并发设计

`ObTransCallbackMgr` 维护多条 callback list（`callback_lists_`，最多 `MAX_CALLBACK_LIST_COUNT` 条）：

```
ObTransCallbackMgr
    │
    ├── callback_list_[0] (ObTxCallbackList)
    │   └── ObITransCallback 双向链表
    ├── callback_list_[1]
    │   └── ObITransCallback 双向链表
    ├── ...
    └── callback_list_[N]
```

并行 DML 时，`write_seq_no_` 决定选择哪个 list。`fill_log()` 的 round-robin 调度确保各 list 公平推进。

---

## 8. 源码索引

| 文件 | 关键行 | 内容 |
|------|--------|------|
| `src/logservice/ob_log_service.h` | L95-L314 | `ObLogService` 类定义 |
| `src/logservice/ob_log_service.h` | L112-125 | `create_ls()` 创建日志流 |
| `src/logservice/ob_log_service.h` | L170-175 | 子服务访问接口 |
| `src/logservice/ob_log_service.h` | L301-328 | 内部成员变量 |
| `src/logservice/ob_log_handler.h` | L222-472 | `ObLogHandler` 日志流句柄 |
| `src/logservice/ob_log_handler.h` | L262-275 | `append()` 日志提交接口 |
| `src/logservice/ob_append_callback.h` | L24-48 | `AppendCbBase` 基类 |
| `src/logservice/ob_append_callback.h` | L49-80 | `AppendCb` 虚基类（on_success/on_failure） |
| `src/logservice/applyservice/ob_log_apply_service.h` | L63-74 | `ObApplyFsCb` PALF 回调类 |
| `src/logservice/applyservice/ob_log_apply_service.h` | L108-174 | `ObApplyStatus` 状态管理 |
| `src/logservice/applyservice/ob_log_apply_service.cpp` | L446-529 | `try_handle_cb_queue` `on_success` 回调执行 |
| `src/logservice/palf/palf_callback.h` | L30-37 | `PalfFSCb` PALF 回调接口 |
| `src/storage/memtable/ob_redo_log_generator.h` | L25-43 | `ObCallbackScope` 回调范围 |
| `src/storage/memtable/ob_redo_log_generator.h` | L46-61 | `ObRedoLogSubmitHelper` 提交辅助 |
| `src/storage/memtable/ob_redo_log_generator.h` | L63-68 | `RedoLogEpoch` 日志纪元 |
| `src/storage/memtable/ob_redo_log_generator.h` | L78-146 | `ObTxFillRedoCtx` 填充上下文 |
| `src/storage/memtable/ob_redo_log_generator.h` | L169-219 | `ObRedoLogGenerator` 类定义 |
| `src/storage/memtable/ob_redo_log_generator.cpp` | L253-302 | `fill_redo_log()` 核心实现 |
| `src/storage/memtable/ob_redo_log_generator.cpp` | L304-319 | `log_submitted()` |
| `src/storage/memtable/ob_redo_log_generator.cpp` | L321-356 | `sync_log_succ()` / `sync_log_fail()` |
| `src/storage/memtable/mvcc/ob_mvcc.h` | L40-193 | `ObITransCallback` 接口定义 |
| `src/storage/memtable/mvcc/ob_mvcc.h` | L82 | `log_submitted_cb()` |
| `src/storage/memtable/mvcc/ob_mvcc_trans_ctx.cpp` | L110-119 | `log_submitted_cb()` 实现 |
| `src/storage/memtable/mvcc/ob_mvcc_trans_ctx.cpp` | L1200-1253 | `ObTransCallbackMgr::log_submitted()` |
| `src/storage/memtable/mvcc/ob_mvcc_trans_ctx.cpp` | L1263-1281 | `prepare_log_submitted()` |
| `src/storage/memtable/mvcc/ob_mvcc_trans_ctx.cpp` | L1591-1657 | `ObMvccRowCallback::log_submitted()` |

---

## 9. 总结

Log Service 是 OceanBase 事务引擎的"日志脊梁"——它将 Memtable 上的数据变更转化为持久化的 Redo Log，通过 PALF 的 Paxos 协议复制到多数派副本，并通过 Append Callback 链将提交结果传回事务层。

核心设计理念：

1. **解耦分层**：Log Service 将日志生成（`ObRedoLogGenerator`）、日志复制（PALF）、回调通知（`AppendCb` → `ObITransCallback`）三个环节严格分离
2. **批处理提升吞吐**：多个 callback 合并为一条 Redo Log 提交，减少 Paxos 写入次数
3. **精度追踪**：AppendCb 的三时间戳设计为性能诊断提供了精确手段
4. **异常处理**：`on_success`/`on_failure` 双路回调确保日志提交结果能被事务层正确处理
