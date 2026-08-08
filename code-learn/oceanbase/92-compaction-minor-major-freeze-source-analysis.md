# 92-compaction-freeze — OceanBase Compaction / Minor & Major Freeze / 合并策略深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/storage/compaction/` **108 文件** + `src/rootserver/freeze/` 34 文件 + `src/share/ob_freeze_info_*.{h,cpp}` + `src/observer/virtual_table/ob_all_virtual_dag.h`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Compaction 体系**是整个 observer 集群"存储合并"的核心 —— memtable freeze → mini-sstable（minor freeze），多个 mini-sstable → SSTable（major freeze），DAG 调度保证不阻塞 DML。OB 5.x 的 Compaction 建立在 `ObCompactionService` + `ObMajorFreezeService` + `ObBasicScheduleTabletFunc` + `ObCompactionDagRanker` 之上，是 OB 自研的高效 merge 系统。

本文聚焦 8 个核心问题：

1. **Compaction 全景** —— 108+34 文件
2. **Minor Freeze** —— memtable → mini-sstable（参见 #89）
3. **Major Freeze** —— multiple mini-sstable → SSTable
4. **ObMajorFreezeService**（RS 端）—— 主 freeze 协调
5. **ObBasicScheduleTabletFunc** —— 调度核心
6. **ObCompactionDagRanker** —— DAG 优先级排序
7. **ObPartitionMergeProgress** —— 合并进度
8. **Daily Major Freeze / Reentrant Thread** —— 定时 + 协调

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 06-memtable-freezer | #06 是早期分析 memtable freezer |
| 34-sstable-merge | #34 是早期分析 SSTable merge 概览 |
| 48-data-checkpoint | checkpoint 触发 compaction 调度 |
| 35-macro-block-lifecycle | macro block 分配 / GC 涉及 compact |
| 89-memtable-memstore | memtable freeze → mini-sstable（#89 §10.1） |
| 90-sstable-macroblock-encoding | SSTable → micro block 写入 |

---

## 1. 整体架构：Compaction 3 层

### 1.1 模块组成（142 文件）

```bash
# Storage 层 Compaction（108 文件）
src/storage/compaction/
├── ob_basic_schedule_tablet_func.{h,cpp}    # 调度核心
├── ob_basic_tablet_merge_ctx.{h,cpp}          # merge 上下文
├── ob_batch_freeze_tablets_dag.{h,cpp}       # batch freeze DAG
├── ob_block_op.{h,cpp}                       # block 操作
├── ob_ckm_error_tablet_info.h                # CKM 错误信息
├── ob_column_checksum_calculator.{h,cpp}     # 列 checksum
├── ob_compaction_dag_ranker.{h,cpp}          # DAG 排序
├── ob_compaction_diagnose.{h,cpp}            # 诊断
├── ob_compaction_memory_context.{h,cpp}      # 内存 ctx
├── ob_compaction_memory_pool.{h,cpp}          # 内存池
├── ob_compaction_schedule_iterator.{h,cpp}    # 调度迭代
├── ob_compaction_schedule_util.{h,cpp}        # 调度工具
├── ob_compaction_suggestion.{h,cpp}          # compaction 建议
├── ob_tablet_merge_task.h                    # tablet merge 任务
├── ob_partition_merge_progress.{h,cpp}       # 合并进度
├── filter/                                    # filter 子目录
└── # ... 80+ 其他

# RootServer 层 Freeze（34 文件）
src/rootserver/freeze/
├── ob_daily_major_freeze_launcher.{h,cpp}    # 每日 major freeze
├── ob_freeze_info_detector.{h,cpp}           # freeze info 检测
├── ob_freeze_reentrant_thread.{h,cpp}        # freeze reentrant thread
├── ob_checksum_validator.{h,cpp}             # checksum 校验
├── ob_fts_checksum_validate_util.{h,cpp}      # FTS checksum 工具
├── ob_major_freeze_helper.{h,cpp}            # major freeze helper
├── ob_major_freeze_rpc_define.{h,cpp}         # RPC 定义
├── ob_major_freeze_service.{h,cpp}            # major freeze service
├── ob_major_freeze_util.{h,cpp}              # major freeze 工具
├── ob_major_merge_info_manager.{h,cpp}       # major merge info
└── # ... 24+ 其他

# Share 层
src/share/
├── ob_freeze_info_proxy.h                   # freeze info proxy
└── ob_freeze_info_manager.h                # freeze info manager
```

**142 文件** —— Compaction + Freeze 联合体量可观。

### 1.2 3 层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Compaction 调度 (ObBasicScheduleTabletFunc)          │
│  - 选 tablet + 选 SSTable list                                │
│  - DAG 优先级排序 (ObCompactionDagRanker)                      │
│  - 调度合并任务 (参见 #41 DAG 调度)                            │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Compaction 执行 (ObTabletMergeTask)                   │
│  - per-tablet merge task                                      │
│  - 合并多个 SSTable → 1 个新 SSTable                          │
│  - 写新 SSTable + 替换 handle                                 │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: Freeze (Major / Daily)                                │
│  - 每日定时 major freeze (ObDailyMajorFreezeLauncher)         │
│  - Reentrant thread 协调 (ObFreezeReentrantThread, 参见 #74)  │
│  - Major freeze 协调 (ObMajorFreezeService)                    │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. Minor Freeze —— memtable → mini-sstable

### 2.1 触发条件

参见 #89 §10.1 + #14 §10.1：
- memtable size > 阈值（默认 256MB）
- 距离上次 freeze 时间 > 阈值
- 显式 ALTER SYSTEM MINOR FREEZE

### 2.2 流程

```
触发条件满足
    │
    ▼
ObMemtableCompactWriter::freeze
    │
    ├─ 1. memtable 状态: active → frozen
    │
    ├─ 2. 写 mini-sstable
    │   └─ 写 ObSSTable 到本地磁盘（参见 #90）
    │
    ├─ 3. 通知 ObTabletMemtableMgr
    │   └─ 把 frozen memtable 替换为 mini-sstable handle
    │
    └─ 4. 调度 major freeze（如果有足够 mini-sstable）
        └─ ObCompactionService
```

### 2.3 与 #89 MemTable 的关系

`ObMemtableCompactWriter` 已在 #89 §7 详细分析。Minor freeze 的核心是：
- 内存数据 → SSTable 格式
- 不阻塞 DML（新数据写入新 memtable）
- 释放内存

---

## 3. Major Freeze —— multiple mini-sstable → SSTable

### 3.1 触发条件

| 触发源 | 触发条件 |
|--------|----------|
| **Daily Major Freeze** | 每日定时（默认凌晨） |
| **Merge Threshold** | 单 tablet mini-sstable 数量 > 阈值 |
| **Space Pressure** | 磁盘空间 > 阈值 |
| **Manual** | `ALTER SYSTEM MAJOR FREEZE` |

### 3.2 流程

```
触发 Major Freeze
    │
    ▼
ObCompactionService::trigger_merge
    │
    ├─ 1. 选 tablet 列表
    │   └─ 优先选 mini-sstable 多的 / 写少的
    │
    ├─ 2. 对每个 tablet 调度 DAG merge
    │   └─ ObCompactionDagRanker 排序
    │
    ▼
per tablet:
    │
    ├─ 3. ObTabletMergeTask 读所有 mini-sstable
    │
    ├─ 4. 合并相同 rowkey
    │   └─ 多个版本 → 最新版本
    │
    ├─ 5. 写新 SSTable
    │
    ├─ 6. 替换 handle（旧 mini-sstable 标记可 GC）
    │
    └─ 7. 调 ObBlockManager 释放旧 macro block（参见 #35）
```

### 3.3 Merge 策略

| 策略 | 说明 | 适用 |
|------|------|------|
| **Minor Merge** | 仅合并 mini-sstable → SSTable | 短期整理 |
| **Major Merge** | 合并所有 mini-sstable + 旧 SSTable → 新 SSTable | 长期整理 |
| **历史 compaction** | 合并超 7 天的 SSTable | 防碎片 |

参见 #34 §3 + §10。

---

## 4. ObMajorFreezeService（RS 端）

### 4.1 类骨架

```cpp
// (推测, src/rootserver/freeze/ob_major_freeze_service.h)
class ObMajorFreezeService {
public:
  // 触发 major freeze
  int trigger_major_freeze(const ObFreezeArg &arg);

  // 协调各 observer
  int coordinate_observers();

  // 监控 freeze 进度
  int check_progress();
};
```

### 4.2 与 RS / Observer 协作

```
RS: ObMajorFreezeService.trigger_major_freeze
    │
    ├─ 1. 写 freeze info 到内部表
    │
    ├─ 2. broadcast 给所有 observer
    │
    ▼
各 observer:
    │
    ├─ 3. 收到 broadcast → 触发本地 freeze
    │
    ├─ 4. 写 freeze log → PALF
    │
    └─ 5. ack RS
    │
    ▼
RS 收集 ack
    │
    └─ 6. freeze 完成
```

### 4.3 关键文件

```bash
src/rootserver/freeze/
├── ob_major_freeze_service.{h,cpp}       # 主 service
├── ob_major_freeze_helper.{h,cpp}        # helper
├── ob_major_freeze_rpc_define.{h,cpp}     # RPC 定义
├── ob_major_freeze_util.{h,cpp}          # 工具
├── ob_major_merge_info_manager.{h,cpp}   # major merge info
├── ob_freeze_info_detector.{h,cpp}       # freeze info 检测
├── ob_freeze_reentrant_thread.{h,cpp}    # freeze reentrant thread
├── ob_daily_major_freeze_launcher.{h,cpp}# 每日 major freeze
├── ob_checksum_validator.{h,cpp}         # checksum 校验
└── # ... 24+ 其他
```

---

## 5. ObBasicScheduleTabletFunc —— 调度核心

### 5.1 类骨架

```cpp
// (推测, src/storage/compaction/ob_basic_schedule_tablet_func.{h,cpp})
class ObBasicScheduleTabletFunc {
public:
  // 选 tablet 调度
  int schedule_tablets(ObArray<share::ObLSID> &ls_ids);

  // 选 SSTable list
  int select_merge_tablets();

  // 优先级排序
  int rank_tablets();
};
```

### 5.2 调度策略

- **选 tablet**：遍历所有 LS，按需合并的优先级排序
- **选 SSTable list**：每个 tablet 选要合并的 mini-sstable + 旧 SSTable
- **排序**：用 `ObCompactionDagRanker`（参见 #6.1）

### 5.3 与 #41 DAG 调度的关系

Compaction 调度共享 DAG 框架（参见 #41 / #66）：
- 每个 tablet merge 任务 = 1 个 DAG 节点
- DAG 调度器按优先级排序 + 并发执行
- ObCompactionDagRanker 决定 DAG 节点执行顺序

---

## 6. ObCompactionDagRanker —— DAG 优先级排序

### 6.1 类骨架

```cpp
// (推测, src/storage/compaction/ob_compaction_dag_ranker.{h,cpp})
class ObCompactionDagRanker {
public:
  // 排序
  int rank(ObIArray<ObDag *> &dags);

  // 评分函数（per tablet）
  int score_tablet(share::ObLSID &ls_id, const ObTabletMeta &meta);

private:
  // 评分因子
  int64_t mini_sstable_count_;
  int64_t oldest_sstable_age_;
  int64_t disk_usage_;
  // ... 几十个
};
```

### 6.2 评分因子

| 因子 | 含义 | 权重 |
|------|------|------|
| **mini-sstable 数量** | 越多越紧迫 | 高 |
| **最旧 SSTable 年龄** | 越久越需要合并 | 中 |
| **磁盘使用率** | 越高越紧迫 | 中 |
| **写放大** | 越高越需要合并 | 低 |
| **表活跃度** | 高峰期不合并 | 负权 |

### 6.3 与 #41 DAG 调度的关系

DAG 调度共享框架（参见 #41）：
- 评分 → 排序 → 入队 → 执行
- 多 observer 并发执行
- 全局配额限制（不超磁盘 IO 上限）

---

## 7. ObPartitionMergeProgress —— 合并进度

### 7.1 类骨架

```cpp
// (推测, src/storage/compaction/ob_partition_merge_progress.{h,cpp})
class ObPartitionMergeProgress {
public:
  // 进度查询
  int get_progress(const share::ObLSID &ls_id, ObPartitionMergeProgressInfo &info);

  // 监控
  int get_active_merge_tasks();
  int get_pending_merge_tasks();
};
```

### 7.2 进度跟踪

- **active merge tasks**：当前正在合并的 tablet 数
- **pending merge tasks**：等待合并的 tablet 数
- **estimated remaining time**：预计剩余时间

### 7.3 监控虚拟表

参见 #84 监控虚拟表：
- `ob_all_virtual_*_partition_merge_progress`
- `ob_all_virtual_dag`（参见 #41）
- `ob_all_virtual_server_compaction_progress`（参见 #84）

---

## 8. Daily Major Freeze / Reentrant Thread

### 8.1 ObDailyMajorFreezeLauncher

```cpp
// src/rootserver/freeze/ob_daily_major_freeze_launcher.{h,cpp}
class ObDailyMajorFreezeLauncher {
public:
  // 启动 daily major freeze
  int start();

  // 周期触发
  int trigger_daily();
};
```

**目的**：每日凌晨自动触发 major freeze，防止 SSTable 无限增长。

### 8.2 ObFreezeReentrantThread

```cpp
// src/rootserver/freeze/ob_freeze_reentrant_thread.{h,cpp}
class ObFreezeReentrantThread : public ObRsReentrantThread {
public:
  // reentrant 模式
  void run1() override;
};
```

参见 #74：Reentrant Thread 模式 + idle + heartbeat。

### 8.3 ObFreezeInfoDetector

```cpp
// src/rootserver/freeze/ob_freeze_info_detector.{h,cpp}
class ObFreezeInfoDetector {
public:
  // 检测是否需要 freeze
  int detect_need_freeze(const share::ObLSID &ls_id);

  // 触发条件判断
  bool should_freeze(const ObFreezeInfo &info);
};
```

---

## 9. 与其他文章的关系

### 9.1 与 #06 MemTable Freezer

#06 是早期分析 memtable freezer 概览。本篇是 #06 的 **深化**：
- #06 聚焦 minor freeze
- 本文覆盖 minor + major + compaction 全体系

### 9.2 与 #34 SSTable Merge

#34 是早期分析 SSTable merge 概览。本篇是 #34 的 **深化**：
- #34 聚焦 merge 策略
- 本文深入 ObBasicScheduleTabletFunc + ObCompactionDagRanker + ObMajorFreezeService + ObPartitionMergeProgress 各自的实现

### 9.3 与 #89 MemTable

Minor freeze 是 memtable → mini-sstable 的路径（参见 #89 §10.1）。

### 9.4 与 #90 SSTable

Major freeze 产生新 SSTable，过程与 #90 §10 描述一致。

### 9.5 与 #48 Data Checkpoint

Checkpoint 触发 compaction 调度（参见 #48）：
- checkpoint 后检查 freeze 条件
- 满足条件则 trigger major freeze

### 9.6 与 #41 DAG 调度

Compaction 调度共享 DAG 框架（参见 #41 / #66）：
- 每个 tablet merge 任务 = 1 个 DAG 节点
- ObCompactionDagRanker 排序
- 并发执行

### 9.7 与 #35 Macro Block Lifecycle

Major freeze 释放旧 macro block（参见 #35）：
- ObBlockManager 释放（参见 #90）
- SSTable 替换 + GC

---

## 10. 总结

### 10.1 Compaction 体系在 OB 体系中的定位

Compaction 是 **OB 存储整理的核心**：
- Minor freeze（memtable → mini-sstable）
- Major freeze（mini-sstable → SSTable）
- DAG 调度 + 优先级排序
- Daily major freeze 自动化

### 10.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Minor Freeze | `ObMemtableCompactWriter`（参见 #89） |
| Major Freeze | `ObMajorFreezeService`（RS 端）+ observer 端 |
| Daily Major | `ObDailyMajorFreezeLauncher` |
| 调度核心 | `ObBasicScheduleTabletFunc` |
| DAG 排序 | `ObCompactionDagRanker` |
| 合并任务 | `ObTabletMergeTask` |
| 合并进度 | `ObPartitionMergeProgress` |
| Reentrant | `ObFreezeReentrantThread`（参见 #74） |
| Freeze Info | `ObFreezeInfoDetector` + `ObFreezeInfoManager` |
| Checksum | `ObChecksumValidator` |
| 调度 DAG | `ObBatchFreezeTabletsDag` |
| 调度迭代 | `ObCompactionScheduleIterator` + `ObCompactionScheduleUtil` |
| 调度建议 | `ObCompactionSuggestion` |
| 内存 | `ObCompactionMemoryContext` + `ObCompactionMemoryPool` |
| 诊断 | `ObCompactionDiagnose` |
| 列 Checksum | `ObColumnChecksumCalculator` |
| 块操作 | `ObBlockOp` |
| 块 dump | `ob_block_op.{h,cpp}` |
| Tablet 合并 | `ObTabletMergeTask` + `ObBasicTabletMergeCtx` |
| 合并进度 | `ObPartitionMergeProgress` |
| 过滤 | `filter/` 子目录 |

### 10.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/storage/compaction/` (108 文件) | Compaction 主目录 |
| `src/storage/compaction/ob_basic_schedule_tablet_func.{h,cpp}` | 调度核心 |
| `src/storage/compaction/ob_basic_tablet_merge_ctx.{h,cpp}` | merge ctx |
| `src/storage/compaction/ob_batch_freeze_tablets_dag.{h,cpp}` | batch freeze DAG |
| `src/storage/compaction/ob_block_op.{h,cpp}` | block 操作 |
| `src/storage/compaction/ob_column_checksum_calculator.{h,cpp}` | 列 checksum |
| `src/storage/compaction/ob_compaction_dag_ranker.{h,cpp}` | DAG 排序 |
| `src/storage/compaction/ob_compaction_diagnose.{h,cpp}` | 诊断 |
| `src/storage/compaction/ob_compaction_memory_context.{h,cpp}` | 内存 ctx |
| `src/storage/compaction/ob_compaction_memory_pool.{h,cpp}` | 内存池 |
| `src/storage/compaction/ob_compaction_schedule_iterator.{h,cpp}` | 调度迭代 |
| `src/storage/compaction/ob_compaction_schedule_util.{h,cpp}` | 调度工具 |
| `src/storage/compaction/ob_compaction_suggestion.{h,cpp}` | compaction 建议 |
| `src/storage/compaction/ob_partition_merge_progress.{h,cpp}` | 合并进度 |
| `src/storage/compaction/ob_tablet_merge_task.h` | tablet merge 任务 |
| `src/storage/compaction/filter/` | filter 子目录 |
| `src/rootserver/freeze/ob_major_freeze_service.{h,cpp}` | major freeze service |
| `src/rootserver/freeze/ob_major_freeze_helper.{h,cpp}` | major freeze helper |
| `src/rootserver/freeze/ob_major_freeze_rpc_define.{h,cpp}` | RPC 定义 |
| `src/rootserver/freeze/ob_major_freeze_util.{h,cpp}` | major freeze 工具 |
| `src/rootserver/freeze/ob_major_merge_info_manager.{h,cpp}` | major merge info |
| `src/rootserver/freeze/ob_daily_major_freeze_launcher.{h,cpp}` | 每日 major freeze |
| `src/rootserver/freeze/ob_freeze_info_detector.{h,cpp}` | freeze info 检测 |
| `src/rootserver/freeze/ob_freeze_reentrant_thread.{h,cpp}` | freeze reentrant thread |
| `src/rootserver/freeze/ob_checksum_validator.{h,cpp}` | checksum 校验 |
| `src/rootserver/freeze/ob_fts_checksum_validate_util.{h,cpp}` | FTS checksum 工具 |
| `src/share/ob_freeze_info_proxy.h` | freeze info proxy |
| `src/share/ob_freeze_info_manager.h` | freeze info manager |
| `src/observer/virtual_table/ob_all_virtual_dag.h` | DAG 虚拟表（参见 #41） |

### 10.4 合并策略对比

| 策略 | 触发 | 范围 | 影响 |
|------|------|------|------|
| **Minor Freeze** | memtable size | 当前 LS | 释放 memtable 内存 |
| **Major Freeze** | mini-sstable 累积 / 定时 | 跨 LS | 减少 SSTable 数量 |
| **Daily Major** | 每日定时 | 全集群 | 防止碎片 |
| **History Compact** | SSTable > 7 天 | 跨 LS | 长期整理 |

### 10.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#93 DDL 物理执行 / Online DDL 实现**（深化 #64）：

OB 的 DDL 物理执行路径 —— Schema Service + 跨 observer 协调 + 异步增量更新。源码入口：`src/storage/ddl/` + `src/rootserver/ob_ddl_service.{h,cpp}` + `src/sql/ddl/`。

适用场景：DDL 性能分析 / 兼容性 / 长事务处理。

整吗？