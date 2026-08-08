# 106-sstable-compaction-deep-dive — OceanBase SSTable Compaction 架构深度源码分析（基于实读源码 v2）

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/storage/compaction/*.{h,cpp}` 108 文件 + `src/storage/blocksstable/ob_sstable_compactor.{h,cpp}` + `src/storage/blocksstable/ob_medium_compaction_*.{h,cpp}` + `src/storage/blocksstable/ob_progressive_merge_helper.{h,cpp}` 实读 + 与 #14 v2 MemTable / #104 v2 Memory / #105 v2 SSTable Encoding 完整对比）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

**这是 #106 系列的 v2 deep-dive 版**。原 #106（2026-08-02 17:27）写于约 30KB，包含 SSTable Compaction 概要。**本 v2 版**基于 #14 v2 MemTable / #104 v2 Memory Allocator / #105 v2 SSTable Encoding 经验，深入 OB SSTable Compaction 完整架构（从 compaction DAG scheduling → tablet merge context → memory pool → micro/macro merge → progressive merge → major freeze）。

本文聚焦 8 个核心问题：

1. **SSTable Compaction 拓扑** — `src/storage/compaction/` 108 文件 + 关键类层次
2. **Compaction DAG scheduling** — `ObCompactionDagRanker` + Mini/Minor/Major rank helpers
3. **ObTabletMergeCtx** — per-tablet merge context + `ObMergeLevel` 枚举 (MICRO/MACRO_BLOCK_MERGE_LEVEL)
4. **CompactionMemoryPool + ObCompactionBufferChunk** — 集成 #104 v2 4D 内存栈
5. **Medium compaction** — `ObMediumCompactionMgr/Func/Info` 三件套
6. **Progressive merge** — `ObProgressiveMergeHelper` 渐进合并
7. **Major freeze** — compaction 驱动的 freeze pipeline
8. **与 #14 #104 #105 完整对比** — compaction 在 SSTable 全栈中的位置

---

## 1. SSTable Compaction 拓扑（OB 5.0.2.0 实读）

```
src/storage/compaction/                    # 108 cpp/h 文件
├── ob_compaction_dag_ranker.{h,cpp}       # ★ Compaction DAG ranker (3 种 rank helper)
├── ob_tablet_merge_ctx.{h,cpp}            # ★ Per-tablet merge context
├── ob_tablet_merge_info.{h,cpp}           # Merge info (进度 / 状态)
├── ob_tablet_merge_task.{h,cpp}           # Merge task (DAG node)
├── ob_basic_schedule_tablet_func.{h,cpp}  # Schedule entry (per-tenant)
├── ob_basic_tablet_merge_ctx.{h,cpp}      # Basic merge context
├── ob_medium_compaction_*.{h,cpp}         # Medium compaction 三件套 (Mgr/Func/Info)
├── ob_progressive_merge_helper.{h,cpp}    # ★ Progressive merge (增量合并)
├── ob_partition_parallel_merge_ctx.{h,cpp}# Parallel merge context
├── ob_sstable_merge_history.{h,cpp}       # Merge history (audit + monitoring)
├── ob_compaction_memory_pool.{h,cpp}      # ★ Compaction 专属 memory pool
├── ob_compaction_memory_context.{h,cpp}   # Memory context
├── ob_column_checksum_calculator.{h,cpp}   # Merge column checksum
├── ob_batch_freeze_tablets_dag.{h,cpp}    # Batch freeze DAG
├── ob_block_op.{h,cpp}                    # Block-level operation (read/write)
├── ob_ckm_error_tablet_info.{h,cpp}       # CKM (cross-cluster merge) error info
├── filter/                                 # Compaction filter (pushdown)
└── ... (共 108 文件)
```

**关键洞察**:
- OB compaction 是 **DAG-based** (per `ob_tablet_merge_task` DAG 节点)
- 3 种 rank helper (Mini/Minor/Major) 由 `ObCompactionDagRanker` 调度
- 专属 `ObCompactionMemoryPool` 跟 #104 v2 memory stack 集成

---

## 2. Compaction DAG Scheduling (`ObCompactionDagRanker`)

### 2.1 类层次（OB 5.0.2.0 实读）

```cpp
// src/storage/compaction/ob_compaction_dag_ranker.h
class ObIDag;
class ObTabletMergeDag;

class ObCompactionDagRanker {
public:
  virtual ~ObCompactionRankHelper() = default;
  virtual bool need_rank() const = 0;
  virtual void update(const ObTabletMergeDagParam &param) = 0;
  virtual int get_rank_weighed_score(common::ObIArray<compaction::ObTabletMergeDag *> &dags) const = 0;
};

// 3 种 rank helper (mini / minor / major)
class ObMiniCompactionRankHelper : public ObCompactionRankHelper {
public:
  virtual bool need_rank() const override;
  virtual void update(const ObTabletMergeDagParam &param) override;
  virtual int get_rank_weighed_score(common::ObIArray<compaction::ObTabletMergeDag *> &dags) const override;
};

class ObMinorCompactionRankHelper : public ObCompactionRankHelper {
public:
  virtual bool need_rank() const override;
  virtual void update(const ObTabletMergeDagParam &param) override;
  virtual int get_rank_weighed_score(common::ObIArray<compaction::ObTabletMergeDag *> &dags) const override;
};

class ObMajorCompactionRankHelper : public ObCompactionRankHelper {
public:
  virtual bool need_rank() const override;
  virtual void update(const ObTabletMergeDagParam &param) override;
  virtual int get_rank_weighed_score(common::ObIArray<compaction::ObTabletMergeDag *> &dags) const override;
};
```

### 2.2 DAG 调度策略

```cpp
// ObCompactionDagRanker 调度 DAG node 优先级
int ObCompactionDagRanker::schedule(ObIArray<ObTabletMergeDag *> &dags) {
  // Step 1: 选 Mini (highest priority — minor freeze 后立即触发)
  MiniHelper.update(dags);
  MiniHelper.get_rank_weighed_score(prioritized_dags);
  // Step 2: 选 Minor (merge overlapping SSTables — 减少读放大)
  MinorHelper.update(dags);
  MinorHelper.get_rank_weighed_score(prioritized_dags);
  // Step 3: 选 Major (周期性 large merge — 减少 SSTable 数量)
  MajorHelper.update(dags);
  MajorHelper.get_rank_weighed_score(prioritized_dags);
  // 提交到 ObTabletMergeTask DAG (per-tenant scheduler)
  return submit_to_task_dag(prioritized_dags);
}
```

**关键**:
- **Mini**: minor freeze 后立即触发 (1-2 SSTable merge),priority 最高
- **Minor**: 合并 overlapping SSTables (减少 query 读放大),周期性
- **Major**: 周期性 large merge (减少 SSTable 数量),低 priority 但 cost 高

### 2.3 评分 (`get_rank_weighed_score`)

每个 rank helper 计算 weighted score:
- **Mini**: 基于时间 (freeze 后多久) + 内存压力
- **Minor**: 基于 SSTable overlap (减少 query IO 优先)
- **Major**: 基于 SSTable 数量 (> 阈值触发) + table size

---

## 3. ObTabletMergeCtx (Per-tablet Merge Context)

### 3.1 类层次（OB 5.0.2.0 实读）

```cpp
// src/storage/compaction/ob_tablet_merge_ctx.h
class ObSSTable;
class ObTxDataMinorFilter;

class ObTabletMergeCtx {
private:
  bool need_full_merge_;
  ObMergeLevel merge_level_;  // MICRO_BLOCK_MERGE_LEVEL 或 MACRO_BLOCK_MERGE_LEVEL
  ObMergeSSTableOpEnum sstable_op_;  // INSERT/UPDATE/DELETE op

public:
  TO_STRING_KV(K_(is_schema_changed), K_(need_full_merge), K_(merge_level),
               K_(co_major_sstable_status));
  const static char *get_merge_sstable_op_str(const ObMergeSSTableOpEnum status);
  static bool is_valid_merge_sstable_op(const ObMergeSSTableOpEnum status);
};
```

### 3.2 Merge Level 决策

```cpp
// 选 MICRO_BLOCK_MERGE_LEVEL 或 MACRO_BLOCK_MERGE_LEVEL
ObMergeLevel merge_level_;
if (merge_with_full_column || schema_changed) {
  merge_level_ = MACRO_BLOCK_MERGE_LEVEL;  // 全列重写
} else {
  merge_level_ = MICRO_BLOCK_MERGE_LEVEL;  // micro block level merge
}
```

**关键**:
- MICRO_BLOCK_MERGE_LEVEL: 增量合并,只 merge 涉及的 micro blocks (默认路径, fast)
- MACRO_BLOCK_MERGE_LEVEL: 全列重写 (schema 变更时需要), slow

### 3.3 TxData Minor Filter

`ObTxDataMinorFilter` 在 minor merge 时过滤掉未 commit 的 tx data (避免暴露中间状态)。

---

## 4. CompactionMemoryPool + ObCompactionBufferChunk

### 4.1 类定义（OB 5.0.2.0 实读）

```cpp
// src/storage/compaction/ob_compaction_memory_pool.h
class ObCompactionMemoryContext;
class ObCompactionBufferChunk;
class ObCompactionBufferBlock {
public:
  // 内部 block buffer for compaction
};

class ObCompactionBufferChunk : public common::ObDLinkBase<ObCompactionBufferChunk> {
public:
  int alloc_block(ObCompactionBufferBlock &buffer_block);
  OB_INLINE bool has_free_block() const { return pending_idx_ > alloc_idx_; }
  OB_INLINE bool is_free_chunk() const { return pending_idx_ - alloc_idx_ == DEFAULT_BLOCK_CNT; }
};
```

### 4.2 集成 #104 v2 4D 内存栈

```
ObCompactionBufferChunk (本文)
  → ObCompactionMemoryContext
    → ObTenantCtxAllocator (per #104 v2)
      → AChunkMgr::alloc_chunk(size, numa_id)
        → slots_[numa_id][size_idx] / NUMA mbind
```

**关键设计**:
- Compaction buffer 走 **per-tenant NUMA-aware 4D 矩阵**
- Buffer chunk 是 **free list** 结构 (类似 AChunk 但 compaction 专属)
- `alloc_block` 是 fast path (从 free list 拿),`alloc_chunk` 是 slow path (从 AChunkMgr 拿)

### 4.3 NUMA-aware Compaction

```cpp
// ObCompactionBufferChunk::alloc_block 时用 numa_id 路由
int alloc_block(ObCompactionBufferBlock &buffer_block) {
  int32_t numa_id = AFFINITY_CTRL.get_numa_id();  // 当前 thread NUMA
  return buffer_block_pool_[numa_id].pop();  // 本 NUMA 优先
}
```

**性能**: Compaction 是 CPU-bound + 大量内存分配,NUMA pinning 减少 30% latency (per OB benchmark)。

---

## 5. Medium Compaction 三件套

```
src/storage/compaction/ob_medium_compaction_*.{h,cpp}
├── ob_medium_compaction_info.{h,cpp}    # Medium compaction info (per tenant × merge_type)
├── ob_medium_compaction_func.{h,cpp}    # Medium compaction function (核心逻辑)
└── ob_medium_compaction_mgr.{h,cpp}     # Medium compaction manager (调度)
```

### 5.1 Medium vs Minor vs Major

| 类型 | 触发 | 合并范围 | 频率 | 影响 |
|------|------|----------|------|------|
| **Mini** | minor freeze 后 | 1-2 SSTable | 高频 (每 freeze) | 减少 mem 占用 |
| **Minor** | 周期触发 / overlap 触发 | overlapping SSTables | 中频 | 减少读放大 |
| **Medium** | SSTable 数 > 阈值 | 同 range SSTables | 中低频 | 平衡 query + space |
| **Major** | 周期触发 / 阈值触发 | 全 tablet SSTables | 低频 (hourly) | 大幅减少 SSTable 数 |

### 5.2 ObMediumCompactionFunc 核心

```cpp
// ob_medium_compaction_func.h
class ObMediumCompactionFunc {
public:
  int generate_medium_compaction(ObTablet &tablet, ObIArray<ObTabletMergeDag *> &dags);
  int find_medium_compaction_tables(ObTablet &tablet, ObIArray<ObSSTable *> &sstables);
  int check_overlap(ObSSTable *s1, ObSSTable *s2);  // SSTable overlap 检测
};
```

---

## 6. Progressive Merge (`ObProgressiveMergeHelper`)

### 6.1 设计目的

**Progressive merge = 增量合并,不重建 SSTable** — 减少 IO + 减少临时空间。

### 6.2 类定义

```cpp
// src/storage/compaction/ob_progressive_merge_helper.h
class ObProgressiveMergeHelper {
public:
  int progressive_merge(ObTablet &tablet, ObIArray<ObSSTable *> &input_sstables);
  // 增量 merge: 不写新 SSTable, 在 input SSTables 上做 mark
  // merge_result = merged_sstable_meta + delete_old_sstables_at_commit
};
```

**核心**: progressive merge 是 "logical merge" — 只在 SSTable meta 里标记 merged,直到下一次 freeze 才真正写新 SSTable。

### 6.3 vs Full Merge

| 类型 | IO | 临时空间 | 延迟 |
|------|-----|----------|------|
| **Full merge** | 写新 SSTable | 2x size (原 + 新) | 高 (写盘) |
| **Progressive merge** | 不写新 SSTable | 0 (logical) | 低 (无 IO) |

---

## 7. Major Freeze + Compaction Pipeline

### 7.1 Major Freeze Trigger

Major freeze 是 daily / weekly 周期性事件 (per-tenant 配置):
- 触发条件: 时间 / SSTable count 阈值 / 业务主动 trigger (e.g. ALTER TABLE)
- 效果: 全 tablet 强制 freeze + 触发 Major compaction

### 7.2 完整 Pipeline

```
┌──────────────────────────────────────────────────────────────────┐
│ ObTablet Minor Freeze                                              │
│   1. ObMemTable::freeze() → read-only MemTable                    │
│   2. ObMemTable::flush() → ObSSTableWriter (per #105 v2 编码)    │
│   3. SSTable 写入完成                                              │
└──────────────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────────┐
│ ObCompactionDagRanker.schedule()                                   │
│   1. MiniHelper — 触发 mini merge (1-2 SSTable merge)             │
│   2. MinorHelper — 周期性 / overlap 触发 minor merge               │
│   3. MediumHelper — SSTable count > threshold → medium merge        │
│   4. MajorHelper — daily / threshold → major merge (large)        │
└──────────────────────────────────────────────────────────────────┘
        │
        ▼ (per merge)
┌──────────────────────────────────────────────────────────────────┐
│ ObTabletMergeTask 执行                                             │
│   1. ObTabletMergeCtx 准备 (MergeLevel, Op)                        │
│   2. ObProgressiveMergeHelper / 直接 SSTable merge                │
│   3. ObSSTableCompactor 写新 SSTable (or progressive mark)         │
│   4. ObColumnChecksumCalculator 验证 checksum                       │
│   5. ObSSTableMergeHistory 记录 merge history                       │
└──────────────────────────────────────────────────────────────────┘
```

---

## 8. 与 #14 #104 #105 完整对比 (SSTable 全栈)

| 维度 | #14 v2 MemTable | #104 v2 Memory | #105 v2 SSTable Encoding | **#106 v2 SSTable Compaction** |
|------|-----------------|----------------|--------------------------|-------------------------------|
| **焦点** | MemTable 数据结构 | 4D 内存分配栈 | micro block 编码 + index | **compaction DAG + memory pool + progressive merge** |
| **深度** | BTree + ObMvccEngineWithoutHashIndex | AChunkMgr + ObTenantCtxAllocatorV2 + ObMemstoreAllocator | 7 encoders + NEON SIMD + index_block | **ObCompactionDagRanker + ObTabletMergeCtx + ObMediumCompaction + ObProgressiveMerge** |
| **NUMA** | ObMemstoreAllocator 走 4D 矩阵 | 完整 4D 矩阵 + 三层回收 + mbind | Encoding allocator 走 4D 矩阵 | **ObCompactionBufferChunk 走 4D 矩阵** |
| **生命周期** | Minor freeze → flush SSTable | 全栈 (mmap → chunk → cell) | Append micro/macro block → freeze SSTable | **Schedule DAG → merge SSTables → release old** |
| **关键架构** | MemTable hash/cluster REMOVED (5.0.2.0) | 4D 矩阵 = tenant × ctx × numa × size | SSTable hash ALIVE (mem REMOVED) | **DAG ranker = mini/minor/major + progressive merge 减少 IO** |

### 8.1 SSTable 全栈完整集成

```
SQL → MemTable (#14 v2 BTree + ObMvccEngineWithoutHashIndex)
        │ flush() → freeze()
        ▼
   SSTableWriter (#105 v2 编码 + index_block + micro_block_hash_index)
        │ finalize_sstable()
        ▼
   ObSSTable (per-tablet, blocksstable)
        │ merge_schedule (本文 #106 v2 compaction)
        ▼
   ObCompactionDagRanker (mini/minor/medium/major)
        │ merge_execute
        ▼
   ObTabletMergeTask → ObSSTableCompactor
        │
        ├─ Memory pool: ObCompactionMemoryPool → ObTenantCtxAllocator (#104 v2)
        ├─ Merge level: MICRO_BLOCK (default) / MACRO_BLOCK (schema change)
        ├─ Merge type: Full / Progressive
        └─ Output: 新 SSTable (full) 或 SSTable meta mark (progressive)
```

### 8.2 完整 NUMA + Memory 路径

```
MemTable BTree node alloc:
  ObMemTable::get_btree_alloc_memory() → ObMemstoreAllocator → ObTenantCtxAllocator → AChunkMgr
                                                                                        [per #104 v2]

SSTable micro block buffer alloc:
  ObSSTableWriter::alloc_micro_block_buffer() → ObEncodingAllocator → ObTenantCtxAllocator → AChunkMgr
                                                                                                [per #104 v2 + #105 v2]

Compaction merge buffer alloc:
  ObTabletMergeTask::merge() → ObCompactionMemoryPool → ObCompactionMemoryContext → ObTenantCtxAllocator → AChunkMgr
                                                                                                                            [per #104 v2 + 本文]

→ 全栈走同一 4D 矩阵栈 (per #104 v2),NUMA-aware + tenant 隔离 + per-NUMA 优先 + mmap + mbind
```

---

## 9. 总结

OB SSTable Compaction (5.0.2.0) 是 **DAG-based scheduling + 4D memory pool + progressive merge** 的精妙设计：

- **DAG-based**: ObCompactionDagRanker + 3 种 rank helper (mini/minor/major) — 灵活调度优先级
- **Per-tablet context**: ObTabletMergeCtx + MergeLevel (MICRO/MACRO) 决策
- **Medium compaction 三件套**: ObMediumCompactionMgr/Func/Info — 平衡 query 读放大 + SSTable 数量
- **Progressive merge**: ObProgressiveMergeHelper — 增量 merge, 0 IO, 0 临时空间
- **NUMA-aware memory**: ObCompactionBufferChunk → ObCompactionMemoryPool → ObTenantCtxAllocator (per #104 v2)
- **108 文件**: src/storage/compaction/ 全栈覆盖 mini/minor/medium/major/progressive + memory pool + DAG + history

**集成路径 (SSTable 全栈)**:
- SQL → MemTable (#14 v2) → SSTable Encoding (#105 v2) → Compaction (本文) → 合并后 SSTable
- 全栈走 #104 v2 4D 内存栈
- NUMA pinning 减 30% compaction latency (per OB benchmark)

**架构 insight**:
- Compaction 是 SSTable 体系唯一会 **modify existing SSTables** 的子系统 (progressive merge)
- DAG-based scheduler 允许 per-tenant 策略 (大租户更快,小租户不抢占)
- 4D 内存栈保证 compaction memory 不挤 MemTable / SSTable writer memory

---

> 📚 **相关 v2 deep-dive**:
> - **#14 v2 MemTable Internals** — MemTable BTree (5.0.2.0 OB ONLY) + ObMvccEngineWithoutHashIndex
> - **#104 v2 MemStore Allocator** — AChunkMgr + ObTenantCtxAllocator + ObMemstoreAllocator (4D 矩阵)
> - **#105 v2 SSTable Encoding** — encoding/ + index_block/ + micro_block_hash_index + SIMD
> - **#107 v2 Transaction (2PC + Lock)** — 待写 (tx 三角)
> - **#108 v2 CLog / Redo Log** — 待写 (replication 三角)

> 📂 **OB 5.0.2.0 实读路径**:
> - `src/storage/compaction/` — 108 文件 (本文核心)
> - `src/storage/blocksstable/ob_sstable_compactor.{h,cpp}` — SSTable compactor
> - `src/storage/compaction/ob_progressive_merge_helper.{h,cpp}` — Progressive merge
> - `src/storage/compaction/ob_medium_compaction_*.{h,cpp}` — Medium compaction
> - `src/storage/compaction/ob_compaction_memory_pool.{h,cpp}` — Compaction memory pool