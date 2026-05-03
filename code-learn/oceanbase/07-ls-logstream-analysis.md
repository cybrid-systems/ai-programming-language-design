# 07 — LogStream 与 LS Tree — 存储引擎的容器架构

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前面的 6 篇文章从 MVCC 行数据开始逐步上探：Row 结构 → Iterator 迭代 → Write Conflict 冲突管理 → Callback 回调链 → Compact 行级压缩 → Memtable Freeze 冻结。现在来到容器层：**LogStream（LS）**。

如果说前面的 MVCC 层是 **存储引擎的细胞**，那么 LogStream 就是 **组织器官**。

### LogStream 在整个架构中的位置

```
┌─────────────────────────────────────────────────────────┐
│                    SQL Layer                             │
│   SQL解析、计划生成、分布式执行                             │
├─────────────────────────────────────────────────────────┤
│                    Transaction Layer                      │
│   分布式事务、两阶段提交、MVCC 可见性                        │
├─────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────┐   │
│  │              LogStream (ObLS)                     │   │
│  │  数据复制的最小单元 | Paxos 一致性协议 | 日志管理    │   │
│  │                                                    │   │
│  │  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐          │   │
│  │  │Tablet│  │Tablet│  │Tablet│  │Tablet│  ...     │   │
│  │  └──┬───┘  └──┬───┘  └──┬───┘  └──┬───┘          │   │
│  │     │         │         │         │              │   │
│  │  ┌──▼──────────▼──────────▼──────────▼──┐         │   │
│  │  │        LS Tree (ObTabletTableStore)   │         │   │
│  │  │  ┌─────┐ ┌──────┐ ┌───────┐ ┌──────┐│         │   │
│  │  │  │ L0  │ │ L1   │ │ L2    │ │ L3   ││         │   │
│  │  │  │Mini │ │Minor │ │Medium │ │Major ││         │   │
│  │  │  └─────┘ └──────┘ └───────┘ └──────┘│         │   │
│  │  └──────────────────────────────────────┘         │   │
│  └──────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────┤
│                    Storage Layer                         │
│  宏块管理、数据编码、压缩、异步 I/O                          │
└─────────────────────────────────────────────────────────┘
```

### 三个核心概念

| 概念 | 对应类/结构 | 职责 |
|------|-------------|------|
| **LogStream** | `ObLS` | 数据复制和 Paxos 的最小单元，管理一组 Tablet |
| **Tablet** | `ObTablet` | 存储在 LS 上的数据分片，存储引擎的核心数据单元 |
| **LS Tree** | `ObTabletTableStore` | LogStream 内部的 LSM-Tree 结构，管理所有 SSTable 的分层组织 |

**关键洞察**：OceanBase 的 "LS Tree" 并不是一个单独的类名，而是 `ObTabletTableStore` 实际表现出来的架构模式——每个 Tablet 内维护独立的多层 SSTable 集合（major、inc_major、minor、mds），由 ObLS 统一协调 Freeze、Compaction、Checkpoint。

---

## 1. ObLS — LogStream 核心类

### 1.1 ObLS 类结构

```cpp
// ob_ls.h:197 - doom-lsp 确认
class ObLS
{
  // ════════ 生命周期 ════════
  int init();                           // @L253 — 初始化
  int start();                          // @L264 — 启动
  int stop();                           // @L265 — 停止
  int wait();                           // @L266 — 等待完成
  int destroy();                        // @L269 — 销毁
  int offline();                        // @L270 — 下线
  int online();                         // @L271 — 上线

  // ════════ 子服务访问 ════════
  ObTabletService *get_tablet_svr();    // @L288 — Tablet 服务
  ObFreezer *get_freezer();             // @L295 — Freezer 冻结器
  ObCheckpointExecutor *get_checkpoint_executor(); // @L297 — Checkpoint 执行器
  ObDataCheckpoint *get_data_checkpoint();         // @L298 — 数据 Checkpoint
  ObLogHandler *get_log_handler();      // @L305 — 日志处理器
  ObRoleChangeHandler *get_role_change_handler();  // @L308 — 角色切换（Leader/Follower）
  ObGCHandler *get_gc_handler();        // @L310 — GC 处理器
  ObLSMigrationHandler *get_ls_migration_handler(); // @L312 — 迁移处理器
  ObTransferHandler *get_transfer_handler();        // @L314 — 传输处理器

  // ════════ LS 元数据 ════════
  ObLSID get_ls_id();                   // @L289 — LS ID
  int get_ls_role();                    // @L336 — LS 角色（LEADER/FOLLOWER）
  int get_ls_meta(...);                 // @L392 — LS 元数据
  int get_ls_meta_package(...);         // @L390 — LS 元数据包

  // ════════ 冻结接口 ════════
  int logstream_freeze(...);            // @L977 — LS 级冻结
  int tablet_freeze(...);               // @L984 — Tablet 级冻结

  // ════════ 锁管理 ════════
  RWLock meta_rwlock_;                  // @L1216 — 元数据读写锁
};
```

### 1.2 ObLS 成员一览

doom-lsp `doc` 显示的 ObLS 字段（ob_ls.h:104-121 — doom-lsp 确认）：

```
ls_id_                    @L104 — LS 标识符
replica_type_             @L105 — 副本类型
ls_state_                 @L106 — LS 运行状态
migrate_status_           @L107 — 迁移状态
tablet_count_             @L108 — Tablet 计数
weak_read_scn_            @L109 — 弱读 SCN
need_rebuild_             @L110 — 是否需要重建
checkpoint_scn_           @L111 — Checkpoint SCN
checkpoint_lsn_           @L113 — Checkpoint LSN
rebuild_seq_              @L114 — 重建序列号
tablet_change_checkpoint_scn_ @L115 — Tablet 变更 Checkpoint SCN
transfer_scn_             @L116 — 传输 SCN
tx_blocked_               @L117 — 事务是否被阻塞
mv_major_merge_scn_       @L118 — Major Merge MV SCN
mv_publish_scn_           @L119 — 发布 MV SCN
mv_safe_scn_              @L120 — 安全 MV SCN
required_data_disk_size_  @L121 — 所需磁盘空间
```

### 1.3 LS 子服务模型

ObLS 采用了**委托模式（Delegate Pattern）**，大量方法通过 `DELEGATE_WITH_RET` 宏委托给内部子服务处理。这些子服务在 `ob_ls.h:1121-1210` 中声明为成员字段（doom-lsp 确认）：

```cpp
// ob_ls.h - 子服务字段（doom-lsp 确认）
ls_tablet_svr_;               // @L1121 — Tablet 服务（管理所有 Tablet）
log_handler_;                 // @L1124 — 日志处理器（Paxos 日志）
role_change_handler_;         // @L1125 — 角色切换
ls_tx_svr_;                   // @L1127 — 事务服务
replay_handler_;              // @L1130 — 回放处理器
restore_handler_;             // @L1133 — 恢复处理器
restore_role_change_handler_; // @L1134 — 恢复时角色切换
checkpoint_executor_;         // @L1137 — Checkpoint 执行器
ls_freezer_;                  // @L1139 — Freezer
gc_handler_;                  // @L1141 — GC 处理器
ls_restore_handler_;          // @L1151 — LS 恢复处理器
tx_table_;                    // @L1152 — 事务表
data_checkpoint_;             // @L1153 — 数据 Checkpoint
lock_table_;                  // @L1155 — 锁表
```

### 1.4 ObLS 生命周期

```
   init()
     │
     ▼
   start()
     │
     ▼
  ┌──────────────┐     offline()     ┌───────────────┐
  │  LS_RUNNING   │ ──────────────→  │  LS_OFFLINING  │
  │  (正常服务)    │                  │  (正在下线)     │
  └──────┬───────┘                  └───────┬───────┘
         │                                   │
         │ online()                          │ post_offline()
         │                                   ▼
         │                         ┌───────────────┐
         │                         │  LS_OFFLINED   │
         │                         │  (已下线)       │
         │                         └───────┬───────┘
         │                                   │
         │                                   │ stop()
         │                                   ▼
         │                         ┌───────────────┐
         └─────────────────────────│  LS_STOPPED    │
                                   │  (已停止)       │
                                   └───────────────┘
```

`ObLSRunningState` 的完整状态枚举（ob_ls_state.h:58-64 — doom-lsp 确认）：

```cpp
// ob_ls_state.h:58-64 - doom-lsp 确认
enum State {
  INVALID      = 0,
  LS_INIT      = 1,  // 刚初始化
  LS_RUNNING   = 2,  // 正常运行
  LS_OFFLINING = 3,  // 正在下线
  LS_OFFLINED  = 4,  // 已下线
  LS_STOPPED   = 5,  // 已停止
  MAX
};
```

**Ops 操作状态机**（`ObLSRunningState::Ops`）控制状态转换（ob_ls_state.h:93-99 — doom-lsp 确认）：

```
CREATE_FINISH → ONLINE → PRE_OFFLINE → POST_OFFLINE → STOP
```

### 1.5 LS 元数据和持久化状态

`ObLSMeta`（ob_ls_meta.h:50 — doom-lsp 确认）是 LS 的持久化元数据，包含：

```
ObLSMeta 主要方法（doom-lsp 确认）：
  init()                          @L61  — 初始化
  set_start_work_state()          @L69  — 开始工作
  set_start_ha_state()            @L70  — 开始 HA
  set_finish_ha_state()           @L71  — 完成 HA
  set_remove_state()              @L72  — 删除状态
  get_persistent_state()          @L73  — 获取持久化状态
  set_clog_checkpoint()           @L77  — 设置日志 Checkpoint
  set_migration_status()          @L81  — 设置迁移状态
  set_gc_state()                  @L84  — 设置 GC 状态
  set_restore_status()            @L88  — 设置恢复状态
```

`ObLSPersistentState`（ob_ls_state.h:144 — doom-lsp 确认）使用基于操作的持久化状态机：

```
start_work()  → 正常提供读写服务的开始
start_ha()    → 开始高可用操作（如从其他副本拉取数据）
finish_ha()   → HA 完成
remove()      → LS 被删除
```

---

## 2. ObTablet — 数据分片

### 2.1 ObTablet 核心结构

每个 LogStream 管理 0~N 个 Tablet。Tablet 是 OceanBase 分布式存储的核心数据单元。

```cpp
// ob_tablet.h:219 - doom-lsp 确认
class ObTablet
{
  // ════════ 核心数据 ════════
  ObTabletMeta tablet_meta_;          // 元数据（Tablet ID、LS ID、SCN 范围等）
  ObTabletTableStore table_store_;    // LS Tree 的核心——SSTable 分层管理

  // ════════ 关键操作 ════════
  int init_for_first_time_creation(...);  // @L290 — 首次创建
  int insert_row(...);                     // @L508 — 插入行
  int update_row(...);                     // @L515 — 更新行
  int lock_row(...);                       // @L531 — 行锁

  int get_all_tables(...);                 // @L550 — 获取所有表
  int get_all_sstables(...);               // @L551 — 获取所有 SSTable
  int get_memtables(...);                  // @L552 — 获取所有 Memtable
  int get_active_memtable(...);            // @L560 — 获取活跃 Memtable（可写）
  int get_mini_minor_sstables(...);        // @L645 — 获取 Mini/Minor SSTable
  int get_major_sstables(...);             // (通过 table_store_)
  int get_ddl_sstables(...);              // @L637 — 获取 DDL SSTable
};
```

### 2.2 ObTabletMeta

Tablet 元数据定义在 `ObTabletMeta` 中，主要包含：

```cpp
// ObTabletMeta 主要字段（doom-lsp 确认）
ObTabletID tablet_id_;       // Tablet ID
ObLSID ls_id_;               // 所属 LS ID
share::SCN snapshot_version_; // 快照版本
share::SCN multi_version_start_; // 多版本可见性起点
share::SCN clog_checkpoint_scn_; // 日志 Checkpoint SCN
int64_t data_version_;        // 数据版本
int64_t schema_version_;     // Schema 版本
int64_t row_count_;          // 行数
int64_t data_size_;          // 数据大小
int64_t occupy_size_;        // 占用空间
```

### 2.3 Tablet 的数据组织

每个 Tablet 内部通过 `ObTabletTableStore` 组织多个数据版本：

```
ObTablet
  │
  ├── tablet_meta_ — 不可变元数据
  │
  ├── table_store_ (ObTabletTableStore)
  │     ├── major_tables_       — Major SSTable（全量合并结果，一个 Tablet 通常一个）
  │     ├── inc_major_tables_   — Inc Major SSTable（增量合并结果）
  │     ├── minor_tables_       — Minor SSTable（Mini 合并后的分层 SSTable）
  │     ├── mds_sstables_       — MDS（元数据服务）SSTable
  │     ├── ddl_sstables_       — DDL 操作产生的临时 SSTable
  │     ├── inc_major_ddl_sstables_ — DDL 增量 Major SSTable
  │     └── memtables_          — 活跃和冻结的内存表
  │
  └── (Memtable Manager) — 管理 memtable 生命周期
```

> `ob_tablet_table_store.h:561-572`（doom-lsp 确认）显示了所有 SSTable 容器字段。

---

## 3. LS Tree — SSTable 分层管理

### 3.1 分层的本质

OceanBase 没有单独的 "LS Tree" 类，但 `ObTabletTableStore` 实际实现了经过优化的 LSM-Tree 分层架构：

```
   写入路径                  读取路径
      │                        ▲
      ▼                        │
┌────────────────────────────────────────────────────────┐
│  Memtable（活跃）  ← 所有写入先到这里                     │
├────────────────────────────────────────────────────────┤
│  Memtable（冻结）  → 冻结后变为只读                        │
├────────────────────────────────────────────────────────┤
│                    LS Tree 层级                          │
│                                                        │
│  L0: Mini SSTable  ──── Mini Merge ────┐               │
│    (冻结 Memtable     (合并多个 Mini)     │               │
│     直接生成的 SST)                       │               │
│                                          │               │
│  L1: Minor SSTable  ◄───────────────────┘               │
│    (多个 Mini+Minor 的增量合并)            │               │
│                                          │               │
│  L2: Medium SSTable ◄── 部分分区的增量合并 │               │
│    (指部分 Tablet 分区)                    │               │
│                                          │               │
│  L3: Major SSTable  ◄── Major Merge ────┘               │
│    (全库全量合并，每个 Tablet 最多一个)                    │
└────────────────────────────────────────────────────────┘
```

### 3.2 SSTable 类型对应关系

OceanBase 的 SSTable 类型与 LSM-Tree 层级的关系：

| LS Tree 层级 | SSTable 类型 | 对应变量 | 生成方式 |
|-------------|-------------|---------|---------|
| L0（最顶层） | Mini SSTable | `minor_tables_` | 冻结 Memtable 直接 flush 生成 |
| L1 | Minor SSTable | `minor_tables_` | 多个 Mini/Minor 增量合并 |
| L2 | Medium SSTable | `inc_major_tables_` | 部分分区合并（Medium Compaction） |
| L3（最底层） | Major SSTable | `major_tables_` | 全量合并（Major Freeze 结果） |

**注意**：OceanBase 的实现中，`minor_tables_` 同时承载 L0 和 L1 的数据，它们通过 SCN 范围区分。`inc_major_tables_` 对应增量 Major 级别，`major_tables_` 对应全量 Major。

### 3.3 ObSSTable 类

```cpp
// ob_sstable.h:124 - doom-lsp 确认
class ObSSTable
{
  int init(...);     // @L136 — 初始化
  int scan(...);     // @L151 — 扫描数据
  int inc_ref();     // @L132 — 增加引用计数
  int dec_ref();     // @L133 — 减少引用计数
};
```

每个 SSTable 关联 `ObSSTableMeta`（ob_sstable.h:54 — doom-lsp 确认），包含：

```
ObSSTableMeta 主要字段（doom-lsp 确认）：
  version_                     @L96 — 版本号
  has_multi_version_row_       @L97 — 是否包含多版本行
  data_macro_block_count_      @L102 — 数据宏块数
  total_macro_block_count_     @L105 — 总宏块数
  row_count_                   @L107 — 行数
  occupy_size_                 @L108 — 占用空间
  max_merged_trans_version_    @L109 — 最大合并事务版本
  upper_trans_version_         @L113 — 上界事务版本
  filled_tx_scn_               @L114 — 已填充事务 SCN
  contain_uncommitted_row_     @L115 — 是否包含未提交行
  rec_scn_                     @L116 — 日志回放 SCN
  min_merged_trans_version_    @L118 — 最小合并事务版本
```

### 3.4 LS Tree 完整数据流

#### 写入路径

```
SQL INSERT / UPDATE / DELETE
         │
         ▼
    ObLS::get_tablet()  → 获取目标 Tablet
         │
         ▼
    ObTablet::insert_row() / update_row()
         │
         ▼
    活跃 Memtable（ACTIVE）
    (通过 ObTabletMemtableMgr 管理)
         │
         ├── 内存阈值触发
         │       │
         │       ▼
         │    ObFreezer::logstream_freeze()
         │       │
         │       ├── freeze_clock + 1
         │       ├── freeze_snapshot_version = weak_read_scn
         │       └── submit_checkpoint_task()
         │
         ▼
    冻结 Memtable（FREEZING → READY_FOR_FLUSH）
         │
         ▼ flush
    Mini SSTable (L0)
    → 写入 minor_tables_
         │
         ▼ (Mini Merge)
    Minor SSTable (L1)
    → 替换 minor_tables_ 中的多个 Mini
         │
         ▼ (Minor Compaction 继续)
    Medium SSTable (L2)
    → 写入 inc_major_tables_
         │
         ▼ (Major Compaction)
    Major SSTable (L3)
    → 写入 major_tables_
```

#### 读取路径

```
SQL SELECT
  │
  ▼
ObLS::get_tablet_svr() → TabletService 路由到目标 Tablet
  │
  ▼
ObTabletTableStore::get_read_tables()
  │
  ├── 收集所有可读的 Memtable（活跃 + 冻结）
  ├── 收集所有 Mini/Minor SSTable（minor_tables_）
  ├── 收集所有 Inc Major SSTable（inc_major_tables_）
  └── 收集 Major SSTable（major_tables_）
  │
  ▼
ObTabletTableIterator → 多路归并
  │
  ├── 每棵树的 Iterator 按 rowkey 排序
  ├── 通过 Merge（归并）合并结果
  └── MVCC 可见性过滤（snapshot_version）
  │
  ▼
结果行返回给用户
```

---

## 4. ObFreezer — LS 级冻结协调

### 4.1 Freezer 与 LS 的关系

`ObFreezer` 是 `ObLS` 的一个子服务（`ls_freezer_` 字段，ob_ls.h:1139 — doom-lsp 确认），负责协调 LS 范围内所有 Tablet 的冻结。

```cpp
// ob_freezer.h:147-270 - doom-lsp 确认
class ObFreezer
{
  uint32_t freeze_flag_;              // @L253 — 冻结标志 + freeze_clock
  share::SCN freeze_snapshot_version_; // @L256 — 冻结快照版本
  share::SCN max_decided_scn_;        // @L259 — 最大已决定日志 SCN

  ObLS *ls_;                          // @L261 — 所属 LS

  int logstream_freeze(...);          // @L153 — LS 级冻结
  int tablet_freeze(...);             // @L155 — Tablet 级冻结
};
```

### 4.2 Freeze 到 Mini SSTable 的连接

上一篇文章（06）详细分析了 freeze 机制。这里补充 LS Tree 上下文中的连接点：

```
ObLS::logstream_freeze()        ← LS 的冻结调度入口
  │
  ▼
ObFreezer::logstream_freeze()   ← 递增 freeze_clock，记录 snapshot_version
  │
  ├── submit_checkpoint_task()  ← 触发 DataCheckpoint
  │     │
  │     ▼
  │   ObDataCheckpoint::ls_freeze()
  │     │
  │     ▼
  │   transfer Memtable from frozen_list to prepare_list
  │
  ├── 冻结 Memtable 等待 flush 条件
  │     └── write_ref_cnt == 0 && unsubmitted_cnt == 0
  │
  ▼
ObMemtableCompactWriter 编码 → Mini SSTable
  │
  ▼
ObTabletTableStore::replace_sstables()  → 写入 minor_tables_
```

### 4.3 ObTabletTableStore 提供的关键方法

`ObTabletTableStore`（ob_tablet_table_store.h:44 — doom-lsp 确认）负责管理 Tablet 中所有 SSTable，其在 freeze 和 compaction 中的作用方法：

```cpp
class ObTabletTableStore {
  // 读相关
  int get_read_tables(MemtableArray &, SSTableArray &);    // @L136 — 获取读表集合
  int get_mini_minor_sstables(...);                          // @L157 — 获取 Mini/Minor SSTable
  int get_major_sstables(...);                                // @L142 — 获取 Major SSTable
  int get_all_sstable(...);                                   // @L141 — 获取所有 SSTable

  // 写相关
  int replace_sstables(...);                                  // @L452 — 替换 SSTable（compaction 结果）
  int update_memtables(...);                                  // @L145 — 更新 Memtable 列表
  int build_major_tables(...);                                // @L224 — 构建 Major 表
  int build_minor_tables(...);                                // @L234 — 构建 Minor 表

  // 内部数据（doom-lsp 确认）
  ObSSTableArray major_tables_;           // @L562 — Major SSTable 数组
  ObSSTableArray inc_major_tables_;       // @L563 — Inc Major SSTable 数组
  ObSSTableArray minor_tables_;           // @L564 — Minor SSTable 数组（含 Mini）
  ObIMemtableMgr *memtables_;             // @L569 — Memtable 管理器指针
};
```

---

## 5. ASCII 架构图

### 5.1 LS 内部架构

```
┌─────────────────────────────────────────────────────────────────┐
│                         ObLS                                     │
│                                                                   │
│  ┌─────────────────┐    ┌────────────────────┐                   │
│  │  Log Handler     │    │  Role Change        │                   │
│  │  (Paxos 日志)     │    │  Handler            │                   │
│  └─────────────────┘    └────────────────────┘                   │
│                                                                   │
│  ┌─────────────────┐    ┌────────────────────┐                   │
│  │  ObTabletService │    │  ObFreezer          │                   │
│  │                  │    │  (冻结协调器)        │                   │
│  └─────────────────┘    └────────────────────┘                   │
│         │                         │                               │
│         ▼                         ▼                               │
│  ┌────────────────────────────────────────────────────────┐      │
│  │                  Tablet 集合                             │      │
│  │                                                         │      │
│  │  ┌──────────────────────────────────────────┐          │      │
│  │  │  Tablet-1 (ObTablet)                     │          │      │
│  │  │  ┌────────────┐ ┌──────────────────────┐ │          │      │
│  │  │  │tablet_meta_│ │  ObTabletTableStore  │ │          │      │
│  │  │  └────────────┘ │                      │ │          │      │
│  │  │                 │  ┌───────────────┐   │ │          │      │
│  │  │                 │  │major_tables_  │───│── L3(Major)│      │
│  │  │                 │  ├───────────────┤   │ │          │      │
│  │  │                 │  │inc_major_     │───│── L2(Med)  │      │
│  │  │                 │  │   tables_     │   │ │          │      │
│  │  │                 │  ├───────────────┤   │ │          │      │
│  │  │                 │  │minor_tables_  │───│── L1(Minor)│      │
│  │  │                 │  ├───────────────┤   │ │          │      │
│  │  │                 │  │memtables_     │───│── L0(Mem)  │      │
│  │  │                 │  └───────────────┘   │ │          │      │
│  │  │                 └──────────────────────┘ │          │      │
│  │  └──────────────────────────────────────────┘          │      │
│  │                                                         │      │
│  │  ┌──────────────────────────────────────────┐          │      │
│  │  │  Tablet-2 (ObTablet)                     │          │      │
│  │  │  ... 同 Tablet-1                          │          │      │
│  │  └──────────────────────────────────────────┘          │      │
│  └────────────────────────────────────────────────────────┘      │
│                                                                   │
│  ┌─────────────────┐    ┌────────────────────┐                   │
│  │  GC Handler      │    │  Migration          │                   │
│  │  (资源回收)       │    │  Handler            │                   │
│  └─────────────────┘    └────────────────────┘                   │
│                                                                   │
│  ┌─────────────────┐    ┌────────────────────┐                   │
│  │  Transfer        │    │  Checkpoint         │                   │
│  │  Handler         │    │  Executor           │                   │
│  └─────────────────┘    └────────────────────┘                   │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 读取路径详细图

```
请求: SELECT * FROM t1 WHERE id = 42
         │
         ▼
ObLS::get_tablet_svr() → route → Tablet-1
         │
         ▼
ObTablet::get_all_tables()
         │
         ▼
ObTabletTableStore::get_read_tables()
         │
         ├───────────────────┬───────────────────┬─────────────────┐
         ▼                   ▼                   ▼                 ▼
    Memtable Array      minor_tables_     inc_major_tables_   major_tables_
    (L0: 活跃+冻结)     (L0/L1: Mini/Minor)  (L2: Medium)       (L3: Major)
         │                   │                   │                 │
         ▼                   ▼                   ▼                 ▼
    ObMemtableIterator  ObSSTableIterator  ObSSTableIterator   ObSSTableIterator
         │                   │                   │                 │
         └───────────────────┴───────────────────┴─────────────────┘
                              │
                              ▼
                      Merge 归并（按 rowkey 排序）
                              │
                              ▼
                    MVCC 可见性过滤
                 (检查 snapshot_version 与
                  trans_version 的关系)
                              │
                              ▼
                          结果行
```

### 5.3 Compaction 分层合并

```
        L0: Mini SSTables（多个）
          ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
          │Mini-1│ │Mini-2│ │Mini-3│ │...   │
          └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘
             │        │        │        │
             └────────┴───┬────┴────────┘
                          │ Mini Merge（合并多个 Mini，删除重复）
                          ▼
        L1: Minor SSTable
          ┌──────────────┐  ┌──────────────┐
          │  Minor-1     │  │  Minor-2     │ ← 与已有 Minor 再次合并
          └──────┬───────┘  └──────┬───────┘
                 │                 │
                 └────────┬────────┘
                          │ Minor Compaction（持续增量合并）
                          ▼
        L2: Medium SSTable (inc_major_tables_)
          ┌──────────────────────────────┐
          │  Medium SSTable (部分分区)    │
          └──────────────┬───────────────┘
                         │
                         │ Major Compaction（全量合并，全库范围）
                         ▼
        L3: Major SSTable (major_tables_)
          ┌──────────────────────────────┐
          │  Major SSTable (全量数据)      │
          │  tablet 级别的完整快照         │
          └──────────────────────────────┘
```

---

## 6. 与前面文章的关联

### 6.1 01-MVCC Row（ObMvccRow）

MVCC 行数据存储在 Memtable 中（活跃或冻结），是 LS Tree 最小数据单元。`ObTablet::insert_row()` 写入到当前活跃 Memtable，由 Memtable 中的 `ObMvccRow` 组织多版本。

### 6.2 02-MVCC Iterator（ObMvccIterator）

`ObTabletTableStore::get_read_tables()` 收集所有级别的数据源后，读取路径通过 `ObTabletTableIterator` 多路归并，最终在行级别使用 `ObMvccIterator` 进行 MVCC 版本过滤。

### 6.3 03-Write Conflict（ObTransCallbackList）

写入冲突检查（WriteConflict）在 `ObITabletMemtable::inc_write_ref()` / `dec_write_ref()` 的保护下进行，这与 `ObFreezer::ready_for_flush_()` 等待 `write_ref_cnt == 0` 的逻辑直接相关——冻结需要等待所有正在进行的写操作完成。

### 6.4 04-Callback（ObTxCallback）

回调链的提交与 LS Freeze 是两个异步流程：
- 回调提交：事务日志写入 Paxos 后触发 `ObITransCallback::before_append_cb()`
- LS Freeze：通过 `unsubmitted_cnt` 等待所有回调提交完成才允许 flush

### 6.5 05-Compact（ObMvccRow::mds_compact）

第 05 篇分析的行级 Compact（MVCC 行的垃圾回收）与 LS Tree 的 Compaction 不同：
- **行级 Compact**：合并同一行内的多个 MVCC 版本，不涉及 SSTable
- **LS Tree Compaction**：将多个 Mini/Minor SSTable 合并为更高层的 SSTable

### 6.6 06-Freeze

Freeze 是 L0 到 L1 的桥梁：
- `ObFreezer::logstream_freeze()` 触发冻结
- 冻结的 Memtable 通过 `ObMemtableCompactWriter` 编码为 Mini SSTable
- Mini SSTable 通过 `ObTabletTableStore::replace_sstables()` 进入 `minor_tables_`

---

## 7. 设计决策分析

### 7.1 为什么 LogStream 是复制单元？

ObLS 是 Paxos 一致性协议的最小应用单元。每个 LogStream 拥有独立的：
- **Paxos 副本组**：多数派选举 Leader、日志复制
- **日志流**：`log_handler_` 管理独立的 Paxos 日志流
- **角色切换**：`role_change_handler_` 处理 Leader/Follower 切换

**设计选择**：将分布式一致性范围限定在 LogStream 级别，而非全局级别。

**优点**：

1. **故障隔离**：一个 LS 的主切换不影响其他 LS
2. **负载均衡**：不同 LS 的 Leader 可以分布在不同的 OBServer 上
3. **并行恢复**：多个 LS 可以并行恢复数据
4. **弹性伸缩**：Tablet 可以在 LS 之间迁移（通过 Transfer Handler）

```cpp
// ob_ls.h:336 - doom-lsp 确认
// get_ls_role() 返回当前 LS 的角色（LEADER / FOLLOWER）
int get_ls_role();
// role_change_handler_ 负责在切换时暂停/恢复读写
ObRoleChangeHandler *get_role_change_handler();
```

对比其他系统：

| 系统 | 复制单元 | 一致性协议 |
|------|---------|-----------|
| OceanBase | LogStream（多个 Tablet） | Paxos |
| CockroachDB | Range（单个 Raft 组） | Raft |
| TiKV | Region（单个 Raft 组） | Raft |
| Spanner | Tablet（单个 Paxos 组） | Paxos |

OceanBase 的 LogStream 可以包含多个 Tablet，减少 Paxos 组数量，降低 Leader 选举和日志复制的开销。

### 7.2 为什么 LS Tree 不是全局共享的？

每个 Tablet 维护独立的 `ObTabletTableStore`（即 LS Tree），而不是 LS 全局共享一个树：

```
LS → Tablet-1 → ObTabletTableStore（独立）
   → Tablet-2 → ObTabletTableStore（独立）
   → Tablet-3 → ObTabletTableStore（独立）
```

**设计选择**：每个 Tablet 独立管理自己的 SSTable 分层。

**原因**：

1. **分区独立性**：Tablet 是数据分区的最小单元，compaction 范围在 Tablet 内更清晰
2. **粒度控制**：不同的 Tablet 可以有不同的合并策略（大表频繁合并，小表不合并）
3. **故障恢复**：单个 Tablet 损坏不会影响其他 Tablet 的 LS Tree
4. **并行 Compaction**：不同 Tablet 的 compaction 可以并行执行

### 7.3 为什么有四种 SSTable 层级？

| 层级 | 数据量 | 合并频率 | 合并代价 | 存在的 SSTable 数量 |
|------|--------|---------|---------|-------------------|
| Mini (L0) | 小 | 高（每次 freeze） | 低 | 多个（取决于 freeze 频率） |
| Minor (L1) | 中 | 中 | 中 | 多个 |
| Medium (L2) | 中 | 较低 | 较高 | 多个或按需 |
| Major (L3) | 大 | 低（每日级别） | 最高 | 通常 1 个 |

**设计权衡**：

OceanBase 的 4 层设计是为了平衡读写放大：

- **读放大**：读操作需要检查所有层级。层级越多，读放大越大。但 Major SSTable 通常覆盖 99%+ 的数据，所以实际读放大可控。
- **写放大**：每次写入经过所有层级的合并。层级越多，写放大越大。但通过推迟 Major Compaction 到低频率，写放大主要由 Mini/Minor 合并且承担。
- **空间放大**：多个 SSTable 存储重复数据。L0/L1 的合并越快释放重复空间。

典型配置：
- **LS Freeze**：每 10~30 秒或内存阈值触发一次
- **Minor Compaction**：Mini 数量超过阈值自动触发
- **Medium Compaction**：按需或定时触发
- **Major Compaction**：每日凌晨或低峰期触发（可配置）

### 7.4 为什么 LS 需要锁定机制？

ObLS 使用 `RWLock meta_rwlock_`（ob_ls.h:1216 — doom-lsp 确认）保护元数据访问，同时提供 `RDLockGuard` 和 `WRLockGuard`（ob_ls.h:222-246）确保并发安全：

```cpp
// ob_ls.h:222-246 - doom-lsp 确认
class RDLockGuard {
  // @L226 - @L232
  RWLock &lock_;
  int ret_;
  int64_t start_ts_;
};

class WRLockGuard {
  // @L240 - @L246
  RWLock &lock_;
  int ret_;
  int64_t start_ts_;
};
```

**设计选择**：读写锁分离。

- `RDLockGuard`：读操作获取共享锁，可以并发读取 LS 元数据
- `WRLockGuard`：写操作获取排他锁，阻塞其他读写

这种设计在 LS 在线服务期间大量读取的路径上提供高并发，而写锁仅在 Tablet 创建/删除/迁移等元数据变更时短暂持有。

### 7.5 ObLS 的委托模式解析

ObLS 大量使用 `DELEGATE_WITH_RET` 和 `CONST_DELEGATE_WITH_RET` 宏（ob_ls.h:507-510 — doom-lsp 确认）将方法调用委托给内部子服务：

```
DELEGATE_WITH_RET(get_tx_svr, ...)    → 委托给 ls_tx_svr_
DELEGATE_WITH_RET(get_tablet, ...)    → 委托给 ls_tablet_svr_
DELEGATE_WITH_RET(get_ls_id, ...)     → 直接返回成员
```

**优点**：

1. **关注点分离**：LS 是门面（Facade），各个子服务是各自的职责
2. **可测试性**：每个子服务可以独立测试
3. **灵活性**：子服务可以在不同的 LS 实现中共用

---

## 8. 源码索引

### `ob_ls.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `class ObLS` | L197 | LS 核心类声明 |
| `ObLSVTInfo` | L102 | LS 可见性信息结构 |
| `DiagnoseInfo` | L141 | LS 诊断信息 |
| `ObLSInnerTabletIDIter` | L210 | LS 内部 Tablet ID 迭代器 |
| `RDLockGuard` | L222 | 读锁守卫 |
| `WRLockGuard` | L236 | 写锁守卫 |
| `ObLS::init()` | L253 | 初始化 |
| `ObLS::start()` | L264 | 启动 |
| `ObLS::stop()` | L265 | 停止 |
| `ObLS::offline()` | L270 | 下线 |
| `ObLS::online()` | L271 | 上线 |
| `ObLS::get_tablet_svr()` | L288 | 获取 Tablet 服务 |
| `ObLS::get_freezer()` | L295 | 获取 Freezer |
| `ObLS::get_ls_role()` | L336 | 获取 LS 角色 |
| `ObLS::logstream_freeze()` | L977 | LS 级冻结 |
| `ObLS::tablet_freeze()` | L984 | Tablet 级冻结 |
| `ls_tablet_svr_` | L1121 | Tablet 服务（子服务） |
| `log_handler_` | L1124 | 日志处理器 |
| `ls_freezer_` | L1139 | Freezer（冻结器） |
| `data_checkpoint_` | L1153 | 数据 Checkpoint |
| `ls_migration_handler_` | L1168 | 迁移处理器 |
| `transfer_handler_` | L1210 | 传输处理器 |
| `meta_rwlock_` | L1216 | 元数据读写锁 |

### `ob_ls_meta.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `enum ObLSCreateType` | L41 | LS 创建类型（NORMAL/RESTORE/MIGRATE/CLONE） |
| `class ObLSMeta` | L50 | LS 元数据类 |
| `init()` | L61 | 初始化 |
| `set_start_work_state()` | L69 | 开始工作状态 |
| `set_finish_ha_state()` | L71 | 完成 HA 状态 |
| `set_clog_checkpoint()` | L77 | 设置日志 Checkpoint |
| `inc_update_transfer_scn()` | L103 | 递增传输 SCN |

### `ob_ls_state.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `class ObLSRunningState` | L28 | LS 运行状态 |
| `enum State` | L57 | 状态枚举（INVALID/LS_INIT/LS_RUNNING/LS_OFFLINING/LS_OFFLINED/LS_STOPPED） |
| `enum Ops` | L92 | 操作枚举（CREATE_FINISH/ONLINE/PRE_OFFLINE/POST_OFFLINE/STOP） |
| `class StateHelper` | L126 | 状态帮助类 |
| `class ObLSPersistentState` | L144 | 持久化状态 |

### `ob_tablet.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `enum ObMajorStoreType` | L118 | 存储类型枚举 |
| `class ObTableStoreCache` | L115 | 表存储缓存 |
| `class ObSSTableTxScnMeta` | L200 | SSTable 事务 SCN 元数据 |
| `class ObTablet` | L219 | Tablet 核心类 |
| `init_for_first_time_creation()` | L290 | 首次创建初始化 |
| `init_for_merge()` | L308 | 合并初始化 |
| `insert_row()` | L508 | 插入行 |
| `update_row()` | L515 | 更新行 |
| `lock_row()` | L531 | 锁定行 |
| `get_all_tables()` | L550 | 获取所有表 |
| `get_all_sstables()` | L551 | 获取所有 SSTable |
| `get_memtables()` | L552 | 获取 Memtable |
| `get_active_memtable()` | L560 | 获取活跃 Memtable |
| `get_mini_minor_sstables()` | L645 | 获取 Mini/Minor SSTable |
| `get_tablet_meta()` | L690 | 获取 Tablet 元数据 |

### `ob_tablet_table_store.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `class ObTabletTableStore` | L44 | Tablet 表存储（LS Tree 核心） |
| `get_read_tables()` | L136 | 获取读表集合 |
| `get_all_sstable()` | L141 | 获取所有 SSTable |
| `get_major_sstables()` | L142 | 获取 Major SSTable |
| `get_mini_minor_sstables()` | L157 | 获取 Mini/Minor SSTable |
| `replace_sstables()` | L452 | 替换 SSTable |
| `build_major_tables()` | L224 | 构建 Major 表 |
| `build_minor_tables()` | L234 | 构建 Minor 表 |
| `calculate_read_tables()` | L188 | 计算读表范围 |
| `major_tables_` | L562 | Major SSTable 数组 |
| `inc_major_tables_` | L563 | Inc Major SSTable 数组 |
| `minor_tables_` | L564 | Minor SSTable 数组 |
| `memtables_` | L569 | Memtable 管理器指针 |

### `ob_sstable.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `struct ObSSTableMetaHandle` | L43 | SSTable 元数据句柄 |
| `struct ObSSTableMetaCache` | L67 | SSTable 元数据缓存 |
| `struct ObSSTable` | L124 | SSTable 核心结构 |
| `init()` | L136 | 初始化 |
| `scan()` | L151 | 扫描数据 |

### `ob_freezer.h`
| 符号 | 行号 | 说明 |
|------|------|------|
| `class ObFreezer` | L147 | Freezer 冻结协调器 |
| `get_freeze_clock()` | L230 | 获取冻结时钟 |
| `freeze_flag_` | L253 | 冻结标志 |
| `logstream_freeze()` | L153 | LS 级冻结 |

---

## 9. 总结

### LS Tree 在 OceanBase 存储架构中的位置

```
┌──────────────────────────────────────────────────────────┐
│  SQL + 分布式事务层                                        │
├──────────────────────────────────────────────────────────┤
│  LogStream 层（ObLS）                                      │
│  └─ 一 Paxos 复制组，管理 N 个 Tablet                       │
│                                                           │
│  Tablet 层（ObTablet）                                     │
│  └─ 数据分片，拥有独立元数据和 Schema                         │
│                                                           │
│  LS Tree 层（ObTabletTableStore）                           │
│  └─ L3: Major → L2: Medium → L1: Minor → L0: Mini → Mem  │
│                                                           │
│  Memtable 层（ObMemtable）                                  │
│  └─ 多版本行（ObMvccRow）→ Iterator（ObMvccIterator）       │
│                                                           │
│  SSTable 层（ObSSTable）                                    │
│  └─ 宏块（Macro Block）→ 微块（Micro Block）→ 编码数据       │
└──────────────────────────────────────────────────────────┘
```

### 核心架构决策

1. **LogStream 作为复制单元**：Paxos 一致性域在 LS 级别，而非全局或 Tablet 级别
2. **每个 Tablet 独立 LS Tree**：分区独立的 Compaction、GC、Checkpoint
3. **4 层 LSM-Tree**：Mini/Minor/Medium/Major 分层平衡读写放大
4. **Freeze 作为 L0 入口**：冻结是内存数据到持久化 SSTable 的关键桥梁
5. **委托模式**：ObLS 通过 `DELEGATE_WITH_RET` 委托给子服务，关注点分离

---

*分析工具：doom-lsp（clangd LSP 18.x） | 分析日期：2026-05-03 | 代码仓库：OceanBase CE*
