# 34 — SSTable Merge 策略：Mini/Minor/Major/Medium 合并路径

> 基于 OceanBase 主线源码（`src/storage/compaction/`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

前 33 篇文章覆盖了 OceanBase 存储引擎的完整技术栈。文章 05（Compact）分析了 MVCC 行级版本链的压缩，文章 06（Freezer）介绍了 Memtable 冻结机制，文章 07（LS Tree）展示了 SSTable 的分层架构。现在深入 LS Tree 的核心维护机制——**SSTable Merge（Compaction）**。

SSTable Merge 是 LSM-Tree 引擎中最核心的系统级操作，负责：

1. **层级降级**：将热数据从 Memtable → L0 Mini SSTable → L1 Minor SSTable → 最终合并到底层
2. **空间回收**：清理已删除/过期的数据行，回收存储空间
3. **版本合并**：将多版本数据合并，标记不再需要的旧版本
4. **读写平衡**：控制读放大（Read Amplification）和写放大（Write Amplification）的 trade-off

OceanBase 的 LS Tree 设计了 **4 种聚合并类型 + 多种特殊合并**，构成了完整的 Compaction 体系。

### 合并类型总览

| 类型 | 枚举值 | 输入来源 | 输出 | 触发条件 | 代码入口 |
|------|--------|---------|------|---------|---------|
| **Mini Merge** | `MINI_MERGE` | 冻结 Memtable | Mini SSTable | Memtable Freeze 完成 | `ObTabletMiniMergeCtx` |
| **Minor Merge** | `MINOR_MERGE` | 多个 Mini + Minor SSTable | L1 Minor SSTable | Mini 数量达阈值 | `ObTabletExeMergeCtx` |
| **Medium Merge** | `MEDIUM_MERGE` | Major + Minor SSTable | Inc Major SSTable | 时间/大小/SCN 阈值 | `ObMediumCompactionScheduleFunc` |
| **Major Merge** | `MAJOR_MERGE` | 所有层级 SSTable | Major SSTable | RootServer 调度 Freeze | `ObTabletMajorMergeCtx` |
| **MDS Mini Merge** | `MDS_MINI_MERGE` | MDS Memtable | MDS Mini SSTable | MDS Freeze | — |
| **DDL KV Merge** | `DDL_KV_MERGE` | DDL 临时数据 | DDL SSTable | DDL 完成 | — |
| **Backfill Tx Merge** | `BACKFILL_TX_MERGE` | 事务回填数据 | 增量 SSTable | 事务提交 | — |

**源码位置**：`ob_compaction_util.h:20-43`（`ObMergeType` 枚举定义）

```cpp
// ob_compaction_util.h:20-43 — doom-lsp 确认
enum ObMergeType : uint8_t
{
  INVALID_MERGE_TYPE = 0,
  MINOR_MERGE,          // 合并多个 mini sstable 为一个更大的 mini sstable
  HISTORY_MINOR_MERGE,
  META_MAJOR_MERGE,
  MINI_MERGE,           // 只 flush memtable
  MAJOR_MERGE,
  MEDIUM_MERGE,
  DDL_KV_MERGE,         // 仅用于 DDL dag
  BACKFILL_TX_MERGE,
  MDS_MINI_MERGE,
  MDS_MINOR_MERGE,
  BATCH_EXEC,           // ObBatchExecDag
  CONVERT_CO_MAJOR_MERGE, // 行存 major → 列存 CG SSTable
  INC_MAJOR_MERGE,
  MERGE_TYPE_MAX
};
```

类型判断辅助函数（`ob_compaction_util.h:48-105`）提供了清晰的语义分类：

- `is_mini_merge()` — 仅 Mini
- `is_minor_merge()` / `is_minor_merge_type()` — Minor + History Minor
- `is_medium_merge()` — Medium
- `is_major_merge()` — 严格 Major
- `is_major_merge_type()` — Medium + Major + Convert Co Major
- `is_multi_version_merge()` — 涉及多版本合并的（Mini/Minor/History Minor/Backfill/MDS Minor）
- `is_mds_merge()` — MDS 特有的合并

---

## 1. LS Tree 的四层合并架构

### 1.1 层级结构与数据流向

```
                   写入路径（用户事务）
                          │
                          ▼
                ╔══════════════════╗
                ║  Active Memtable ║
                ╚══════════════════╝
                          │ Freeze（文章 06）
                          ▼
                ╔══════════════════╗
                ║  Frozen Memtable ║
                ╚══════════════════╝
                          │
                    ══════╪══════    ←───  Mini Merge 触发点
                          │
               ┌──────────┴──────────┐
               │                     │
               ▼                     ▼
     ╔════════════════════┐  ╔═════════════════════
     ║  L0: Mini SSTable  ║  ║  MDS Mini SSTable  ║
     ╚════════════════════╛  ╚════════════════════╛
               │                     │
               │   Mini 数量 >        │
               │  阈值 → Minor Merge  │   MDS Minor Merge
               ▼                     ▼
     ╔════════════════════════════════════
     ║      L1: Minor SSTable           ║
     ║  (多个 Mini 合并为一个 Minor)      ║
     ╚═══════╦═══════════════════════════╛
              │
              │  Medium Merge 触发
              │  (时间/大小/Schema 变化)
              ▼
     ╔════════════════════════════════════
     ║    L2: Inc Major SSTable         ║
     ║  (Medium Merge 的结果)            ║
     ╚═══════╦═══════════════════════════╛
              │
              │  Major Merge（RootServer 调度）
              ▼
     ╔════════════════════════════════════
     ║    L3: Major SSTable             ║
     ║  (全量合并，每个 Tablet 最多一个)  ║
     ╚═══════════════════════════════════╛
```

### 1.2 层次的数量限制

OceanBase 不像 LevelDB 那样存在固定的层级数量。`ObTabletTableStore` 中 SSTable 的组织方式：

| Table Store 容器 | 存放内容 | 最多数量 |
|-----------------|---------|---------|
| `major_tables_` | Major SSTable | 通常 1 个 |
| `inc_major_tables_` | Medium / Inc Major SSTable | 可多个 |
| `minor_tables_` | Mini + Minor SSTable | 可多个 |
| `mds_sstables_` | MDS SSTable | 可多个 |

**关键设计**：`minor_tables_` 同时承载 L0 和 L1 的数据。区分它们不靠数组位置，而是靠 SCN 范围和 SSTable 类型。Mini SSTable 的 SCN 范围窄（仅对应一次 Freeze 的日志范围），而 Minor SSTable 的 SCN 范围更宽。

### 1.3 ObTabletTableStore 的 SSTable 容器

```cpp
// ob_tablet_table_store.h:561-572 — doom-lsp 确认
ObTableStoreIterator major_tables_;         // Major SSTable
ObTableStoreIterator inc_major_tables_;     // Inc Major（Medium Merge 结果）
ObTableStoreIterator minor_tables_;         // Mini + Minor SSTable
ObTableStoreIterator mds_sstables_;         // MDS SSTable
ObTableStoreIterator ddl_sstables_;         // DDL SSTable
ObTableStoreIterator inc_major_ddl_sstables_;
ObTableStoreIterator memtables_;            // 活跃 + 冻结 Memtable
```

---

## 2. Mini Merge — Memtable 到 Mini SSTable

### 2.1 触发机制

Mini Merge 是 Freeze 流程的下游。文章 06（Freezer）描述了 Memtable 冻结的完整流程，冻结完成后立即触发 Mini Merge：

```
Memtable Freeze 完成
    ↓
ObMemtableCompactWriter 将冻结 Memtable 的数据
写入 Macro Block
    ↓
ObBlockOp 决定每个 Macro/Micro Block 的操作策略
    ↓
生成的 Mini SSTable 注册到 LS Tree 的 minor_tables_
    ↓
try_schedule_compaction_after_mini() 检查是否满足
Minor Merge 条件
```

### 2.2 ObTabletMiniMergeCtx — Mini 合并上下文

```cpp
// ob_tablet_merge_ctx.h:74-94 — doom-lsp 确认
class ObTabletMiniMergeCtx : public ObTabletMergeCtx
{
  // 继承自 ObTabletMergeCtx:
  virtual int get_merge_tables(...);       // 获取待合并的表
  virtual int prepare_schema(...);         // 准备 Schema
  virtual int update_tablet(...);          // 合并后更新 Tablet
  virtual int after_update_tablet(...);    // 完成后的清理工作
  virtual int update_tablet_directly(...); // 直接更新 Tablet 引用

  // 特有方法:
  int pre_process_tx_data_table_merge(...);  // 事务数据预处理
  void try_schedule_compaction_after_mini(); // 判断是否需要继续 Minor Merge
  int record_uncommitted_sstable_cnt(...);   // 记录未提交 SSTable 数量
  int try_report_tablet_stat_after_mini(...); // 上报 Tablet 统计
};
```

### 2.3 ObBlockOp — Macro Block 操作策略

Mini Merge 在写入每个 Macro Block 时，需要决定该 Block 是重用还是重新写入。`ObBlockOp`（`ob_block_op.h`）定义了 4 种操作：

```
OP_NONE = 0     → 直接复用（内容不变，跳过解码-编码流程）
OP_OPEN = 1     → 打开范围，遍历 Micro Block / Macro Block
OP_REWRITE = 2  → 打开范围，遍历行（兼容旧格式）
OP_FILTER = 3   → 过滤掉该宏块/Micro Block

操作优先级（fuse 语义）：
  OP_NONE < OP_OPEN / OP_REWRITE < OP_FILTER
```

**实现细节**：`ObBlockOp::fuse()` 取多个操作的最大值，确保最严格的操作被选中。例如如果一个 Block 在部分行程中被标记为 OP_REWRITE，其他行程中标记为 OP_NONE，则最终 fusion 为 OP_REWRITE。

### 2.4 数据流

```
Mini Merge 数据流：

冻结 Memtable (ObMemtable)
  │
  ├── ObMemtableCompactWriter (文章 06)
  │    └── 行级迭代 → ObPartitionMergeIter
  │         └── Merging 多路合并
  │              └── ObBlockOp 决策
  │                   ├── OP_NONE → Macro Block 直接复用
  │                   ├── OP_OPEN → 解码-过滤-重新编码
  │                   └── OP_FILTER → 跳过（数据已过期）
  │
  └── ObSSTableBuilder
       └── 构建 Mini SSTable（包含 Index Block + Macro Block）
            └── 注册到 ObTabletTableStore::minor_tables_
```

---

## 3. Minor Merge — Mini 到 L1 的增量合并

### 3.1 触发条件

Mini Merge 完成后，`ObTabletMiniMergeCtx::try_schedule_compaction_after_mini()`（`ob_tablet_merge_ctx.h:92`）检查是否满足 Minor Merge 条件。触发条件包括：

1. **Mini SSTable 数量阈值**：当 L0 的 Mini SSTable 数量超过 `compaction_estimate` 计算出的并发上限
2. **写入压力**：写入速度过快时，需要加速合并以控制读放大
3. **内存压力**：系统内存紧张时，需要尽早将 Mini SSTable 合并为更大的 Minor SSTable

### 3.2 ObTabletExeMergeCtx — 执行型合并上下文

Minor 和 Medium 合并使用 `ObTabletExeMergeCtx`：

```cpp
// ob_tablet_merge_ctx.h:97-114 — doom-lsp 确认
class ObTabletExeMergeCtx : public ObBasicTabletMergeCtx
{
  virtual int prepare_schema(...);
  virtual int get_merge_tables(...);      // 获取所有待合并的 SSTable 列表
  virtual int cal_merge_param(...);       // 计算合并参数
  int get_tables_by_key(...);             // 按 key 获取 tables
  int prepare_compaction_filter(...);     // 准备过滤器
  int get_recycle_version(...);           // 获取回收版本
  int init_static_param_tx_id(...);       // 初始化事务静态参数
};
```

### 3.3 合并算法

Minor Merge 的合并过程本质上是**多路归并（Multi-Way Merge）**：

```
Input: N 个 Mini/Minor SSTable（按行键范围排序的 multiple runs）
         ↓
         ObPartitionMergeIter — N 路合并迭代器
         ↓
         逐行比较行键 → 去重（只保留最新版本）
         ↓
         编码 → ObSSTableBuilder → Macro Block 写入
         ↓
Output: 1 个新的 Minor SSTable
```

多路合并的核心迭代器在 `ob_partition_merge_iter.h` 和 `ob_partition_rows_merger.h` 中实现。

---

## 4. Medium Merge — L1 到 L2 的部分区域合

### 4.1 异于标准 LSMTree

Medium Merge 是 OceanBase **区别于标准 LSM-Tree** 的核心设计。它不是对整个 Tablet 做全量合并，而是**只合并部分数据**——具体来说，是合并 Major SSTable 的一部分版本范围与对应的 Minor SSTable。

### 4.2 触发条件

`ObMediumCompactionScheduleFunc`（`ob_medium_compaction_func.h:25`）负责 Medium Merge 的调度决策。触发条件包括：

1. **时间间隔**：超过 `medium_compaction_interval` 配置的时间
2. **数据量**：自上次 Medium Merge 以来累积的增量数据超过阈值
3. **Schema 变化**：检测到 Schema 变更（`check_if_schema_changed`）
4. **Adaptive Merge Policy**：`ObAdaptiveMergePolicy` 自适应策略判断需要 Medium Merge

### 4.3 调度流程

Medium Merge 的调度流程由 `ObMediumCompactionScheduleFunc` 驱动，在 `ObLS::schedule_medium_compaction()` 中调用：

```cpp
// ob_medium_compaction_func.h — 调度函数
class ObMediumCompactionScheduleFunc
{
  int schedule_next_medium_for_leader(    // Leader 节点上的 Medium 调度
    const int64_t major_snapshot,
    bool &medium_clog_submitted);

  static int check_if_schema_changed(     // 检查 Schema 是否变化
    const ObTablet &tablet,
    const ObStorageSchema &storage_schema,
    const uint64_t data_version,
    bool &is_schema_changed);
};
```

### 4.4 Medium Merge 的数据流

```
Medium Merge:
                                ┌─────────────────────┐
                                │   Major SSTable      │
                                │  (L3, base version)  │
                                └─────────┬───────────┘
                                          │
                ╔═════════════════════════╪══════════════╗
                ║  Medium Merge Scope     │              ║
                ║  (部分版本区间)          │              ║
                ║                         ▼              ║
                ║  ┌──────────────────────────────┐      ║
                ║  │     Minor SSTable 集合        │      ║
                ║  │  (自上次 Medium 后的增量数据)   │      ║
                ║  └────────────┬─────────────┬───┘      ║
                ╚═══════════════╪═════════════╪══════════╝
                                │             │
                                ▼             ▼
                    ┌──────────────────────────────┐
                    │   Inc Major SSTable (L2)     │
                    │  (Medium Merge 输出)          │
                    └──────────────────────────────┘
```

**关键区别**：Major Merge 包含所有数据并生成新的全量 Major SSTable，而 Medium Merge 只合并**增量部分**，输出为 Inc Major SSTable（存于 `inc_major_tables_` 容器）。

---

## 5. Major Merge — 全量合并

### 5.1 RootServer 调度

Major Merge 由 RootServer 全局调度。文章 27（RootServer）中提到 RootServer 负责决定何时触发 Major Freeze，而 Major Freeze 会触发所有 Tablet 的 Major Merge。

执行流程：

```
RootServer (RS)
  │
  └── 决定触发 Major Freeze
       │
       └── 广播 Major Freeze 请求给所有 OBServer
            │
            └── 每个 OBServer 的 ObBasicMergeScheduler::schedule_merge()
                 │
                 └── 遍历所有 LS 的所有 Tablet
                      │
                      └── 对每个 Tablet 提交 ObTabletMergeDag
                           │
                           └── 在 DAG 引擎中执行 Major Merge
```

### 5.2 ObTabletMajorMergeCtx

```cpp
// ob_tablet_merge_ctx.h:117-128 — doom-lsp 确认
class ObTabletMajorMergeCtx : public ObTabletExeMergeCtx
{
  virtual int prepare_schema(...);        // 准备完整的 Schema
  virtual int try_swap_tablet(...);       // 尝试交换 Tablet 引用
  virtual int cal_merge_param(...);       // 计算合并参数
  virtual int prepare_compaction_filter(...); // 准备合并过滤器
};
```

### 5.3 ObBasicMergeScheduler — 全局合并调度器

```cpp
// ob_compaction_schedule_util.h:116-156 — doom-lsp 确认
class ObBasicMergeScheduler
{
  int could_major_merge_start();           // 判断能否开始 Major Merge
  int stop_major_merge();                  // 停止 Major Merge
  int resume_major_merge();               // 恢复 Major Merge
  int schedule_merge();                    // 调度所有 Tablet 的合并
  int update_merged_version();             // 更新合并版本
  int is_compacting();                     // 检查是否正在合并
  int get_frozen_version();                // 获取冻结版本号
  int get_merged_version();                // 获取已合并版本

  int64_t frozen_version_;                 // 当前冻结版本
  int64_t merged_version_;                 // 当前已合并版本
  ObMergeInfo merge_info_;                 // 合并信息
};
```

`ObBasicMergeScheduler` 还支持两种调度模式（`ob_compaction_schedule_util.h:28-32`）：

```cpp
enum ObCompactionScheduleMode
{
  COMPACTION_NORMAL_MODE,    // 普通模式：持续逐步合并
  COMPACTION_WINDOW_MODE,    // 窗口模式：在指定时间窗口内集中合并
  COMPACTION_MAX_MODE
};
```

### 5.4 ObStaticMergeParam — 静态合并参数

```cpp
// ob_basic_tablet_merge_ctx.h:96-191 — doom-lsp 确认
class ObStaticMergeParam
{
  // 初始化各项合并参数
  int init_static_info(...);
  int init_sstable_logic_seq(...);         // SSTable 逻辑序列号
  int init_sstable_schema_changed(...);    // Schema 变更标记
  int init_sstable_need_full_merge(...);   // 是否需要全量合并
  int init_merge_version_range(...);       // 合并版本范围
  int cal_major_merge_param(...);          // 计算 Major Merge 参数
  int init_progressive_mgr_and_check(...); // 渐进式合并管理器

  // 字段
  ObMergeSSTableOp merge_sstable_op_array_[];
  ObMajorMergeSSTableStatusArray major_merge_sstable_status_array_[];
  int64_t merge_level_;                    // MACRO_BLOCK / MICRO_BLOCK 级别
  bool is_full_merge_;
  bool need_parallel_minor_merge_;
  // ...
};
```

合并级别（`ObMergeLevel`）定义了两个粒度：

```cpp
// ob_compaction_util.h:138-141 — doom-lsp 确认
enum ObMergeLevel : uint8_t
{
  MACRO_BLOCK_MERGE_LEVEL = 0,   // Macro Block 级合并（最粗粒度）
  MICRO_BLOCK_MERGE_LEVEL = 1,   // Micro Block 级合并（精细粒度）
  MERGE_LEVEL_MAX
};
```

---

## 6. Compaction DAG 调度

### 6.1 DAG 引擎架构

OceanBase 使用 DAG（有向无环图）引擎来调度 compaction 任务。合并操作不是直接调用的函数，而是包装为一个 `ObTabletMergeDag` 提交给 DAG 引擎调度。

### 6.2 ObCompactionDagRanker — 合并 DAG 优先级排序

```cpp
// ob_compaction_dag_ranker.h:144-187 — doom-lsp 确认
class ObCompactionDagRanker
{
  int process();                              // 执行排序
  int prepare_rank_dags_();                   // 准备待排序的 DAG 列表
  int sort_();                                // 根据优先级排序
  int move_dags_to_ready_dag_list_();         // 将就绪 DAG 移到执行队列

  ObDagList ready_dag_list_;                  // 就绪执行队列
  ObDagList rank_dag_list_;                   // 待排序 DAG 列表
  ObCompactionRankHelper *rank_helper_;       // 通用排名辅助
  ObMiniCompactionRankHelper *mini_helper_;   // Mini 合并排名辅助
  ObMinorCompactionRankHelper *minor_helper_; // Minor 合并排名辅助
  ObMajorCompactionRankHelper *major_helper_; // Major 合并排名辅助
};
```

每种合并类型都有专门的排名辅助类，使用不同的权重计算：

- **ObMiniCompactionRankHelper**：基于 replay interval（WAL 回放间隔）排序，回放间隔越大优先级越高
- **ObMinorCompactionRankHelper**：基于 SSTable 数量和占用空间排序
- **ObMajorCompactionRankHelper**：基于 compaction SCN 范围排序

### 6.3 优先级计算

合并优先级通过 `get_rank_weighed_score()` 计算，它综合以下因素：

| 因素 | 影响 | 适用合并 |
|------|------|---------|
| 等待时间（`rank_time_`） | 等待越久优先级越高 | 全部 |
| 占用空间（`occupy_size`） | 占空间越大越优先 | Mini / Minor |
| SSTable 数量 | 数量越多越优先 | Minor |
| Replay Interval | 回放间隔越大越优先 | Mini |
| Compaction SCN | SCN 差距越大越优先 | Major |

**源码位置**：`ob_compaction_dag_ranker.h:64-139`，具体实现分散在四个 `*Helper` 类中。

### 6.4 内存估计

`ObCompactionEstimator`（`ob_compaction_dag_ranker.h:34`）提供合并过程中的内存预算估计：

```cpp
// ob_compaction_dag_ranker.h:48-60
static const int64_t DEFAULT_MERGE_THREAD_CNT = 4;
static const int64_t MAX_MEM_PER_THREAD = 64 * 1024 * 1024;  // 64 MB/线程
static const int64_t MINI_MEM_PER_THREAD = 32 * 1024 * 1024; // 32 MB/线程
static const int64_t MINOR_MEM_PER_THREAD = 32 * 1024 * 1024;
static const int64_t MAJOR_MEM_PER_THREAD = 64 * 1024 * 1024;
static const int64_t COMPACTION_BLOCK_FIXED_MEM = 4 * 1024 * 1024;
static const int64_t COMPACTION_CONCURRENT_MEM_FACTOR = 2;
static const int64_t DEFAULT_BATCH_SIZE = 1;
```

---

## 7. 合并诊断

### 7.1 ObCompactionDiagnoseMgr — 诊断管理器

```cpp
// ob_compaction_diagnose.h:486-631 — doom-lsp 确认
class ObCompactionDiagnoseMgr
{
  // 诊断入口
  int diagnose_all_tablets(...);              // 诊断所有 Tablet
  int diagnose_tenant_tablet(...);            // 诊断指定租户的 Tablet
  int diagnose_tenant_major_merge(...);       // 诊断 Major Merge 状态
  int diagnose_tablet_merge(...);             // 诊断单个 Tablet 合并

  // 按类型诊断
  int diagnose_tablet_mini_merge(...);
  int diagnose_tablet_minor_merge(...);
  int diagnose_tablet_medium_merge(...);
  int diagnose_tablet_major_merge(...);
  int diagnose_tablet_multi_version_start(...); // 多版本起点诊断

  // DAG 诊断
  int diagnose_dag(...);
  int diagnose_row_store_dag(...);
  int diagnose_column_store_dag(...);
  int diagnose_no_dag(...);

  // 状态管理
  ObDiagnoseStatus diagnostic_status_;
  DiagnoseTabletArray info_array_;
  int64_t suspect_tablet_count_;
  int64_t multi_version_diagnose_tablet_count_;
};
```

诊断结果包含 5 种状态：

```cpp
// ob_compaction_diagnose.h:462-470
enum ObDiagnoseStatus
{
  DIA_STATUS_NOT_SCHEDULE,       // 未调度
  DIA_STATUS_RUNNING,            // 正在运行
  DIA_STATUS_WARN,               // 警告
  DIA_STATUS_FAILED,             // 失败
  DIA_STATUS_RS_UNCOMPACTED,     // RS 未合并
  DIA_STATUS_SPECIAL,            // 特殊状态
  DIA_STATUS_MAX
};
```

### 7.2 调度可疑信息

`ObScheduleSuspectInfo` 和 `ObScheduleSuspectInfoMgr` 记录调度过程中发现的异常情况：

```cpp
// ob_compaction_diagnose.h:172-186
class ObScheduleSuspectInfo : public ObIDiagnoseInfo
{
  int64_t add_time_;     // 记录时间
  uint64_t hash_;        // 去重哈希
  ObInfoParamType info_; // 异常类型
};
```

---

## 8. 合并过滤器

合并过程中可以使用多种过滤器来决定哪些行应该被保留或丢弃：

### 8.1 过滤器类型

| 过滤器 | 用途 | 所在文件 |
|--------|------|---------|
| `ObTxTableCompactionFilter` | 事务表数据过滤 | `ob_tablet_merge_ctx.h:111` |
| `ObRowScnCompactionFilter` | 基于行 SCN 过滤 | `ob_tablet_merge_ctx.h:114` |
| `ObReorgInfoTableCompactionFilter` | 重组信息过滤 | `ob_tablet_merge_ctx.h:112` |
| `ObMdsFilterInfo` | MDS 数据过滤 | `ob_mds_filter_info.h` |

### 8.2 ObMergeSSTableOp — SSTable 操作分类

`ObMergeSSTableOp`（`ob_basic_tablet_merge_ctx.h:52-70`）定义了每个 SSTable 在合并中的角色：

```cpp
enum ObMergeSSTableOpEnum
{
  SSTABLE_OP_NORMAL,    // 正常参与合并
  SSTABLE_OP_FILTER,    // 过滤（跳过）
  SSTABLE_OP_EMPTY,     // 空 SSTable
  SSTABLE_OP_MAX
};
```

---

## 9. 关键合并策略数据流

### 9.1 Mini → Minor → Medium → Major 完整链条

```
时间线 ─────────────────────────────────────────────────────▶

  Freeze#1    Freeze#2    Freeze#3    Freeze#4    Freeze#5
     │           │           │           │           │
     ▼           ▼           ▼           ▼           ▼
  ┌─────┐    ┌─────┐     ┌─────┐     ┌─────┐     ┌─────┐
  │Mini1│    │Mini2│     │Mini3│     │Mini4│     │Mini5│
  └──┬──┘    └──┬──┘     └──┬──┘     └──┬──┘     └──┬──┘
     │          │           │           │           │
     └──────────┴───────────┘           │           │
              │                    ═════╪═══════    │
              ▼                    Minor Merge     │
        ┌──────────┐                              │
        │  Minor1  │                              │
        └────┬─────┘                              │
             │                                 ═══╪═══════
             │                            ┌───────┴───────┐
             │ ═══════════════════════════│  Minor2       │
             │  Medium Merge              │  (合并 Mini4&5)│
             ▼                            └───────┬───────┘
        ┌────────────┐                            │
        │Inc Major1  │                            │
        │(L2)        │                            │
        └──────┬─────┘                            │
               │                                  │
               ════ Major Merge (合并所有层级) ══════
                                │
                                ▼
                        ┌──────────────┐
                        │ Major SSTable│
                        │ (L3, 全量)   │
                        └──────────────┘
```

### 9.2 Compaction DAG 调度流程

```
ObLS::schedule_minor_merge()
  │
  └── ObTenantTabletScheduler
       │
       └── ObTabletMergeDag 提交到 DAG 引擎
            │
            └── ObCompactionDagRanker::process()
                 │
                 ├── prepare_rank_dags_()
                 │     └── 收集所有待执行的合并 DAG
                 │
                 ├── sort_()
                 │     └── 按优先级排序
                 │
                 └── move_dags_to_ready_dag_list_()
                       └── 转移就绪 DAG 以便调度执行
```

---

## 10. 合并过程中的资源管理

### 10.1 内存管理

合并过程中会分配大量内存用于：

1. **Index Block 缓存**：读取 SSTable 的索引块
2. **Macro Block 读写缓冲区**：每线程的 Macro Block 解码/编码缓冲区
3. **Merge Iterator**：多路合并迭代器
4. **Filter 上下文**：合并过滤器的中间状态

内存预算由 `ObCompactionEstimator` 控制：

```cpp
// ob_compaction_dag_ranker.h:34-41
class ObCompactionEstimator
{
  int estimate_compaction_memory(      // 估算合并所需内存
    const ObCompactionParam &param,
    const int64_t input_data_size,
    int64_t &need_memory);

  int estimate_compaction_batch_size(  // 估算批次大小
    const int64_t avail_memory,
    const int64_t input_data_size,
    int64_t &batch_size);
};
```

### 10.2 写放大控制

OceanBase 通过以下机制控制写放大：

| 机制 | 描述 |
|------|------|
| **合并级别选择** | Macro Block 级合并（粗粒度）vs Micro Block 级合并（精细） |
| **渐进式合并** | `ObProgressiveMergeHelper` 实现分轮次渐进合并 |
| **Compact CO（列存）** | 列存格式下更高效的部分合并策略 |
| **ExecMode 选择** | `EXEC_MODE_LOCAL`（本地）+ `EXEC_MODE_UPLOAD_MINOR`（上传） |

```cpp
// ob_compaction_util.h:148-156
enum ObExecMode : uint8_t {
  EXEC_MODE_LOCAL = 0,                    // 本地私有 Macro Block
  EXEC_MODE_OUTPUT,                       // 正常合并，输出到共享存储
  EXEC_MODE_VALIDATE,                     // 校验 checksum
  EXEC_MODE_LOCAL_WITH_SHARED_BLOCK,      // 本地 + 共享 Block
  EXEC_MODE_UPLOAD_MINOR,                 // 上传本地到共享存储
  EXEC_MODE_MAX
};
```

### 10.3 并行合并

合并支持并行执行，通过 `ObPartitionParallelMergeCtx`（`ob_partition_parallel_merge_ctx.h`）管理：

- 并行度通过 `concurrent_cnt_` 控制
- 任务分片通过 `get_start_task_idx()` 分配
- 多个 Merge DAG 可以同时运行（`max_parallel_dag_cnt_` 控制）

---

## 11. 设计决策

### 11.1 为什么需要 4 层合并？

标准 LSM-Tree（LevelDB/RocksDB）通常只有 2-3 层合并（minor/major 或 Level 0-N）。OceanBase 增加了 **Medium Merge** 作为专门的中间层，原因：

1. **避免 Major Merge 过多**：Major Merge 是全量合并，写放大极大。Medium Merge 只合并增量部分，在不触发全量合并的前提下控制读放大
2. **增量 Major 机制**：Medium Merge 的输出作为 Inc Major SSTable，在查询时可以替代部分 Major SSTable 的范围，减少读放大
3. **Schema 变化响应**：当 Schema 变化时，Medium Merge 可以快速重新编码旧数据而不必等 Major Merge

### 11.2 合并优先级的设计

为什么一个 tablet 的合并比另一个更优先？排序逻辑综合多种因素：

- **Mini Merge**：按 WAL replay interval 排序 — 回放间隔越大，说明数据差异越大，合并收益越高
- **Minor Merge**：按 SSTable 数量 + 占用空间排序 — L0 文件越多，读放大越严重，越需要合并
- **Major Merge**：按 Compaction SCN 排序 — 领先冻结版本越远，越需要追赶

这种设计确保了**公平性**与**效益最大化**之间的平衡。

### 11.3 窗口合并模式

`COMPACTION_WINDOW_MODE` 允许在指定时间窗口内集中执行合并操作，典型场景：

1. **夜间窗口**：低负载时段集中进行 Major Merge
2. **资源控制**：避免合并与在线业务竞争 I/O 资源
3. **定时任务**：配合运维窗口执行合并

### 11.4 合并失败处理

合并过程是异步 DAG 执行的，失败处理机制：

- `ObCompactionDiagnoseMgr::diagnose_failed_report_task()` — 检测并报告失败的合并任务
- `ObScheduleSuspectInfoMgr` — 记录可疑调度信息供诊断
- Tablet 级重试机制 — 合并失败后重新调度

---

## 12. 源码索引

### 核心文件

| 文件路径 | 行数 | 用途 |
|---------|------|------|
| `src/storage/compaction/ob_compaction_util.h` | 219 | `ObMergeType` 枚举、类型判断函数、`ObMergeLevel`、`ObExecMode` |
| `src/storage/compaction/ob_compaction_schedule_util.h` | 156 | `ObBasicMergeScheduler` 全局调度器、调度模式、合并进度 |
| `src/storage/compaction/ob_basic_tablet_merge_ctx.h` | 462 | `ObStaticMergeParam`、`ObBasicTabletMergeCtx` 基类、`ObMergeSSTableOp` |
| `src/storage/compaction/ob_tablet_merge_ctx.h` | 128 | `ObTabletMiniMergeCtx`、`ObTabletExeMergeCtx`、`ObTabletMajorMergeCtx` |
| `src/storage/compaction/ob_compaction_dag_ranker.h` | 187 | DAG 排序引擎、四种合并排名辅助类、内存估计 |
| `src/storage/compaction/ob_compaction_diagnose.h` | 940+ | 合并诊断管理器、诊断状态、可疑信息 |
| `src/storage/compaction/ob_block_op.h` | 59 | Macro/Micro Block 操作策略（NONE/OPEN/REWRITE/FILTER） |
| `src/storage/compaction/ob_medium_compaction_func.h` | 240+ | Medium Compaction 调度函数 |

### 辅助文件

| 文件路径 | 用途 |
|---------|------|
| `ob_partition_merge_iter.h` | 多路合并迭代器 |
| `ob_partition_rows_merger.h` | 行级合并器 |
| `ob_partition_merge_policy.h` | 分区合并策略 |
| `ob_partition_merger.h` | 分区合并器 |
| `ob_sstable_builder.h` | SSTable 构建器 |
| `ob_sstable_merge_history.h` | SSTable 合并历史 |
| `ob_progressive_merge_helper.h` | 渐进式合并辅助 |
| `ob_compaction_memory_context.h` | 合并内存上下文 |
| `ob_compaction_memory_pool.h` | 合并内存池 |
| `ob_compaction_trans_cache.h` | 事务缓存 |
| `ob_uncommit_tx_info.h` | 未提交事务信息 |
| `ob_column_checksum_calculator.h` | 列校验和计算 |
| `ob_compaction_suggestion.h` | 合并建议 |
| `ob_i_compaction_filter.h` | 合并过滤器接口 |
| `ob_mds_filter_info.h` | MDS 过滤器 |
| `ob_partition_merge_progress.h` | 合并进度跟踪 |
| `ob_partition_parallel_merge_ctx.h` | 并行合并上下文 |
| `ob_extra_medium_info.h` | Medium 额外信息 |
| `ob_medium_compaction_info.h` | Medium 合并信息 |
| `ob_window_compaction_utils.h` | 窗口合并工具 |
| `ob_window_loop.h` | 窗口合并循环 |
| `ob_medium_loop.h` | Medium 合并循环 |
| `ob_tenant_tablet_scheduler.h` | 租户 Tablet 调度器 |
| `ob_tenant_freeze_info_mgr.h` | 冻结信息管理 |

### 相关文章关联

| 文章 | 关联内容 |
|------|---------|
| [05] MVCC Compact | 行级版本链压缩 vs SSTable 级合并，粒度不同 |
| [06] Freezer | Mini Merge 是 Freeze 的下游操作 |
| [07] LS Tree | SSTable 层级的理论基础 |
| [08] SSTable 格式 | Merge 过程中 Macro Block 的重新编码 |
| [27] RootServer | RootServer 决定 Major Freeze 时机，触发 Major Merge |

---

## 13. 总结

OceanBase 的 SSTable Merge 策略是 LSM-Tree 体系在大规模分布式数据库场景下的工程实践。4 层合并设计（Mini → Minor → Medium → Major）在标准 LSM-Tree 的基础上增加了 Medium Merge 这一中间层级，有效平衡了读放大与写放大。DAG 引擎驱动的调度架构和优先级排序机制确保了合并操作的公平和高效。

**核心设计特点**：

1. **四层递进**：每条数据从 Memtable 开始，经过多层合并逐步沉降到 Major SSTable
2. **增量优先**：尽可能使用 Medium Merge（增量）替代 Major Merge（全量），降低写放大
3. **DAG 调度**：合并任务封装为 DAG，通过优先级排序实现精细的资源管理
4. **可诊断性**：`ObCompactionDiagnoseMgr` 提供完整的诊断框架，支持运维排障
5. **并行与内存控制**：通过 `ObCompactionEstimator` 精确控制每个合并任务的资源消耗
