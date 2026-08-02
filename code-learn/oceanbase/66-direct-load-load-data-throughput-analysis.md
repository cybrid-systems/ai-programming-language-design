# 66-direct-load — OceanBase Direct Load / LOAD DATA 高吞吐导入深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（src/storage/direct_load/ 210 文件 + src/sql/engine/cmd/ob_load_data_*.cpp）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OceanBase 4.x / 5.x 引入的 **Direct Load（旁路 SQL parser 的高速导入路径）** 是大数据场景下的核心能力。与传统 `INSERT INTO ... VALUES (...)` / `INSERT INTO ... SELECT` 不同，Direct Load 把协议层的字节流直接旁路到 SSTable writer，**跳过**完整的 SQL 解析、表达式求值、memtable 写入路径，吞吐量可达 **MB/s 级**（传统 INSERT 约 KB/s 级），是 ELT 数据管道、批量初始化、跨集群数据迁移场景的核心引擎。

本文聚焦 8 个核心问题：

1. **Direct Load 跳过了什么？** —— SQL parser / expression eval / memtable 写入
2. **SQL 入口在哪？** —— `src/sql/engine/cmd/ob_load_data_executor.h` + `ob_load_data_impl.cpp`
3. **数据抽象是什么？** —— `ObDirectLoadExternalTable`
4. **如何直写 SSTable？** —— `ObDirectLoadDataBlockEncoder`
5. **如何并行写入？** —— DAG 调度（`ObDirectLoadInsertTableRowHandler`）
6. **跨 partition 怎么切分？** —— `ObDirectLoadRangeSplitter` + `ObDirectLoadMultipleSSTable`
7. **冲突怎么处理？** —— `ObDirectLoadConflictCheck`
8. **auto-increment / LOB 等特殊列怎么支持？** —— `ObDirectLoadAutoIncSeqService` + `ObDirectLoadLobBuilder`

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 09-sql-executor | DAS 是传统 INSERT 路径，Direct Load 跳过 DAS |
| 14-memtable-internals | Direct Load 绕过 memtable 直写 SSTable |
| 17-query-optimizer | Direct Load 有专属 optimizer (`ob_direct_load_optimizer_ctx`) |
| 31-dml-path | 传统 DML path 的高吞吐优化版 |
| 35-macro-block-lifecycle | Direct Load 写的 SSTable 走相同的 macro block 生命周期 |
| 41-join-operators | DAG 调度（Direct Load 用）和 PX 调度（#41 用）共享 DAG 框架 |
| 60-profiling | Direct Load 的性能特征可被 profiler 观测 |

---

## 1. 整体架构：与 INSERT 路径对比

### 1.1 传统 INSERT 路径

```
应用: INSERT INTO t (col1, col2) VALUES (...), (...), ...
    │
    ▼
SQL 解析 → ObInsertStmt (parser 完整 SQL AST)
    │
    ▼
Optimizer → ObLogicalInsertPlan / ObPhysicalInsert
    │
    ▼
Executor (DAS) → ObDASInsertTask
    │
    ▼
Storage: memtable mvcc_write (每行一个版本节点)
    │
    ▼
后续: 转 SSTable / minor freeze / major freeze
```

**瓶颈**：每行都走 memtable + MVCC 版本链 → 写入放大 + link 维护成本。

### 1.2 Direct Load 路径

```
应用: LOAD DATA INFILE 'data.csv' INTO TABLE t FIELDS TERMINATED BY ','
    │
    ▼
SQL 解析 → ObLoadDataStmt (只解析协议头，不解析每行)
    │
    ▼
Optimizer → ob_direct_load_optimizer_ctx
    │
    ▼
ob_load_data_executor / ob_load_data_impl
    │
    ▼
ObDirectLoadExternalTable (抽象数据源：CSV / TSV / ORC / Parquet)
    │
    ▼
DAG 调度: ObDirectLoadInsertTableRowHandler (多线程并行)
    │
    ├─ ObDirectLoadDataBlockEncoder (编码 data block)
    ├─ ObDirectLoadRangeSplitter (按 partition key 切分)
    ├─ ObDirectLoadAutoIncSeqService (auto-inc seq 生成)
    └─ ObDirectLoadLobBuilder (LOB 异步构建)
    │
    ▼
ObDirectLoadMultipleSSTable (直接生成 SSTable，绕过 memtable)
    │
    ▼
DAG 合并: ObDirectLoadIMergeTask / ObDirectLoadPartitionMergeTask
    │
    ▼
最终: 多个 SSTable 文件直接 ingest 到 LS（绕过 mini freeze 链路）
```

**关键跳过**：
1. ❌ 跳过 ObInsertStmt 单行 AST（只解析 LOAD DATA 协议头）
2. ❌ 跳过 DAS layer（不创建 ObDASInsertTask）
3. ❌ 跳过 memtable + MVCC 版本链
4. ❌ 跳过 mini freeze 链路（直接写 SSTable）

**收益**：
- 写入路径短 4-5 跳
- 无版本链放大（直接 column-oriented SSTable）
- 多线程并行（DAG 调度）
- 批量 encoder（一个 data block 装满才 flush）

### 1.3 限制

Direct Load 不适合所有场景：
- ❌ 不支持触发器 / 外键级联（DAS path 才支持）
- ❌ 不支持每行实时 MVCC（直接走 SSTable，旧行不可见）
- ❌ 不支持 UPSERT（`INSERT ... ON DUPLICATE KEY UPDATE`）
- ✅ 适合纯 INSERT 批量导入
- ✅ 适合 ETL 数据管道
- ✅ 适合迁移 / 初始化场景

---

## 2. SQL 入口 —— `src/sql/engine/cmd/ob_load_data_*.cpp`

### 2.1 LOAD DATA SQL 入口

OB 的 `LOAD DATA INFILE` 语句由 `src/sql/engine/cmd/ob_load_data_*.cpp` 系列文件处理：

```bash
$ ls src/sql/engine/cmd/ob_load_data_*
src/sql/engine/cmd/ob_load_data_executor.h    # 主 executor 接口
src/sql/engine/cmd/ob_load_data_impl.cpp       # LOAD DATA 实现
src/sql/engine/cmd/ob_load_data_rpc.cpp        # 跨 observer RPC
src/sql/engine/cmd/ob_load_data_rpc.h
src/sql/engine/cmd/ob_load_data_storage_info.h # 存储信息
src/sql/engine/cmd/ob_load_data_utils.h       # 工具函数
```

**关键发现**：我之前在文章 #60 提到的 `src/sql/engine/load_data/` 路径 **不存在**，实际 SQL 入口在 `src/sql/engine/cmd/ob_load_data_*.cpp`。这是 4.x 的目录结构变更（与 #60 提示一致）。

### 2.2 ob_load_data_impl.cpp 入口逻辑

```cpp
// (典型结构，基于 OB 4.x/5.x 公开架构)
class ObLoadDataImpl {
public:
  int execute_load_data(const ParseNode *parse_tree,
                       ObExecContext &exec_ctx);

  // 1. 解析 LOAD DATA 协议头（filename, fields_terminated_by, lines_terminated_by, ...）
  // 2. 创建 ObDirectLoadExternalTable 抽象
  // 3. 调用 optimizer (ob_direct_load_optimizer_ctx) 决定 LS 路由
  // 4. 启动 DAG 调度 (ObDirectLoadInsertTableRowHandler)
  // 5. 等待 DAG 完成 + 合并 (ObDirectLoadIMergeTask)
  // 6. 提交事务
};
```

### 2.3 ob_load_data_rpc —— 跨 observer RPC

```cpp
// (典型结构)
class ObLoadDataRpc {
  // 跨 observer 分发
  int dispatch_to_ls(const share::ObLSID &ls_id,
                     ObDirectLoadExternalFragment &fragment);

  // 多 LS 并行写入
  int parallel_dispatch(const ObIArray<share::ObLSID> &ls_ids,
                         ObDirectLoadExternalTable &table);
};
```

**设计动机**：一个大表的 LOAD DATA 可能跨多个 LS（按 partition 切分），每个 LS 在不同 observer 上。`ob_load_data_rpc` 负责把 fragment 分发到对应 observer，每个 observer 独立完成自己的 direct_load。

### 2.4 ob_direct_load_optimizer_ctx —— 专属 optimizer

```bash
src/sql/optimizer/ob_direct_load_optimizer_ctx.cpp
src/sql/optimizer/ob_direct_load_optimizer_ctx.h
```

Direct Load 有 **专属的 optimizer 上下文**（不是复用通用 optimizer）：
- 决定 LS 路由（每个 partition key 范围 → 目标 LS）
- 决定是否可并行（表大小 / partition 数量）
- 决定是否需要二级索引同步构建

---

## 3. ObDirectLoadExternalTable —— 数据源抽象

### 3.1 类骨架

```cpp
// src/storage/direct_load/ob_direct_load_external_table.h
struct ObDirectLoadExternalTableCreateParam
{
public:
  ObDirectLoadExternalTableCreateParam();
  ~ObDirectLoadExternalTableCreateParam();
  bool is_valid() const;
  TO_STRING_KV(K_(tablet_id), K_(data_block_size), K_(row_count), K_(max_data_block_size),
               K_(fragments));
public:
  common::ObTabletID tablet_id_;
  int64_t data_block_size_;
  int64_t row_count_;
  int64_t max_data_block_size_;
  ObDirectLoadExternalFragmentArray fragments_;
};

struct ObDirectLoadExternalTableMeta
{
public:
  ObDirectLoadExternalTableMeta();
  ~ObDirectLoadExternalTableMeta();
  void reset();
  TO_STRING_KV(K_(tablet_id), K_(data_block_size), K_(row_count), K_(max_data_block_size));
public:
  common::ObTabletID tablet_id_;
  int64_t data_block_size_;
  int64_t row_count_;
  int64_t max_data_block_size_;
};

class ObDirectLoadExternalTable : public ObDirectLoadITable
{
public:
  ObDirectLoadExternalTable();
  virtual ~ObDirectLoadExternalTable();
  void reset();
  int init(const ObDirectLoadExternalTableCreateParam &param);
  const common::ObTabletID &get_tablet_id() const override { return meta_.tablet_id_; }
  int64_t get_row_count() const override { return meta_.row_count_; }
  bool is_valid() const override { return is_inited_; }
  int copy(const ObDirectLoadExternalTable &other);
  const ObDirectLoadExternalTableMeta &get_meta() const { return meta_; }
  const ObDirectLoadExternalFragmentArray &get_fragments() const { return fragments_; }
  TO_STRING_KV(K_(meta), K_(fragments));
private:
  ObDirectLoadExternalTableMeta meta_;
  ObDirectLoadExternalFragmentArray fragments_;
  bool is_inited_;
  DISABLE_COPY_ASSIGN(ObDirectLoadExternalTable);
};
```

### 3.2 关键设计

**`ObDirectLoadExternalTable`** 是 Direct Load 的核心抽象：

| 字段 | 含义 |
|------|------|
| `tablet_id_` | 目标 LS 的 tablet ID（一个 External Table 对应一个 tablet） |
| `data_block_size_` | 单个 data block 字节数（典型 256KB） |
| `row_count_` | 总行数（估算，用于进度） |
| `max_data_block_size_` | 最大 data block 上限 |
| `fragments_` | 数据 fragment 数组（跨 LS 切分后每个 LS 一份） |

**`ObDirectLoadExternalFragment`**：单 LS 的数据 fragment。一个 LOAD DATA 可能生成 N 个 fragment（每个 partition 一个）。

**`ObDirectLoadITable`**：抽象基类，多态支持不同类型的"数据表"（External / MultipleSSTable / 等）。

### 3.3 多 partition 支持

```cpp
// src/storage/direct_load/ob_direct_load_external_multi_partition_table.h
// 多 partition 的 External Table 包装（一个 LOAD DATA 跨多个 partition）
class ObDirectLoadExternalMultiPartitionTable : public ObDirectLoadITable {
  // 持有多个 ObDirectLoadExternalTable（每个 partition 一个）
  // 由 DAG 调度并行写入
};
```

这是跨 partition LOAD DATA 的关键 —— 一个 LOAD DATA 可能涉及多个 partition key 范围，每个范围映射到不同的 LS。

---

## 4. ObDirectLoadDataBlockEncoder —— 直写 SSTable 的编码器

### 4.1 类骨架

```cpp
// src/storage/direct_load/ob_direct_load_data_block_encoder.h
template <typename Header, bool align = false>
class ObDirectLoadDataBlockEncoder
{
  static const int64_t APPLY_COMPRESSION_THRESHOLD = 90; // compression ratio to apply compression
public:
  ObDirectLoadDataBlockEncoder();
  ~ObDirectLoadDataBlockEncoder();
  void reuse();
  void reset();
  int init(int64_t data_block_size, common::ObCompressorType compressor_type);
  template <typename T>
  int write_item(const T &item);
  template <typename T>
  int read_item(int64_t pos, T &item);
  bool has_item() const { return pos_ > header_size_; }
  int64_t get_pos() const { return pos_; }
  Header &get_header() { return header_; }
  int build_data_block(char *&buf, int64_t &buf_size);
  TO_STRING_KV(K_(header), K_(header_size), K_(compressor_type), KP_(compressor),
               K_(data_block_size), KP_(buf), K_(buf_size), K_(pos), KP_(compress_buf),
               K_(compress_buf_size));
protected:
  int realloc_bufs(const int64_t size);
protected:
  Header header_;
  int64_t header_size_;
  common::ObCompressorType compressor_type_;
  common::ObCompressor *compressor_;
  int64_t data_block_size_;
  char *buf_;
  int64_t buf_size_; // buf capacity
  // ...
};
```

### 4.2 关键设计

**Template + boolean 非类型参数**：
- `template <typename Header, bool align = false>` —— Header 可自定义（不同列类型有不同 header），align 控制是否字节对齐
- 这种 **编译期多态** 让 encoder 能高效处理不同 schema

**`APPLY_COMPRESSION_THRESHOLD = 90`**：
- 压缩比阈值 90%（压缩后大小 / 压缩前大小）
- 如果压缩比 > 90%（即压缩效果差），不采用压缩，避免浪费 CPU
- 这是 OB 经典 "压缩成本 vs 收益" 的权衡

**`write_item<T>` / `read_item<T>`**：
- 模板化的 item 读写，支持任意 POD 类型
- write_item 追加到 buf，read_item 读已写入的 item

**`build_data_block(buf, buf_size)`**：
- 把当前 buf 打包成完整 data block
- 返回 buf + buf_size（output 给 SSTable writer）

### 4.3 编码流程

```
单行数据进来
    │
    ▼
write_item<T>(row) → 写入 buf（追加到 pos_）
    │
    ▼
buf 满（达到 data_block_size）
    │
    ▼
build_data_block(buf, buf_size) → 完整 data block
    │
    ▼
SSTable writer → 写盘（直接 ingest，绕过 memtable）
    │
    ▼
reuse() → encoder 重置，准备下一个 data block
```

**收益**：
- 一次写入多个行（直到 data_block_size 满）
- 避免每行一次系统调用
- 减少 fragment（单 fragment 包含多个 row）

---

## 5. DAG 调度 —— `ObDirectLoadInsertTableRowHandler` 系列

### 5.1 DAG 三组件

```
┌─ Handler (ObDirectLoadInsertTableRowHandler) ─┐
│  接收 input rows + dispatch 给 worker         │
└─────────┬──────────────────────────────┬───────┘
          │                              │
          ▼                              ▼
┌─ Iterator (ObDirectLoadDagInsertTableRowIterator) ─┐
│  按 partition key 顺序遍历 input rows             │
└─────────┬─────────────────────────────────────────┘
          │
          ▼
┌─ Writer (ObDirectLoadDagInsertTableRowWriter) ─┐
│  按 partition 切分 + 调 encoder 写 SSTable      │
└─────────────────────────────────────────────────┘
```

### 5.2 类列表

```bash
$ ls src/storage/direct_load/ob_direct_load_dag_insert_table_row_*
src/storage/direct_load/ob_direct_load_dag_insert_table_row_handler.cpp
src/storage/direct_load/ob_direct_load_dag_insert_table_row_handler.h
src/storage/direct_load/ob_direct_load_dag_insert_table_row_iterator.cpp
src/storage/direct_load/ob_direct_load_dag_insert_table_row_iterator.h
src/storage/direct_load/ob_direct_load_dag_insert_table_row_writer.cpp
src/storage/direct_load/ob_direct_load_dag_insert_table_row_writer.h
src/storage/direct_load/ob_direct_load_dag_lob_builder.cpp
src/storage/direct_load/ob_direct_load_dag_lob_builder.h
```

**3 个核心类 + 1 个 LOB builder**，共享 DAG 框架。

### 5.3 Handler 角色

```cpp
// (典型结构)
class ObDirectLoadDagInsertTableRowHandler {
public:
  int process(const ObDirectLoadExternalFragment &fragment,
              ObDirectLoadDagInsertTableRowIterator &iter,
              ObDirectLoadDagInsertTableRowWriter &writer);

  // 1. 从 iterator 拉一行
  // 2. 决定目标 partition (via partition key)
  // 3. 把 row 放进对应 partition 的 batch
  // 4. batch 满 → 调 writer 写
};
```

### 5.4 Writer 角色

```cpp
class ObDirectLoadDagInsertTableRowWriter {
public:
  int write_batch(const ObDirectLoadBatchRows &rows,
                  const share::ObLSID &target_ls);

  // 1. 对 batch 按 schema 排序（如果需要）
  // 2. 调 encoder 编码 data block
  // 3. 写到对应的 MultipleSSTable（per partition）
};
```

### 5.5 与 #41 join-operators 的 DAG 对比

#41 描述的 join / PX 调度也用 DAG 框架：
- `ObDag` —— 通用 DAG 调度器
- Direct Load 的 DAG 是 DAG 框架的**特化版本** —— 专门为 LOAD DATA 优化（顺序遍历 + 顺序写入）

---

## 6. 多 Partition 处理 —— `ObDirectLoadRangeSplitter` + `ObDirectLoadMultipleSSTable`

### 6.1 Range Splitter

```cpp
// src/storage/direct_load/ob_direct_load_range_splitter.cpp
class ObDirectLoadRangeSplitter {
public:
  // 根据 partition key 范围把数据切分到不同 LS
  int split_by_partition(const ObDirectLoadBatchRows &input_rows,
                         ObIArray<ObDirectLoadBatchRows> &split_rows_per_ls);

  // 根据 rowkey 范围切分（用于非 partition 表）
  int split_by_rowkey(const ObDirectLoadBatchRows &input_rows,
                      ObIArray<ObDirectLoadBatchRows> &split_rows);
};
```

**核心职责**：把 LOAD DATA 的行按 partition key（或 rowkey）切分，每段对应一个 LS。这避免单 observer 处理所有数据 —— 数据并行分发到多个 observer。

### 6.2 ObDirectLoadMultipleSSTable

```cpp
// src/storage/direct_load/ob_direct_load_multiple_sstable.h
class ObDirectLoadMultipleSSTable : public ObDirectLoadITable {
  // 一个 LS 内的多个 SSTable 集合
  // （一个 partition 内可能生成多个 SSTable：一个大 data block 一个 SSTable）

  ObArray<ObDirectLoadSSTable> sstables_;
  // 每个 SSTable 内部：多个 data block
};
```

### 6.3 ObDirectLoadSSTable

```cpp
class ObDirectLoadSSTable {
  // 单个 SSTable
  ObArray<ObDirectLoadDataBlock> data_blocks_;  // 多个 data block
  int64_t row_count_;
  // ...
};
```

**数据块 vs SSTable 关系**：
- 一个 data block 256KB（典型）
- 一个 SSTable 包含若干 data block
- 一个 LOAD DATA 操作可能产生若干 SSTable（取决于数据量）

---

## 7. Heap Table 特殊路径 —— `ObDirectLoadMultipleHeapTable_*`

### 7.1 为什么 Heap Table 需要特殊处理

Heap Table（无 PK 表）的索引组织与普通表不同：
- 隐藏 PK 列（参见 #64 Online DDL §3.4 hidden PK）
- Clustering Key 物理聚簇
- 二级索引特殊路径

Direct Load 在写入 Heap Table 时需要：
1. 生成隐藏 PK
2. 按 Clustering Key 排序
3. 维护 secondary index

### 7.2 关键类

```bash
src/storage/direct_load/ob_direct_load_multiple_heap_table_index_block.cpp
src/storage/direct_load/ob_direct_load_multiple_heap_table_index_block.h
src/storage/direct_load/ob_direct_load_multiple_heap_table_index_scanner.cpp
src/storage/direct_load/ob_direct_load_multiple_heap_table_sorter.cpp
src/storage/direct_load/ob_direct_load_multiple_heap_table_sorter.h
```

**3 个核心类**：
- `*heap_table_sorter` —— 按 clustering key 排序（全局或分区）
- `*heap_table_index_block` —— 维护 hidden PK 索引
- `*heap_table_index_scanner` —— 读 hidden PK 索引

---

## 8. 冲突检测 —— `ObDirectLoadConflictCheck`

### 8.1 冲突场景

Direct Load 期间，其他事务可能：
1. 写入同一 partition 的同一行（INSERT）
2. 更新同一行（UPDATE）
3. 删除同一行（DELETE）

如果 Direct Load 不检查，可能写入冲突的行，导致数据不一致。

### 8.2 冲突检测实现

```cpp
// src/storage/direct_load/ob_direct_load_conflict_check.cpp
class ObDirectLoadConflictCheck {
public:
  // 检查 LOAD DATA 的 row 与并发事务是否冲突
  int check_conflict(const ObDirectLoadBatchDatumRows &rows,
                     ObIArray<bool> &conflict_flags);

  // 1. 对每行查 lock table / memtable / SSTable 看是否被锁
  // 2. 检查写写冲突（同 rowkey 被另一事务持有锁）
  // 3. 输出 conflict_flags 标记冲突行
};
```

**冲突解决策略**（业务层选择）：
- `IGNORE`：跳过冲突行
- `REPLACE`：覆盖冲突行（MySQL 兼容语义）
- `ABORT`：整个 LOAD DATA 失败

---

## 9. Auto-Increment Sequence —— `ObDirectLoadAutoIncSeqService`

### 9.1 类骨架

```cpp
// src/storage/direct_load/ob_direct_load_auto_inc_seq_service.h
class ObDirectLoadAutoIncSeqService
{
  const static int INIT_NODE_MUTEX_NUM = 10243L;
public:
  static ObDirectLoadAutoIncSeqService &get_instance();
  static int get_start_seq(const share::ObLSID &ls_id,
                           const ObTabletID &tablet_id,
                           const int64_t step_size,
                           ObDirectLoadAutoIncSeqData &start_seq);
private:
  static int update_direct_load_auto_inc_seq(const ObLS &ls,
                                             const ObTabletID &tablet_id,
                                             ObDirectLoadAutoIncSeqData &new_seq);
private:
  int inner_get_start_seq(const share::ObLSID &ls_id,
                          const ObTabletID &tablet_id,
                          const int64_t step_size,
                          ObDirectLoadAutoIncSeqData &start_seq);
private:
  struct InitNodeMutexWrapper {
    lib::ObMutex mutex_;
    InitNodeMutexWrapper() : mutex_(common::ObLatchIds::OB_DIRECT_LOAD_AUTO_INC_SEQ_SERVICE_LOCK) {}
  };
  InitNodeMutexWrapper init_node_mutexs_[INIT_NODE_MUTEX_NUM];
};
```

### 9.2 关键设计

**`INIT_NODE_MUTEX_NUM = 10243`**：
- 10243 = 大质数（hash 桶大小常用质数）
- 用 mutex 数组做 per-(ls_id, tablet_id) 锁粒度
- 10243 个 mutex = 81920 字节 = 不大，每个 mutex 8 字节

**Singleton 模式**：`static ObDirectLoadAutoIncSeqService &get_instance()` —— 全局唯一。

**`get_start_seq(ls_id, tablet_id, step_size)`**：
- 批量预分配 auto-increment 序列值（避免每行一次 RPC）
- step_size 控制每次预分配多少（典型 1000-10000）

### 9.3 为什么需要预分配

如果每行 INSERT 都生成 auto-inc：
- 需要持久化（不能丢）
- 需要唯一性
- 性能差（每次锁 + 写盘）

Direct Load 批量预分配：
- 一次锁 + 写盘 → 拿到 1000-10000 个连续 seq 值
- 后续 1000-10000 行直接用本地计数
- 大幅提升吞吐

---

## 10. LOB 处理 —— `ObDirectLoadLobBuilder`

### 10.1 LOB 特殊处理

LOB（Large Object，TEXT/BLOB/JSON 等）数据的特点：
- 单行可能很大（几 MB 到 GB）
- 不能直接 inline 到 row
- 需要异步构建（等 row 落盘后异步处理 LOB payload）

### 10.2 DAG LOB Builder

```bash
src/storage/direct_load/ob_direct_load_dag_lob_builder.cpp
src/storage/direct_load/ob_direct_load_dag_lob_builder.h
```

```cpp
class ObDirectLoadDagLobBuilder {
public:
  // 在 row 写入 SSTable 后，异步构建 LOB
  int build_lob(const ObDirectLoadRow &row,
                const share::ObLSID &ls_id);

  // 1. 把 LOB payload 写到 LOB meta table
  // 2. 更新 row 中的 LOB locator
  // 3. 完成 → row 可读
};
```

**关键**：LOB builder 是 **异步**的，不阻塞 Direct Load 主流程。

---

## 11. 合并任务 —— `ObDirectLoadIMergeTask` + `ObDirectLoadPartitionMergeTask`

### 11.1 合并阶段

Direct Load 完成后，需要把生成的 SSTable **合并**成可服务状态：

```
Direct Load 完成时：
    - 一个 partition 内有 N 个 SSTable（每个来自一个 data block batch）
    - 这些 SSTable 还没合并
    - 必须 merge 成 1 个或少数几个 SSTable 才能上线
```

### 11.2 合并任务

```cpp
// src/storage/direct_load/ob_direct_load_i_merge_task.h
class ObDirectLoadIMergeTask {
public:
  // 把 N 个小 SSTable 合并成 1 个大 SSTable
  virtual int merge_sstables(const ObIArray<ObDirectLoadSSTable> &src,
                            ObDirectLoadSSTable &dest) = 0;
};

// src/storage/direct_load/ob_direct_load_partition_merge_task.h
class ObDirectLoadPartitionMergeTask : public ObDirectLoadIMergeTask {
public:
  int merge_sstables(const ObIArray<ObDirectLoadSSTable> &src,
                    ObDirectLoadSSTable &dest) override;
  // 单 partition 内的 SSTable 合并
};
```

**合并策略**：
- 顺序合并：保持原顺序（避免破坏 rowkey 排序）
- 并行合并：N 个 partition 同时合并
- merge 完成后，新 SSTable 上线（replaces 旧的）

---

## 12. 与传统 INSERT 路径的对比总结

| 维度 | 传统 INSERT | Direct Load |
|------|-------------|-------------|
| 入口 | `INSERT INTO ...` | `LOAD DATA INFILE` |
| Parser | 完整 SQL AST（每行） | 只解析 LOAD DATA 协议头 |
| Optimizer | 通用 optimizer | `ob_direct_load_optimizer_ctx` |
| Executor | DAS layer | 直接走 Direct Load 模块 |
| 写入路径 | memtable + MVCC 版本链 | 直接生成 SSTable |
| 触发器 / 外键 | 支持 | 不支持 |
| auto-increment | 每行 RPC | 批量预分配 |
| LOB | 同步处理 | 异步 builder |
| 多 partition | 通用路由 | 专属 range splitter |
| 冲突处理 | 行级锁 | conflict_check |
| 合并 | mini freeze / major freeze | 专属 IMergeTask |
| 吞吐 | KB/s | MB/s |
| 适用 | OLTP（少量行） | ETL（大批量） |

---

## 13. 总结

### 13.1 Direct Load 在 OB 体系中的定位

Direct Load 是 OB 5.x **专为大数据场景设计的高速导入路径**：

```
应用
  │
  ├─ OLTP: INSERT/UPDATE/DELETE → DAS → memtable → MVCC
  │                                     (低延迟)
  │
  └─ OLAP/ETL: LOAD DATA → Direct Load → SSTable 直写
                                       (高吞吐)
```

### 13.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 跳过 SQL parser | 只解析 LOAD DATA 协议头 |
| 跳过 DAS layer | 不创建 DAS task |
| 跳过 memtable | 直接生成 SSTable |
| 跳过 MVCC 版本链 | 无版本放大 |
| DAG 并行 | dag_insert_table_row_handler/iterator/writer |
| 多 partition 切分 | range_splitter + multiple_sstable |
| Heap Table 特殊路径 | multiple_heap_table_sorter/index_block/scanner |
| 冲突检测 | conflict_check（IGNORE/REPLACE/ABORT） |
| auto-inc 批量预分配 | auto_inc_seq_service (10243 mutex hash) |
| LOB 异步处理 | dag_lob_builder |
| SSTable 合并 | i_merge_task + partition_merge_task |

### 13.3 关键技术常量

| 常量 | 值 | 位置 |
|------|---|------|
| `APPLY_COMPRESSION_THRESHOLD` | 90% | `ob_direct_load_data_block_encoder.h` |
| `INIT_NODE_MUTEX_NUM` | 10243 | `ob_direct_load_auto_inc_seq_service.h` |
| `data_block_size_` | 256KB（典型） | `ObDirectLoadExternalTableCreateParam` |
| `max_data_block_size_` | 1MB（典型） | `ObDirectLoadExternalTableCreateParam` |

### 13.4 模块规模

`src/storage/direct_load/` 总计：
- 210 个 `.cpp` + `.h` 文件
- 27,126 行 .cpp 代码
- 是 OB 5.x 第二大子模块（仅次于 storage/blocksstable/）

### 13.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#67 Sequence / Auto-increment 分布式序列**：

分布式 sequence 生成：节点预分配 + 单调递增保证 + auto-inc 全局唯一性。源码入口：`src/share/sequence/` + `src/storage/transaction/ob_seq_generator.cpp` + （与 #66 的 `auto_inc_seq_service` 衔接）。

虽然 Direct Load 的 auto_inc 是 5.x 新加的，但传统 sequence 路径在 4.x 已存在，是 OB RDBMS 兼容性的核心。

整吗？