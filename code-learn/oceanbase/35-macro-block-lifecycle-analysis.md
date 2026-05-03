# 35. Macro Block 生命周期 — 分配、GC、回收

> 深入 OceanBase Macro Block 的完整生命周期：从磁盘分配、引用计数管理，到 Mark-and-Sweep 垃圾回收、坏块检测，以及文件的自动扩展。

---

## 1. 概述

Macro Block 是 OceanBase 存储引擎中**物理写入的最小单元**。每个 Macro Block 固定大小为 **2MB**（`OB_DEFAULT_MACRO_BLOCK_SIZE`），按顺序存放在数据文件中。与逻辑上的 SSTable 不同，Macro Block 是磁盘上真实存在的、有固定偏移和大小的物理块。

一套完整的 Macro Block 生命周期管理涉及：

```
┌─────────────────────────────────────────────────────────────────┐
│                    Macro Block 生命周期                          │
│                                                                 │
│  分配路径                                                       │
│  ┌──────────┐   ┌──────────────┐   ┌────────────────────────┐   │
│  │ 数据写入 │ → │ alloc_block  │ → │ 生成 MacroBlockId      │   │
│  │  SSTable │   │ (分配磁盘)   │   │ (write_seq + block_idx)│   │
│  └──────────┘   └──────────────┘   └────────────────────────┘   │
│                        │                                        │
│                        ▼                                        │
│               ┌────────────────┐                                │
│               │ 写数据到磁盘   │                                │
│               │ inc_ref 计数  │                                │
│               └────────────────┘                                │
│                        │                                        │
│  使用与释放               │                                    │
│                        ▼                                        │
│               ┌──────────────────┐                              │
│               │ SSTable 生命周期  │                              │
│               │ dec_ref → ref=0  │ → pending_free_count++       │
│               └──────────────────┘                              │
│                        │                                        │
│  GC 路径                  ▼                                        │
│  ┌──────────────────────────────────────────────────────┐       │
│  │  Mark-and-Sweep（每 30s 定时触发）                    │       │
│  │  1. 收集 ref_cnt=0 的候选块                           │       │
│  │  2. Mark：遍历所有活跃 Tablet/SSTable，标记在用块     │       │
│  │  3. Sweep：对未标记的块调用 free_block 回收磁盘空间   │       │
│  └──────────────────────────────────────────────────────┘       │
│                        │                                        │
│  文件管理                                                     │
│                        ▼                                        │
│  ┌──────────────────────────────────────────────┐               │
│  │ extend_file_size_if_need                      │               │
│  │ 空闲块 < 512 或空闲率 < 10% → 自动扩展       │               │
│  └──────────────────────────────────────────────┘               │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. ObBlockManager — 块管理器

### 2.1 架构定位

`ObBlockManager` 是管理 Macro Block 生命周期的核心类，位于 `ob_block_manager.h @ L178`（具体在 `src/storage/blocksstable/` 下）。

```cpp
class ObBlockManager
{
  // 核心接口
  int alloc_block(ObMacroBlockHandle &macro_handle);       // 分配块
  int inc_ref(const MacroBlockId &macro_id);               // 增加引用
  int dec_ref(const MacroBlockId &macro_id);               // 减少引用
  void mark_and_sweep();                                    // 垃圾回收
  int first_mark_device();                                  // 首次标记
  int resize_file(...);                                     // 调整文件大小
  // ...
};
```

关键设计点：

- **单例模式**：`ObServerBlockManager` 继承自 `ObBlockManager`，通过 `OB_SERVER_BLOCK_MGR` 宏全局访问（`ob_block_manager.h @ L536`）
- **生命周期**：`init → start → (alloc/write/read/mark_and_sweep) → stop → wait → destroy`
- **线程安全**：使用 `ObBucketLock` 对 Block Map 做分桶锁，细粒度并发控制

### 2.2 内部数据结构

**BlockMap**（`ob_block_manager.h @ L304`）：

```cpp
typedef common::ObLinearHashMap<MacroBlockId, BlockInfo> BlockMap;
```

使用 `ObLinearHashMap`（线性哈希表）管理所有已分配的 Macro Block。Key 是 `MacroBlockId`，Value 是 `BlockInfo`。

**BlockInfo**（`ob_block_manager.h @ L246`）：

```cpp
struct BlockInfo
{
  int64_t ref_cnt_;          // 引用计数
  int64_t access_time_;      // 最近访问时间
  int64_t last_write_time_;  // 最近写入时间
};
```

每个 Block 的三个关键状态：

| 字段 | 含义 | 用途 |
|------|------|------|
| `ref_cnt_` | 引用计数 | 决定块是否可回收（0 = 可回收） |
| `access_time_` | 最近访问时间 | 坏块检测用，2天未访问才检查 |
| `last_write_time_` | 最近写入时间 | GC 和排查用 |

**ObMacroBlockInfo**（`ob_block_manager.h @ L61`）是暴露给上层的精简版本：

```cpp
struct ObMacroBlockInfo
{
  int32_t ref_cnt_;
  bool is_free_;
  int64_t access_time_;
};
```

---

## 3. 块分配路径

### 3.1 alloc_object 与 alloc_block

OceanBase 提供两层分配接口：

1. **`alloc_object`**（`ob_block_manager.cpp @ L156`）：供 `ObStorageObjectHandle` 使用，包含文件扩展重试逻辑。
2. **`alloc_block`**（`ob_block_manager.cpp @ L204`）：底层分配，返回 `MacroBlockHandle`。

核心流程如下：

```
alloc_block(handle)
  │
  ├─ io_device_->alloc_block(&opts, io_fd)    // 从磁盘设备分配
  │    └─ 返回: io_fd (first_id_=disk_id, second_id_=block_index)
  │
  ├─ 若磁盘空间不足 (OB_SERVER_OUTOF_DISK_SPACE)
  │   └─ extend_file_size_if_need()           // 自动扩展文件
  │   └─ 重试 alloc_block
  │
  ├─ blk_seq_generator_.generate_next_sequence(write_seq)
  │   └─ 全局递增 rewrite_seq_，标记写入顺序
  │
  ├─ macro_id.set(write_seq, io_fd.second_id_)
  │   └─ 生成 MacroBlockId(write_seq, block_index, 0)
  │
  └─ ATOMIC_AAF(&alloc_num_, 1)               // 记录分配计数
```

关键源码行号：`ob_block_manager.cpp @ L204-L253`。

### 3.2 MacroBlockId 组成

`MacroBlockId` 是一个复合 ID，包含三个维度：

```
┌──────────────┬──────────────────┬──────────┐
│  write_seq   │   block_index    │  unused  │
│  (64bit)     │   (64bit)        │  (64bit) │
└──────────────┴──────────────────┴──────────┘
```

- **write_seq**：全局递增的写入序列号，由 `ObMacroBlockRewriteSeqGenerator` 生成（线程安全，`SpinRWLock` 保护）
- **block_index**：磁盘设备分配的实际物理块索引（`io_fd.second_id_`）
- **disk_id**：`io_fd.first_id_`，标识磁盘设备

**分配编号的边界检查**（`ob_block_manager.cpp @ L80-L91`）：

```cpp
if (OB_UNLIKELY(MacroBlockId::MAX_WRITE_SEQ == rewrite_seq_)) {
  ret = OB_ERROR_OUT_OF_RANGE;
} else {
  blk_seq = ++rewrite_seq_;
  if (OB_UNLIKELY(BLOCK_SEQUENCE_WARNING_LINE < blk_seq)) {
    const int64_t remaining = MacroBlockId::MAX_WRITE_SEQ - blk_seq;
    // 剩余 10T 重写量时报警
  }
}
```

`BLOCK_SEQUENCE_WARNING_LINE = MAX_WRITE_SEQ - 5,000,000`，当序列号接近耗尽时发出严重告警，提示需要迁移数据。

### 3.3 分配后的写入路径

`async_write_block`（`ob_block_manager.cpp @ L257-L268`）展示了完整的"分配+写入"链路：

```cpp
int ObBlockManager::async_write_block(const ObMacroBlockWriteInfo &write_info,
                                      ObMacroBlockHandle &macro_handle)
{
  OB_SERVER_BLOCK_MGR.alloc_block(macro_handle);   // 1. 分配
  macro_handle.async_write(write_info);             // 2. 写入
}
```

`write_block` 进一步封装了 `wait()` 实现同步写入。

---

## 4. 块的引用计数管理

### 4.1 引用计数机制

OceanBase 使用**引用计数**（Reference Counting）而非全量 Mark-and-Sweep 来跟踪每个 Macro Block 的使用状态。这是其 GC 策略的基础。

**inc_ref**（`ob_block_manager.cpp @ L665-L703`）：

```cpp
int ObBlockManager::inc_ref(const MacroBlockId &macro_id) {
  ObBucketHashWLockGuard lock_guard(bucket_lock_, macro_id.hash());
  // ...
  block_info.ref_cnt_++;
  block_map_.insert_or_update(macro_id, block_info);
}
```

**dec_ref**（`ob_block_manager.cpp @ L705-L750`）：

```cpp
int ObBlockManager::dec_ref(const MacroBlockId &macro_id) {
  ObBucketHashWLockGuard lock_guard(bucket_lock_, macro_id.hash());
  // ...
  block_info.ref_cnt_--;
  block_map_.insert_or_update(macro_id, block_info);
  if (block_info.ref_cnt_ == 0) {
    ATOMIC_INC(&pending_free_count_);     // 🔑 标记为待回收
  }
}
```

关键设计点：

- **分桶锁**：`ObBucketLock`（2048 个桶）对每个 block 做独立锁，避免全表锁竞争
- **ref_cnt_ = 0** 并不立即回收，只递增 `pending_free_count_`，等待定时 GC 统一回收
- **安全断言**：当 ref_cnt_ < 0 时触发 `OB_ERR_UNEXPECTED`，防止引用泄漏

### 4.2 引用计数的使用场景

引用计数的增/减由上层 SSTable、Tablet 等组件管理：

```
SSTable 打开 → inc_ref(macro_id)
SSTable 关闭 → dec_ref(macro_id)
Tablet 加载 → inc_ref(meta_blocks)
Tablet 卸载 → dec_ref(meta_blocks)
```

---

## 5. GC 策略 — Mark-and-Sweep

### 5.1 触发机制

Macro Block 的垃圾回收由定时任务 `MarkBlockTask` 驱动：

- **间隔**：`RECYCLE_DELAY_US = 30s`（`ob_block_manager.h @ L300`）
- **注册**：`start()` 方法中通过 `timer_.schedule(mark_block_task_, RECYCLE_DELAY_US, true)` 注册（`ob_block_manager.cpp @ L127-L129`）
- **执行**：`MarkBlockTask::runTimerTask()` 调用 `blk_mgr_.mark_and_sweep()`

与常见的引用计数 GC 不同，OceanBase 采用**"引用计数 + Mark-and-Sweep"**混合策略：

1. **引用计数**实时跟踪使用状态（`inc_ref`/`dec_ref`）
2. **Mark-and-Sweep**定期做全局确认，回收确认不再使用的块

### 5.2 mark_and_sweep 完整流程

`mark_and_sweep`（`ob_block_manager.cpp @ L1049-L1135`）：

```
mark_and_sweep()
  │
  ├─ 1. 收集候选块
  │     └─ for_each block_map_ → 找 ref_cnt_=0 的块 → 放入 mark_info
  │     └─ 每轮最多回收 MAX_FREE_BLOCK_COUNT_PER_ROUND = 200,000 个块
  │     └─ 记录 alloc_num 快照（用于检测并发分配）
  │
  ├─ 2. Mark：标记在用块（从 mark_info 中排除）
  │     ├─ mark_tmp_file_blocks()          // 临时文件
  │     ├─ mark_server_meta_blocks()       // 服务器元数据
  │     └─ for_each tenant:
  │         ├─ mark_tenant_ckpt_blocks()   // 租户检查点
  │         ├─ mark_tablet_blocks()        // Tablet 块
  │         │   ├─ mark_tablet_meta_blocks()
  │         │   ├─ mark_sstable_blocks()   // SSTable 数据+索引+链
  │         │   └─ mark_tablet_block()     // Tablet 自身
  │         ├─ mark_held_shared_block()    // 共享块
  │         └─ calc_ext_disk_cache_blocks()// 外部缓存
  │
  ├─ 3. 检查并发分配
  │     └─ alloc_num 对比：若有并发分配，下一轮再回收
  │
  └─ 4. Sweep：回收未标记的块
        └─ do_sweep(mark_info):
            └─ for_each mark_info:
                sweep_one_block(macro_id):
                  ├─ block_map_.erase(macro_id)
                  ├─ io_device_->free_block(io_fd)    // 通知磁盘设备释放
                  └─ ATOMIC_DEC(&pending_free_count_)
```

**标记阶段**的核心逻辑在 `mark_macro_blocks`（`ob_block_manager.cpp @ L1137-L1200`），它遍历所有活跃的 Tenant、Tablet、SSTable，从 `mark_info` 中移除正在使用的块。最终 `mark_info` 中只保留**未被任何活跃对象引用**的块。

### 5.3 关键阈值

| 常量 | 值 | 含义 |
|------|-----|------|
| `RECYCLE_DELAY_US` | 30s | GC 定时器间隔 |
| `MAX_FREE_BLOCK_COUNT_PER_ROUND` | 200,000 | 单轮最大回收数（约 400GB） |
| `MARK_THRESHOLD` | 0.2 | 标记阶段的内存占比阈值 |
| `DEFAULT_LOCK_BUCKET_COUNT` | 2048 | 分桶锁桶数 |
| `DEFAULT_PENDING_FREE_COUNT` | 1024 | 待回收列表预分配大小 |

### 5.4 为什么不用纯引用计数？

引用计数很快（O(1)），但无法处理**循环引用**和**遗漏引用**。Mark-and-Sweep 从全局视图出发，遍历所有活跃数据结构，确保不会被误回收。

这种混合策略结合了两者优势：
- **引用计数**：实时、低延迟跟踪
- **Mark-and-Sweep**：周期性、全局确认，保证正确性

---

## 6. 坏块检测

OceanBase 还内置了**坏块检测**机制，由 `InspectBadBlockTask` 定时执行（`INSPECT_DELAY_US = 1s`）：

```
InspectBadBlockTask::runTimerTask()
  │
  ├─ 检查间隔：2 天（ACCESS_TIME_INTERVAL = 2 * 86400 * 1000000 µs）
  │
  ├─ 每轮检测量：
  │     ├─ 每轮最少 1 个块
  │     ├─ 最多 1000 次搜索（MAX_SEARCH_COUNT_PER_ROUND）
  │     └─ 根据 verify_cycle 分配每日检测配额
  │
  └─ check_block():
        ├─ 异步读取整个 Macro Block（2MB）
        ├─ ObSSTableMacroBlockChecker::check() → 物理校验
        └─ 校验失败 → report_bad_block() 记录
```

坏块会被记录在 `bad_block_infos_` 数组中，最多可记录总块数的 1%（最小 10 条）。

---

## 7. 文件管理

### 7.1 文件结构

Macro Block 存储在数据文件中。每个数据文件的物理布局：

```
┌─────────────────────────────────┐
│  Super Block（文件头）           │ ← offset=0
├─────────────────────────────────┤
│  Macro Block 0 (2MB)            │
├─────────────────────────────────┤
│  Macro Block 1 (2MB)            │
├─────────────────────────────────┤
│  ...                            │
├─────────────────────────────────┤
│  Macro Block N (2MB)            │
└─────────────────────────────────┘
```

Super Block 在 `ob_super_block_struct.h` 中定义（位于 `ObServerSuperBlock::body_`），包含：

```cpp
struct {
  int64_t macro_block_size_;           // 默认 2MB
  int64_t total_macro_block_count_;    // 总块数
  int64_t total_file_size_;            // 文件总大小
  int64_t modify_timestamp_;           // 最后修改时间
  // ...
};
```

### 7.2 文件自动扩展

当磁盘空间不足时，`extend_file_size_if_need()`（`ob_block_manager.cpp @ L1876-L1937`）自动扩展数据文件：

```
检查条件（同时满足任一）：
  1. free_block_cnt < AUTO_EXTEND_LEAST_FREE_BLOCK_CNT (512个, 即1GB)
  2. free_block_cnt < total_block_cnt - total_block_cnt * usage_upper_bound / 100

扩展动作：
  └─ ObServerUtils::calc_auto_extend_size() 计算建议扩展大小
  └─ OB_STORAGE_OBJECT_MGR.resize_local_device() 执行扩展
```

文件扩展的限制：
- `datafile_maxsize`：最大文件大小上限
- `datafile_next`：每次扩展大小
- `reserved_size`：预留空间（默认 4GB）

### 7.3 文件手动调整

`resize_file()` 提供手动调整接口（`ob_block_manager.cpp @ L632-L663`）：

```cpp
int ObBlockManager::resize_file(
    const int64_t new_data_file_size,
    const int64_t new_data_file_disk_percentage,
    const int64_t reserved_size,
    ObServerSuperBlock &super_block)
```

调整时更新 Super Block 中的 `total_file_size_` 和 `total_macro_block_count_`。

### 7.4 空间统计查询

ObBlockManager 提供一系列查询接口：

| 接口 | 含义 | 实现 |
|------|------|------|
| `get_free_macro_block_count()` | 空闲块数 | `io_device_->get_free_block_count()` |
| `get_used_macro_block_count()` | 已用块数 | `block_map_.count()` |
| `get_pending_free_macro_block_count()` | 待回收块数 | `ATOMIC_LOAD(&pending_free_count_)` |
| `get_max_macro_block_count(reserved)` | 最大可用块数 | `io_device_->get_max_block_count(reserved)` |
| `get_total_block_size()` | 文件总大小 | `io_device_->get_total_block_size()` |

---

## 8. 设计决策

### 8.1 为什么是 2MB 固定大小？

- **I/O 效率**：2MB 是 HDD/SSD 顺序读写的高效粒度，在延迟和吞吐之间取平衡
- **元数据简单**：固定大小意味着不需要在文件系统中追踪变长块，Block ID 可直接映射到文件偏移
- **对齐友好**：2MB 对齐到操作系统页（4KB）和 SSD 擦除块（通常 512KB-4MB）

### 8.2 引用计数 vs Mark-and-Sweep

**为什么不只用引用计数？**
- 引用计数无法处理循环引用（虽然 OceanBase 的 DAG 结构中很少出现）
- 引用计数遗漏（某个模块忘记 dec_ref）会导致空间泄漏
- Mark-and-Sweep 作为安全网，保证最终一致

**为什么不只用 Mark-and-Sweep？**
- 停顿时长不可控：遍历所有 Tablet/SSTable 可能很慢
- 引用计数提供了实时的内存/空间约束反馈（O(1) 操作）

### 8.3 分配策略

- **随机分配**：`io_device_->alloc_block()` 在磁盘上分配任意空闲位置，不做顺序性保证
- **Write Sequence**：通过 `write_seq`（全局递增）记录写入顺序，虽然物理位置是随机的，但写入顺序可追踪
- **无原地更新**：Macro Block 一旦写入即为不可变（immutable），更新通过写新块+GC 旧块实现（类似 LSM-Tree）

### 8.4 碎片管理

由于块大小固定（2MB），不存在内部碎片。但外部碎片（空闲块分散）由 `io_device` 底层管理，通过空闲块 bitmap 或 free list 维护。ObBlockManager 本身不关注物理连续性——上层通过 `MacroBlockId` 访问，不要求数据块连续。

### 8.5 延迟回收的设计

当 `dec_ref` 使 `ref_cnt_` 降为 0 时，不会立即回收，而是：
1. 递增 `pending_free_count_`
2. 等待 `mark_and_sweep` 下一轮 GC
3. 在 `sweep_one_block` 中才实际释放

这种延迟回收的好处：
- **减少竞争**：避免直接在写入路径上做昂贵的回收操作
- **批量处理**：一次 GC 回收多个块，提高效率
- **二次确认**：Mark 阶段再次确认块确实未被使用，防止误回收

---

## 9. 与前文的关联

### 文章 08（SSTable 格式）
SSTable 是逻辑存储单元，Macro Block 是物理存储单元。一个 SSTable 的宏块包括：Meta Block（元数据）、Index Block（索引）、Data Block（数据）、Linked Block（链式宏块，用于大数据行）。

### 文章 34（SSTable Merge）
合并（Compaction）是 Macro Block 生命周期中最重要的"触发器"。合并过程中：
- **旧块**：从旧 SSTable 读取数据 → 合并后引用计数降为 0 → 进入待回收列表
- **新块**：通过 `alloc_block` 分配 → 写入合并后的数据 → `inc_ref` 关联到新 SSTable

合并是 Macro Block 分配和回收的主要驱动因素，一次大规模合并可能触发成百上千个 Macro Block 的分配/释放。

---

## 10. ASCII 图 — 完整生命周期

```
                             ┌──────────────┐
                             │ SSTable Merge │
                             │ (Compaction)  │
                             └──────┬───────┘
                                    │
                    ┌───────────────┴───────────────┐
                    │                               │
                    ▼                               ▼
            ┌──────────────┐                ┌──────────────┐
            │ alloc_block  │                │ dec_ref → 0  │
            │ (分配新块)   │                │ (旧块释放)   │
            └──────┬───────┘                └──────┬───────┘
                   │                              │
                   ▼                              ▼
            ┌──────────────┐                ┌──────────────┐
            │ 写入数据     │                │ pending_free │
            │ inc_ref = 1  │                │ 等待 GC      │
            └──────┬───────┘                └──────┬───────┘
                   │                              │
                   │                              ▼
                   │                     ┌──────────────────┐
                   │                     │ mark_and_sweep() │
                   │                     │ 每 30s 定时触发  │
                   │                     └──────┬───────────┘
                   │                              │
                   │                              ▼
                   │                     ┌──────────────────┐
                   │                     │  Mark: 遍历所有   │
                   │                     │  Tablet/SSTable  │
                   │                     │  确认在用块      │
                   │                     └──────┬───────────┘
                   │                              │
                   │                              ▼
                   │                     ┌──────────────────┐
                   │                     │  Sweep: 回收     │
                   │                     │  free_block()   │
                   │                     └──────┬───────────┘
                   │                              │
                   │                              ▼
                   │                     ┌──────────────────┐
                   └─────────────────────│ 磁盘空间释放     │
                                         │ (可被重用)      │
                                         └──────────────────┘
```

---

## 11. 源码索引

| 文件 | 关键符号 | 行号 | 说明 |
|------|---------|------|------|
| `ob_block_manager.h` | `ObBlockManager` | 178 | 块管理器主类 |
| `ob_block_manager.h` | `BlockInfo` | 246 | 块元数据（ref_cnt, access_time） |
| `ob_block_manager.h` | `BlockMap` | 304 | 块哈希表 |
| `ob_block_manager.h` | `MacroBlkIdMap` | 305 | GC 标记图 |
| `ob_block_manager.h` | `BlockMapIterator` | 445 | 首次标记迭代器 |
| `ob_block_manager.h` | `MarkBlockTask` | 459 | GC 定时任务 |
| `ob_block_manager.h` | `InspectBadBlockTask` | 474 | 坏块检测定时任务 |
| `ob_block_manager.h` | `ObMacroBlockInfo` | 61 | 精简块信息 |
| `ob_block_manager.h` | `ObMacroBlockWriteInfo` | 96 | 写入请求结构 |
| `ob_block_manager.h` | `ObMacroBlockReadInfo` | 128 | 读取请求结构 |
| `ob_block_manager.h` | `ObMacroBlockRewriteSeqGenerator` | 154 | 写入序列号生成器 |
| `ob_block_manager.cpp` | `alloc_object` | 156 | 对象级分配 |
| `ob_block_manager.cpp` | `alloc_block` | 204 | 块级分配 |
| `ob_block_manager.cpp` | `inc_ref` | 665 | 增加引用计数 |
| `ob_block_manager.cpp` | `dec_ref` | 705 | 减少引用计数 |
| `ob_block_manager.cpp` | `mark_and_sweep` | 1049 | GC 主入口 |
| `ob_block_manager.cpp` | `mark_macro_blocks` | 1137 | 标记阶段 |
| `ob_block_manager.cpp` | `mark_sstable_blocks` | 1224 | 标记 SSTable 块 |
| `ob_block_manager.cpp` | `sweep_one_block` | 1028 | 单块回收 |
| `ob_block_manager.cpp` | `extend_file_size_if_need` | 1876 | 文件自动扩展 |
| `ob_block_manager.cpp` | `InspectBadBlockTask::runTimerTask` | 1862 | 坏块检测入口 |
| `ob_block_sstable_struct.h` | `ObMacroBlockMarkerStatus` | 698 | GC 状态统计 |
| `ob_block_sstable_struct.h` | `ObSimpleMacroBlockInfo` | 674 | 精简块信息（GC 用） |
| `ob_block_sstable_struct.h` | `ObBloomFilterMacroBlockHeader` | 534 | Bloom Filter 宏块头 |
| `ob_macro_block_struct.h` | `ObMacroBlocksWriteCtx` | 22 | 批量写入上下文 |
| `ob_object_manager.h` | `OB_STORAGE_OBJECT_MGR` | 453 | 全局对象管理器宏 |
| `ob_super_block_struct.h` | `ObServerSuperBlock` | ~90 | Super Block 定义 |
| `ob_io_device.h` | `ObIODevice` | - | 底层 I/O 设备抽象 |

---

*前篇：[34. SSTable Merge — 合并机制深度分析](./34-sstable-merge-analysis.md)*  
*后篇：[36. ObMacroBlockHandle — 异步 I/O 封装](./36-macro-block-handle-analysis.md)*
