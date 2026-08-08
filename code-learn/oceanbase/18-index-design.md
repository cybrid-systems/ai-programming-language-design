# #18 v2 — Index Design (Clustered + Secondary + Functional)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")

> 接续 #14 v2 / #15 v2 / #16 v2：MemTable + ObKeyBTree + ObMvccHashIndex 三件套已经
> 把"在内存里怎么排"讲清楚。#18 v2 把视角抬到"在 OB 整个表/查询系统里,索引
> 是什么 / 怎么用 / 怎么维护 / 怎么被优化器选 / 怎么扛住 MVCC / 怎么支持表达式"。

---

## 0. 全文导读

索引在 OB 里有四种身份:

| 身份 | 关键结构 | 物理路径 | 用途 |
|------|----------|----------|------|
| **Clustered Index** | primary key → rowptr | `ObKeyBTree` (MemTable) → SSTable (block cache) | 主表存储;没有"主表堆",索引就是表 |
| **Secondary Index (local)** | (idx_keys, pk) → rowptr | 同上,索引列 + PK 列拼接成 key | 单分区 lookup;`INDEX BACKUP` 不需要 |
| **Secondary Index (global)** | (idx_keys, pk) → rowptr | 每个 partition 一棵独立 index tree | 跨分区 lookup,需要 `INDEX BACKUP` |
| **Functional Index** | expr(col) → pk → rowptr | 同 secondary,但 key 是表达式结果 | `WHERE LOWER(name) = 'x'` 走索引 |

四种身份的 storage 层是 **同一套机制**:都是 row → (ObKeyBTree + ObMvccHashIndex in
MemTable) → (micro_block + bloom_filter + B-tree in SSTable)。区别只在
**key 的构造** 和 **optimizer 是否选它**。本文按这个统一视角拆。

---

## 1. Clustered Index — 主表就是索引

### 1.1 设计动机

传统 RDBMS 是"堆表 + 索引":`data page` 存 row,`index page` 存 (key, rowid)。查
询 `WHERE pk = X` 要先走索引拿 rowid,再去堆表 fetch row——两次 IO。

OB 反过来:**主键就是 row 的物理位置**。没有堆表,`pk` 直接定位到 `rowptr`,一次
IO 拿到完整 row。这是"index-organized table"的思路,和 InnoDB clustered
index 同构。

```cpp
// src/storage/blocksstable/ob_data_block_store.h:200
// 主表 block 的 key 永远是 PK,没有"data page"这个概念
class ObDataStoreMeta {
  // ... 没有 row_id_; PK 就是行标识
};
```

### 1.2 PK 的形态

OB 的 PK 不限于单列。任何 `UNIQUE NOT NULL` 的列(或列组合)都能当 PK。`CREATE
TABLE t (a INT, b INT, PRIMARY KEY (a, b))` —— PK 是 `(a, b)` 复合键。

```cpp
// src/share/schema/ob_table_schema.h:500
class ObTableSchema {
  // 主键 schema:column 数组,长度 1-N
  common::ObSEArray<ObColumnSchemaV2 *, 1> pk_columns_;
};
```

复合 PK 的存储顺序是列定义顺序,不是声明顺序——所以 `(a, b)` 和 `(b, a)` 是不同
的 clustered key,查询时必须按相同顺序。

### 1.3 Clustered Key 编码

和 #14 v2 / #15 v2 描述的一致:PK → rowkey 编码走 `ObRowkeyHelper` / `ObObj` 序
列化。

```cpp
// src/storage/ob_rowkey_helper.h:80
class ObRowkeyHelper {
public:
  // 把 row 的 PK 部分序列化成 byte stream
  static int encode_rowkey(const ObRow &row, const common::ObRowkeyInfo &info,
                            common::ObString &encoded);
  // 反向
  static int decode_rowkey(const common::ObString &encoded,
                            const common::ObRowkeyInfo &info, ObRow &row);
};
```

编码细节:
- 每列先写 1 字节 type tag(对应 `ObObjType`),再写定长或变长 payload
- NULL 列:写 `ObObj::MIN_OBJECT_VALUE`(哨兵,小于任何正常值)——保证 NULL 在
  ASC 排序时排第一,符合 SQL 语义
- VARCHAR/TEXT:长度前缀(varint)+ UTF-8 bytes
- NUMBER/DECIMAL:twos-complement big-endian

> **v2 洞察**:NULL 哨兵用 `MIN_OBJECT_VALUE` 而不是 `MAX_OBJECT_VALUE`——因为 OB
> 默认 ASC,DESC 时 `MAX_OBJECT_VALUE` 才是 NULL 哨兵。`MIN`/`MAX` 是同一
> 个 `ObObj` 类型的两个极端值,不是 `nullptr`,所以可以安全参与排序和范围
> 扫描。

### 1.4 Clustered Key 的存储路径

```
INSERT (PK=42, a=1, b=2)
    │
    ↓ encode_rowkey
key = [type_tag=INT, payload=42, 0x00_terminator]
    │
    ↓
MemTable.insert(key, [mvcc_row_t{tx_id=base, version=0, row_data={a:1, b:2}}])
    │
    ├─→ ObKeyBTree.insert(key, mvcc_row)
    └─→ ObMvccHashIndex.insert(key_hash, mvcc_row)
```

MemTable flush 时:
```
MemTable.freeze()
    │
    ↓ 序列化每行 → SSTable
SSTable (range-partitioned by PK)
    ├─ block 0: PK [0, 1000)
    ├─ block 1: PK [1000, 2000)
    └─ ...
```

读路径:`SELECT * WHERE pk = 42` → 先查 MemTable(BTree + HashIndex)→ 没命中再
查 SSTable(每 block 内 binary search on PK)→ 命中后返回 row。

---

## 2. Secondary Index — 索引也是"另一张表"

### 2.1 Local vs Global

OB 二级索引分两种:

| 类型 | 范围 | 实现 | 备份 |
|------|------|------|------|
| **Local** | 单 partition 内唯一 | 每 partition 一棵独立 index tree | 随主表 partition 备份 |
| **Global** | 全表唯一 | 每个 partition 持有一部分 index entries | 需要单独 `INDEX BACKUP` |

Local 索引是默认的(创建时无 `GLOBAL` 关键字)。它和主表一样 partition——同一
个 partition 的 secondary index 跟着主表一起迁移、rebalance。

Global 索引把整个索引按 PK 范围切片,每个 partition 持有一部分。优点是单点查询
不用走所有 partition;缺点是写入要扇出到目标 partition,rebalance 时要重新切
片。

### 2.2 Secondary Key 编码

Secondary index 的 key 是 **`(index_cols..., pk_cols...)`**——索引列在前,PK
列在后。PK 列附加是为了保证唯一性(因为 index 列本身可能不唯一)。

```cpp
// src/storage/access/ob_index_info.h:120
class ObIndexInfo {
public:
  // 索引列定义(含 PK 后缀)
  const common::ObIArray<ObColumnSchemaV2 *> &get_index_columns() const {
    return index_columns_;
  }
  // 索引列的 rowkey 描述
  const common::ObRowkeyInfo &get_index_rowkey_info() const {
    return index_rowkey_info_;
  }
};
```

例子:`CREATE INDEX idx1 ON t (a);` 且 PK 是 `(id)`:
- index key = `(a, id)`
- value = rowptr(指向主表 cluster key = `(id)` 的位置)

查询 `SELECT * FROM t WHERE a = 5`:
1. 走 idx1 拿所有 `a=5` 的 entry,得到 PK 列表 `(id_1, id_2, ...)`
2. 用 PK 列表回表(走 clustered index)拿完整 row

### 2.3 为什么 PK 必须附加

考虑 `CREATE TABLE t (id PK, a INT, INDEX(a))` 插入两行 `(id=1, a=5)` 和
`(id=2, a=5)`:
- idx1 key = `(5, 1)` 和 `(5, 2)`
- 两行 a 列相同,但 PK 不同 → idx1 中两个独立 entry
- 没有 PK 后缀就分不清这两行

PK 后缀同时让 secondary index 自身也支持 `ORDER BY a, id` 和 `RANGE
SCAN(a=[5,5])`——索引列相同时按 PK 顺序,这是 SQL 标准的稳定排序。

### 2.4 Covering Index(覆盖索引)

如果查询只涉及索引列,**不需要回表**:

```sql
CREATE INDEX idx2 ON t (a, b);
SELECT a, b FROM t WHERE a = 5;  -- 不需要回表,idx2 直接返回 a, b
SELECT a FROM t WHERE a = 5;    -- 同上,但只读 a 列
```

OB 优化器识别"covering"——把这类查询标记为 "index only scan",不需要拿到
rowptr。Storage 层会跳过 clustered index 的二次查询。

```cpp
// src/sql/optimizer/ob_log_index_scan.cpp:200
// 优化器判断 covering
bool ObLogIndexScan::is_index_only_scan() const {
  return get_column_items().count() == get_index_columns().count()
         && !need_fetch_other_tables();
}
```

> **v2 洞察**:covering index 不只是优化——它直接改变了执行路径。Storage 层
> 在 index scan 时会"projection pushdown",只 deserialize 索引列,跳过主表
> 的反序列化。`a INT` 不读主表 vs. 读主表,deserialization CPU 差 5-10x。

---

## 3. Functional Index(表达式索引)

### 3.1 定义

```sql
CREATE INDEX idx_lower_name ON t (LOWER(name));
SELECT * FROM t WHERE LOWER(name) = 'alice';  -- 走 idx_lower_name
```

索引列是**表达式结果**,不是原始列。

### 3.2 表达式存储

```cpp
// src/share/schema/ob_index_schema.h:60
class ObIndexSchema {
public:
  // 索引列的表达式定义(可能是简单列引用,也可能是函数调用)
  const ObIArray<ObColumnSchemaV2 *> &get_index_columns() const {
    return index_columns_;
  }
  // functional index 的表达式 AST
  const ObIArray<ObRawExpr *> &get_func_exprs() const {
    return func_exprs_;
  }
};
```

写入时:对每行计算 `LOWER(name)` → 把结果当作普通索引列值,encode 进 secondary
key。

读取时:优化器把查询的 `LOWER(name) = 'alice'` 改写成 `index_expr = 'alice'`(因
为表达式一致),触发索引扫描。

### 3.3 表达式一致性约束

Functional index 的"功能正确性"取决于**写入和查询的表达式必须语义一致**。如
果用户写 `CREATE INDEX ... (LOWER(name))` 但查询用 `WHERE LCASE(name)`,优化
器认不出,会走全表扫描。

OB 的折中:表达式字符串化 + 规范化(忽略大小写、空白)+ AST 比较。只要 `LOWER`
和 `lcase` 在同一个 alias 表里,就视为一致。

```cpp
// src/sql/optimizer/ob_optimizer_util.cpp:1500
bool ObOptimizerUtil::is_same_func_expr(const ObRawExpr *e1, const ObRawExpr *e2) {
  // 递归比较 AST 节点;对 function call 走 alias 表
  // 对 column ref 走 column id(不靠名字)
}
```

> **v2 洞察**:functional index 的"陷阱"是**表达式漂移**——schema 改了(比如
> `name VARCHAR(100)` → `VARCHAR(200)`),索引表达式结果不变,但 optimizer 的
> AST 比较可能因为类型转换节点变化而失败。OB 走"列 id"而不是"列名",所
> 以 `ALTER TABLE ... MODIFY COLUMN name VARCHAR(200)` 不会破索引——只要
> 类型兼容性规则一致。

---

## 4. 索引的存储层细节(接 #14/#15/#16 v2)

### 4.1 MemTable 中的索引 entry

每个二级索引在 MemTable 里有自己的 `ObKeyBTree` + `ObMvccHashIndex` 实例。和
主表的区别只有**key 编码不同**——主表是 PK,二级索引是 `(index_cols,
pk_cols)`。

```cpp
// src/storage/memtable/ob_memtable.h:300
class ObMemtable {
  // 主表 + 所有 secondary indexes 的 storage
  ObKeyBtree memtable_keybtree_;            // 主表
  ObMvccHashIndex memtable_mvcc_hash_;      // 主表 hash
  // 每个二级索引一组
  hash::ObHashMap<uint64_t, ObKeyBtree *> secondary_keybtrees_;
  hash::ObHashMap<uint64_t, ObMvccHashIndex *> secondary_hash_indexes_;
};
```

每个 secondary index 用 `index_id` 作为 map key。`index_id` 是 schema 级唯
一,跨 partition 不重复。

### 4.2 SSTable 中的索引 entry

SSTable 不区分主表 / 二级索引——都是 `key → row data` 的有序存储。区别只在
**micro_block_header** 标记这是哪个 index:

```cpp
// src/storage/blocksstable/ob_micro_block_header.h:50
class ObMicroBlockHeader {
  uint16_t index_id_;       // 哪个索引
  uint8_t table_id_index_;  // 主表/二级索引的 sub-table id
  // ...
};
```

读 SSTable 时,先看 header 的 `index_id` 决定要不要这个 block——多 index 共存
一个 SSTable 时(shared storage 模式)节省 IO。

### 4.3 Bloom Filter(每 micro_block)

每个 micro_block 自带 bloom filter,用于 `WHERE pk = X` 的快速"不在此 block"
判定。

```cpp
// src/storage/blocksstable/ob_micro_block_hash_index.h:80
class ObMicroBlockHashIndex {
  // 每 32 行一个 bloom filter entry
  // 命中率 ~99% (PK 唯一场景),大幅减少 block 内 scan
};
```

二级索引的 bloom filter 用 index key 的 hash 而不是 PK 的 hash——所以
`WHERE a = 5` 查 idx1 时,bloom filter 直接淘汰 99% 不相关的 micro_block。

> **v2 洞察**(接 #15 v2):bloom filter 是 micro_block 级,不是 SSTable 级。每
> 个 SSTable 有 ~1000 个 micro_block,每个 micro_block 有自己的 bloom。一
> 次 `WHERE a = 5` 查 idx1 在 100GB SSTable 上:先按 index range 找到 ~1000
> 个 SSTable,每个 SSTable 拿 ~100 个 micro_block,bloom filter 砍掉 99,只剩 1
> 个 block 进 deserialization。总 IO:`1000 * (1 block read + 99 bloom
> check)` ≈ 1MB IO,而不是 100GB。

---

## 5. Index Lookup Path(查询端)

### 5.1 优化器层

```sql
SELECT * FROM t WHERE a = 5;
```

走 ObLogPlan → ObLogTableScan / ObLogIndexScan 的选择:

```cpp
// src/sql/optimizer/ob_log_plan.cpp:3000
int ObLogPlan::generate_table_plan() {
  // 1. 收集候选 indexes (主表 + 所有 secondary)
  ObSEArray<ObIndexInfo *> candidates;
  collect_candidate_indexes(candidates);
  // 2. 对每个 candidate 算 cost
  for (ObIndexInfo *idx : candidates) {
    double cost = compute_index_cost(idx, query);
    // 3. 选 cost 最小的,加上 "回表 cost" 如果不是 covering
    if (!is_covering(idx, query)) {
      cost += compute_table_lookup_cost(idx);
    }
  }
  // 4. 输出最优 plan
}
```

`compute_index_cost` 包含:
- index range scan cost(行数 × micro_block IO)
- bloom filter 命中率(估算 false positive rate)
- memory cost(如果是 in-memory)
- 维护 cost(最近写放大)

### 5.2 执行层:Index Scan Operator

选完 plan 后,`ObIndexScanOp` 拿到 `ObIndexInfo` + range,执行:

```cpp
// src/sql/engine/ob_physical_plan.cpp:2500
class ObIndexScanOp : public ObTableScanOp {
public:
  virtual int inner_open() override {
    // 1. 准备 index range (start_key, end_key)
    ObDatumRange range;
    build_index_range(range_);
    // 2. open storage iterator
    storage_iter_.open(table_param_, range_);
    // 3. 对每行:deserialise → evaluate filter → output
    return OB_SUCCESS;
  }
  virtual int inner_get_next_row() override {
    while (OB_SUCC(storage_iter_.get_next_row(row))) {
      // 过滤
      if (!filter_.eval(row)) continue;
      // 回表(如果不是 covering)
      if (!is_covering_) {
        table_iter_.seek(row.pk_);
        table_iter_.get_next_row(full_row_);
      }
      return OB_SUCCESS;
    }
    return OB_ITER_END;
  }
};
```

回表是"按 PK 单独查询",不是 "join"——所以每行回表是一次独立的
`WHERE pk = X` 查询,走主表的 MemTable + SSTable 路径。

### 5.3 Index Merge(索引合并)

OB 支持"多个二级索引 OR 合并":

```sql
SELECT * FROM t WHERE a = 5 OR b = 7;
```

优化器识别可合并的多个 index,生成 `INDEX MERGE` plan:

```cpp
// src/sql/optimizer/ob_log_index_merge.cpp:100
class ObLogIndexMerge : public ObLogSet {
  ObSEArray<ObLogIndexScan *> index_scans_;  // 每个子条件一个 index scan
};
```

执行层用 heap merge:每个 child 给一个有序 rowid 流,merge 出 PK 去重集合,再回
表。代价模型和单 index 不同——merge cost = sum(child cost) + heap merge cost +
dedup cost。

> **v2 洞察**:INDEX MERGE 在 OB 里是"plan-level 优化",不是"execution-level 优
> 化"。优化器先决定要不要 merge,执行层只是按 plan 跑。所以 merge 的可行
> 性受优化器的 index 选择能力限制——如果优化器没识别到 `a=5 OR b=7` 的
> index 可用性,merge 不会发生,fallback 到全表扫描。

---

## 6. Index Maintenance(DML 端)

### 6.1 INSERT 触发

```sql
INSERT INTO t (id, a, b) VALUES (1, 5, 'x');
```

事务层要做 N+1 次写(主表 1 次,每个 secondary index 1 次):

```cpp
// src/storage/transaction/ob_trans_service.cpp:1500
int ObTransService::insert_row(ObTxDesc &tx, const ObTableOp &op) {
  // 1. 写主表
  memtable_.insert(pk, mvcc_row, tx_id);
  // 2. 写每个 secondary index
  for (ObIndexInfo *idx : table_schema.indexes_) {
    ObString idx_key = encode_index_key(idx, row);  // (idx_cols, pk_cols)
    memtable_.insert(idx_key, mvcc_row, tx_id);     // 同一行,不同 key
  }
  // 3. 返回成功(实际 commit 时才持久化)
}
```

**一致性**:如果中途失败,需要回滚——但 MVCC 的好处是"单行失败不影响其他
行"。OB 用 per-row undo log,失败的 row 不影响主表和已成功的 index entries(它
们会被 GC)。

### 6.2 DELETE 触发

DELETE 不会物理删除——按 #1-#5 v2 描述,加 `delete_version` 标记:

```cpp
// src/storage/ob_dml_handler.cpp:300
int ObDMLHandler::delete_row(...) {
  // 主表:row 上加 delete_version = tx.read_version
  memtable_.update(pk, mvcc_row_with_delete, tx_id);
  // secondary:同样的 delete_version 加到 index entry 的 mvcc_row
  for (ObIndexInfo *idx : table_schema.indexes_) {
    memtable_.update(idx_key, mvcc_row_with_delete, tx_id);
  }
}
```

物理删除发生在 compact 时——compact 把 `delete_version < oldest_active_tx` 的
row 直接丢弃,腾出空间。

### 6.3 UPDATE 触发

UPDATE 拆成 DELETE + INSERT(因为 row key 可能变化)——除非 update 的列都不在任
何 index 里,才走原地 update:

```cpp
// src/storage/ob_dml_handler.cpp:500
int ObDMLHandler::update_row(...) {
  // 判断:是否影响 index?
  bool affects_index = false;
  for (ObIndexInfo *idx : table_schema.indexes_) {
    if (idx->includes_any(updated_columns)) {
      affects_index = true;
      break;
    }
  }
  if (affects_index) {
    // DELETE old row + INSERT new row
    delete_row(...);
    insert_row(...);
  } else {
    // 原地 update(只改 data,不改 key)
    memtable_.update(pk, new_mvcc_row, tx_id);
  }
}
```

> **v2 洞察**:"影响 index" 的判定基于**列 id**,不是列名。所以 `UPDATE t SET
> a = a + 1` 当 `idx1` 包含 `a` 时,会触发 DELETE+INSERT 而不是原地 update。这
> 是 secondary index 的代价——但 MVCC 的好处是 DELETE 和 INSERT 是原子的(同
> 一事务内可见),失败可以一起回滚。

---

## 7. Index 与 MVCC 的耦合(接 #1-#5 v2)

### 7.1 二级索引的版本化

每个 secondary index entry 也带 `mvcc_row_t`(不是简单的 `(key, rowptr)`):

```cpp
// src/storage/access/ob_index_info.h:200
// 二级 index entry 的 value
struct ObIndexEntry {
  ObRowkey index_key;       // (idx_cols, pk_cols)
  memtable::ObMvccRow mvcc_row;  // 不是 rowptr,是 row 本身
};
```

为什么不用 rowptr?因为 rowptr 不稳定——compact 后 rowptr 会变。但 secondary
index 需要"stable pointer"指向主表行,所以直接存 row 数据(denormalize)。

代价:写放大。每个 row 在 N 个 index 里被存 N 次。读放大也类似:回表时拿到
rowptr 后,实际数据已经在 secondary index 里。

### 7.2 Index GC

Compact 时,secondary index entry 也参与清理:

```
compact_worker.run():
  for each SSTable (sorted by PK):
    for each row:
      if row.delete_version < oldest_active_tx:
        跳过(GC 掉)
      else:
        保留
    for each secondary_index entry:
      if entry.mvcc_row.delete_version < oldest_active_tx:
        跳过
      else:
        保留
```

二级 index 的 GC 比主表"贵"——因为每个 index entry 的 mvcc_row 是完整 row
数据,deserialization + 判断 + 重新 encode 比主表复杂。

### 7.3 Snapshot Isolation 与 Index

`SELECT ... WHERE a = 5` 在 read-committed 下:
- 事务 start → 拿 read_version
- 走 idx1:每行看 `mvcc_row.commit_version <= read_version && delete_version > read_version`
- 匹配则返回

二级 index 不需要"快照"——index 本身就是 per-row versioned,scan 时逐行判定可
见性。这是 OB 的设计精髓:index 不引入额外的一致性机制,直接复用 MVCC 行
版本。

---

## 8. Skip Scan(索引跳跃扫描)

### 8.1 优化场景

```sql
CREATE INDEX idx_a ON t (a);
SELECT * FROM t WHERE a IN (1, 2, 3, ..., 100);
SELECT DISTINCT a FROM t;
```

前导列 `a` 基数低,完全扫描 index 浪费——只查 distinct 值更高效。

### 8.2 OB 实现

OB 优化器识别"前导列低基数" + "IN-list / DISTINCT",生成 skip scan plan:

```cpp
// src/sql/optimizer/ob_log_index_skip_scan.cpp:60
class ObLogIndexSkipScan : public ObLogIndexScan {
  // 不一次性 scan 整个 index
  // 1. 先 distinct 前导列值,得到 distinct_a_values_ = [1, 2, 3, ...]
  // 2. 对每个 distinct_a,做 range scan: WHERE a = X AND ...
};
```

代价模型:
- skip scan cost = distinct_count × (range_scan cost per distinct value)
- 对比全 index scan cost = total_rows × per_row_cost
- 当 distinct_count << total_rows,skip scan 更优

> **v2 洞察**:skip scan 在 OB 里是"启发式 + 代价估算"双触发。不是所有低基数
> 列都 skip scan——比如 `a IN (1, 2)`(只有 2 个值),代价估算会发现"逐个
> range scan 的 overhead 比全 index scan 还高",不会触发 skip scan。触发
> 条件是 `distinct_count × range_scan_cost < total_rows × per_row_cost`。
> 在 100GB 表 + `a` 有 10000 个 distinct 值场景,skip scan 可以把 100GB IO
> 降到 ~10GB。

---

## 9. 索引统计信息

### 9.1 收集

OB 维护每张表的统计信息(`histogram`, `ndv`, `null_count`, `min/max`):

```cpp
// src/share/stat/ob_stat_manager.h:80
class ObStatManager {
public:
  // 周期性收集 + on-demand 收集
  int gather_table_stats(uint64_t table_id);
  int gather_index_stats(uint64_t index_id);
};
```

### 9.2 在 CBO 中的角色

```cpp
// src/sql/optimizer/ob_optimizer_stats.cpp:200
double ObOptStat::estimate_row_count(const ObRawExpr &filter, const ObIndexInfo &idx) {
  // 1. 拿 filter 列的 histogram
  // 2. 算 selectivity (用 histogram 桶插值)
  // 3. row_count = table_rows × selectivity
  // 4. 返回 cost
}
```

索引选择高度依赖 stats 准确性。`ANALYZE TABLE t` 强制重收 stats;OB 默认
`major freeze` 后自动 gather。

> **v2 洞察**(接 #29 v2 Slow Query):"为什么我的 query 慢?" 80% 是索引选错,
> 索引选错的 80% 是 stats 过时。`ANALYZE TABLE` 是 99% 调优的第一步——比
> 加索引还优先。

---

## 10. 索引的代价与权衡

### 10.1 写放大

每加一个 secondary index:
- INSERT:多一次 MemTable 写 + 一次 SSTable 写(flush 时)
- UPDATE:如果更新列在 index 里,DELETE + INSERT 双倍写
- DELETE:多一次 update(delete_version)

N 个 index = N 倍写放大。

### 10.2 空间放大

每个 secondary index 存完整 row 数据(denormalize)。N 个 index = N 倍空间(非
常粗略——具体看 row 大小和 index 列数)。

### 10.3 何时不加索引

- **写多读少**:每次 INSERT 都要写 N 个 index,得不偿失
- **低选择性列**:`WHERE gender = 'M'`(50% 选择性)走 index 比全表扫描更慢
- **小表**:`< 1000 行`,index 没意义,优化器会忽略
- **频繁 DDL 的表**:每次 schema 变更可能要 rebuild index,代价大

### 10.4 何时加索引

- **高选择性列**:`WHERE user_id = 12345`(0.001% 选择性)
- **覆盖查询**:`SELECT a, b FROM t WHERE a = 5` — index 同时是数据
- **ORDER BY 列**:`ORDER BY create_time` —— 避免 filesort
- **JOIN 列**:`t1 JOIN t2 ON t1.id = t2.t1_id` —— NL join 的 inner 表 index
  必备

---

## 11. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #18 v2(本文)是一条贯穿 storage / index 主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObMvccHashIndex | hash 实现 | 等值查询优化 + GC 集成 |
| **#18 v2 (本文)** | **Index Design** | **索引系统** | **clustered/secondary/functional + CBO + MVCC** |

这四篇连起来,读者能完整理解 OB 的"数据怎么排 + 怎么查 + 怎么改":

- 写入路径:#14 (MemTable 编码) → #15 (B-tree 插入) → #16 (hash 索引) → #18
  (secondary index propagation)
- 读取路径:#18 (optimizer 选 index) → #15/#16 (MemTable scan) → #14 (SSTable
  fallback) → MVCC visibility (#1-#5)
- 维护路径:DML → #18 (index propagation) → #1-#5 (MVCC versioning) → #16
  (compact GC)

---

## 12. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **#17 v2 Query Optimizer** — CBO 完整实读(cost model + join ordering +
  subquery unnesting)
- **#41 v2 Join Operators** — NL/Hash/Merge Join 实现细节
- **#51 v2 Block Cache** — micro_block cache + bloom_filter cache 深入
- **#29 v2 Slow Query** — slow query 捕获 + 分析 + 索引推荐

继续哪一篇?

---

## 13. 参考(可执行的源码锚点)

- `src/storage/ob_rowkey_helper.h` — PK / index key 编码
- `src/storage/access/ob_index_info.h` — secondary index 描述
- `src/share/schema/ob_index_schema.h` — index schema(含 functional
  expression)
- `src/sql/optimizer/ob_log_index_scan.cpp` — index scan 优化
- `src/sql/optimizer/ob_log_index_merge.cpp` — index merge
- `src/sql/optimizer/ob_log_index_skip_scan.cpp` — skip scan
- `src/sql/optimizer/ob_optimizer_stats.cpp` — stats-based CBO
- `src/storage/ob_dml_handler.cpp` — INSERT/DELETE/UPDATE → index propagation
- `src/storage/transaction/ob_trans_service.cpp` — 事务内多 index 写入
- `src/storage/blocksstable/ob_micro_block_hash_index.h` — bloom filter on
  micro_block

---

#18 v2 完。
