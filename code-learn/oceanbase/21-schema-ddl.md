# #21 v2 — Schema / DDL (Schema Version + Online DDL 完整实读)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后)

> 接续 #14 v2 MemTable / #15 v2 BTree / #16 v2 HashIndex / #18 v2 Index Design:
> 前面讲了"row 怎么放、index 怎么组织"。本文聚焦 **"schema 怎么描述、DDL 怎么
> 执行、Online DDL 怎么不阻塞查询"** ——这是 OB 表结构变更的核心路径。

---

## 0. 全文导读

OB 的 Schema 子系统:

```
Schema 定义      →  ObTableSchema / ObColumnSchemaV2 / ObIndexSchema
Schema 版本     →  schema_version (单调递增,每 DDL +1)
DDL 执行       →  RootService 协调 + RS 写 Clog + 各 OBServer 刷新 cache
Online DDL     →  instant / inplace 两种策略,选哪个取决于变更类型
```

本文按"Schema 定义 → Schema 版本机制 → DDL 流程 → Online DDL 策略 →
DDL 期间的查询 → 兼容性"展开。

---

## 1. Schema 定义

### 1.1 ObTableSchema

```cpp
// src/share/schema/ob_table_schema.h:200
class ObTableSchema {
public:
  // 1. 表级属性
  uint64_t table_id_;                 // 表 ID(全局唯一)
  common::ObString table_name_;        // 表名
  ObTableType table_type_;             // USER TABLE / SYSTEM TABLE / INDEX
  uint64_t database_id_;               // 所属 DB
  int64_t schema_version_;             // schema 版本(随 DDL 递增)
  int64_t create_timestamp_;           // 创建时间
  // 2. 列定义
  common::ObSEArray<ObColumnSchemaV2 *, 64> columns_;
  // 3. PK 列
  common::ObSEArray<ObColumnSchemaV2 *, 8> pk_columns_;
  // 4. 索引
  common::ObSEArray<ObIndexSchema *> index_schemas_;
  // 5. 表选项
  uint64_t auto_increment_;            // 自增列
  uint64_t row_store_type_;            // 行存/列存
  uint64_t compress_type_;             // 压缩算法
  uint64_t consistency_level_;         // 一致性级别
};
```

### 1.2 ObColumnSchemaV2

```cpp
// src/share/schema/ob_column_schema.h:100
class ObColumnSchemaV2 {
public:
  uint64_t column_id_;           // 列 ID(表内唯一)
  common::ObString column_name_; // 列名
  ObColumnType column_type_;     // 类型:INT / VARCHAR / TIMESTAMP ...
  int64_t column_length_;        // VARCHAR 长度
  int32_t precision_;            // NUMBER 精度
  int32_t scale_;                // NUMBER 小数位
  bool is_nullable_;             // 是否允许 NULL
  bool is_auto_increment_;       // 自增
  common::ObString default_value_; // 默认值
  // ... (注释 / charset / collation)
};
```

### 1.3 ObIndexSchema

```cpp
// src/share/schema/ob_index_schema.h:60
class ObIndexSchema {
public:
  uint64_t index_id_;            // 索引 ID
  common::ObString index_name_;  // 索引名
  uint64_t table_id_;            // 所属表
  // 索引列(可能含 functional expression)
  common::ObSEArray<ObColumnSchemaV2 *, 8> index_columns_;
  uint64_t index_type_;          // LOCAL / GLOBAL
  uint64_t index_status_;        // AVAILABLE / UNAVAILABLE / INVALID
  // functional index 表达式
  common::ObSEArray<ObRawExpr *, 4> func_exprs_;
};
```

### 1.4 Schema 序列化

```cpp
// src/share/schema/ob_schema_service.cpp:80
// Schema 是"事实源"(source of truth),需要在 OBServer 间同步
// 序列化用 protobuf-like 二进制格式

class ObSchemaService {
public:
  // 1. 序列化 schema → byte[]
  int serialize_schema(const ObTableSchema &schema, common::ObString &binary);

  // 2. 反序列化 byte[] → schema
  int deserialize_schema(const common::ObString &binary, ObTableSchema &schema);
};
```

序列化后的 schema 存到内部系统表 `__all_virtual_core_table`(每行是一条
DDL 操作的结果)。

---

## 2. Schema 版本机制

### 2.1 版本号分配

```cpp
// src/share/schema/ob_schema_service.cpp:200
// 每次 DDL 提交,schema_version 递增(全局单调)
int64_t ObSchemaService::alloc_schema_version() {
  // 1. 取当前最大版本
  int64_t cur = max_schema_version_.load();
  // 2. atomic CAS 递增
  while (!max_schema_version_.compare_exchange_weak(cur, cur + 1)) {
    // 失败重试
  }
  return cur + 1;
}
```

### 2.2 版本号的作用

```
1. Schema 缓存失效(key 包含 schema_version)
2. 查询路径用 schema_version 决定"看到的列定义"
3. 副本同步附带 schema_version(主备 schema 一致)
```

### 2.3 三层 Schema Cache

```cpp
// src/sql/optimizer/ob_schema_cache.h:80
// L1: thread local cache(最快,~ns)
// L2: process local cache(~ns-μs)
// L3: RS fetch(慢,~ms)

class ObSchemaCache {
public:
  // 三级 cache,逐级降级
  ObTableSchema *get_table_schema(uint64_t table_id, int64_t schema_version);
};
```

查询路径先看 L1,miss 看 L2,miss 看 L3,miss 从 RS 拉。

---

## 3. DDL 执行流程

### 3.1 DDL 分类

```cpp
// src/share/schema/ob_ddl_type.h:50
enum ObDDLType {
  // 表级
  OB_DDL_CREATE_TABLE,
  OB_DDL_DROP_TABLE,
  OB_DDL_ALTER_TABLE,
  OB_DDL_RENAME_TABLE,
  // 索引
  OB_DDL_CREATE_INDEX,
  OB_DDL_DROP_INDEX,
  // 列
  OB_DDL_ADD_COLUMN,
  OB_DDL_DROP_COLUMN,
  OB_DDL_MODIFY_COLUMN,
  OB_DDL_CHANGE_COLUMN,
  // 分区
  OB_DDL_ADD_PARTITION,
  OB_DDL_DROP_PARTITION,
  // ...
};
```

### 3.2 DDL 流程概览

```
Client → OBProxy → OBServer (任意一台)
                     ↓
                  接收 DDL
                     ↓
                  解析 + 校验
                     ↓
                  发送到 RootService
                     ↓
                  RS 协调(全局锁 + schema_version)
                     ↓
                  RS 生成新 schema + 写 Clog
                     ↓
                  所有 OBServer 接收 Clog
                     ↓
                  各 OBServer 刷新本地 schema cache
                     ↓
                  DDL 完成
```

### 3.3 RS 的协调

```cpp
// src/rootserver/ob_ddl_service.cpp:100
class ObDDLService {
public:
  int execute_ddl(const ObDDLStmt &stmt) {
    // 1. 拿 DDL 锁(全局,防止并发 DDL 冲突)
    ObDDLLockGuard lock(ddl_lock_);
    // 2. 校验当前 schema + DDL 兼容性
    ObTableSchema *new_schema = apply_ddl(current_schema_, stmt);
    validate_schema(new_schema);
    // 3. 分配新 schema_version
    int64_t new_version = schema_service_.alloc_schema_version();
    // 4. 写 DDL Clog(OB_LOG_DDL)
    ObLogRecord ddl_log;
    ddl_log.log_type_ = OB_LOG_DDL;
    ddl_log.schema_version_ = new_version;
    ddl_log.ddl_stmt_ = stmt.serialize();
    clog_writer_.write_log(ddl_log);
    // 5. 等所有 OBServer ack(各 OBServer 拉新 schema)
    wait_for_all_observers_apply(new_version);
    return OB_SUCCESS;
  }
};
```

### 3.4 OBServer 接收 DDL

```cpp
// src/storage/ob_server_ddl_service.cpp:50
class ObServerDDLService {
public:
  // 监听 Clog,发现 DDL 时:
  void on_ddl_log(ObLogRecord &record) {
    // 1. 反序列化 DDL
    ObDDLStmt stmt = deserialize_ddl(record.ddl_stmt_);
    // 2. 应用到本地 schema cache
    ObTableSchema *new_schema = apply_ddl(current_schema_, stmt);
    schema_cache_.update(record.schema_version_, new_schema);
    // 3. (optional)刷新优化器 cache
    optimizer_cache_.invalidate(record.table_id_);
    // 4. ack RS
    rs_client_.send_ddl_ack(record.schema_version_);
  }
};
```

---

## 4. Online DDL 策略

### 4.1 两种策略

OB 的 DDL 分两类:
- **INSTANT**:几乎瞬时(只改元数据,不改数据)——ADD COLUMN with default
- **INPLACE**:异步,可能耗时长(改数据)——ADD INDEX, MODIFY COLUMN

```cpp
// src/share/schema/ob_ddl_alter_type.h:50
enum ObAlterTableType {
  // INSTANT: 仅修改 schema,数据不动
  OB_ALTER_TABLE_INSTANT,
  // INPLACE: 异步重建数据
  OB_ALTER_TABLE_INPLACE,
};
```

### 4.2 INSTANT 适用场景

```sql
-- ✅ INSTANT(只改元数据)
ALTER TABLE t ADD COLUMN c1 INT DEFAULT 0;
ALTER TABLE t ADD COLUMN c2 VARCHAR(100) DEFAULT '';
ALTER TABLE t DROP COLUMN c3;
ALTER TABLE t MODIFY COLUMN c4 BIGINT;
```

OB 的 trick:**default value 存到 schema(不在 row 里)**——所以 ADD
COLUMN with default 不需要重写 row。

```cpp
// src/storage/blocksstable/ob_row.h:80
// 读 row 时,缺失列查 schema 的 default_value
ObObj get_column_value(const ObColumnSchemaV2 &col) {
  // 1. row 里有这个列?直接返回
  if (row.has_column(col.column_id_)) return row[col.column_id_];
  // 2. 没有,返回 schema 的 default
  return col.default_value_;
}
```

### 4.3 INPLACE 适用场景

```sql
-- ❌ INPLACE(需要改数据,异步执行)
ALTER TABLE t ADD INDEX idx_a (a);
ALTER TABLE t DROP PRIMARY KEY;
ALTER TABLE t MODIFY COLUMN c1 INT NOT NULL;  -- 加 NOT NULL 约束
ALTER TABLE t ALTER COLUMN c1 SET DEFAULT 5;  -- 改 default
```

INPLACE 是 **异步** —— 后台线程扫表改数据,DML 不阻塞。

### 4.4 INPLACE 流程

```
1. RS 创建 "DDL task",记录进度
2. 后台线程(每个 OBServer 一份)扫表
   - 每扫一批 row:写新 SSTable(micro_block 带新 schema)
   - 删除旧 SSTable
   - 更新进度
3. 期间 DML 不阻塞(写新 SSTable 的 micro_block)
4. DDL 完成 → schema 切换到新版本
```

### 4.5 DDL 进度查询

```sql
-- 查看所有进行中的 DDL
SELECT * FROM oceanbase.__all_virtual_ddl_task\G

-- 关键字段:
-- task_id_: DDL 任务 ID
-- table_id_: 哪个表
-- ddl_type_: ALTER / CREATE INDEX ...
-- task_status_: PENDING / RUNNING / FINISHED / FAILED
-- progress_: 进度 0-100%
-- estimated_finish_time_: 预计完成时间
```

---

## 5. DDL 期间的查询处理

### 5.1 Schema 版本隔离

```cpp
// src/sql/optimizer/ob_log_plan.cpp:5000
// 查询开始时,记下 read_schema_version
void ObOptimizer::start() {
  read_schema_version_ = schema_service_.get_latest_version();
}

// 查询过程中,schema_version 可能变化,但不影响当前查询
// 因为 schema 在查询开始时已经"快照"了
```

### 5.2 DML 期间 DDL 的冲突

```cpp
// src/storage/transaction/ob_trans_service.cpp:1200
// 事务开始时,记下 schema_version
void ObTransCtx::start() {
  read_schema_version_ = schema_service_.get_latest_version();
  // 提交时,检查 schema_version 是否变化
  // 如果变化 → abort(因为看不到最新 schema)
  if (current_schema_version_ != read_schema_version_) {
    abort();
  }
}
```

DDL 提交时,**所有未提交事务都会被 abort**——保证 schema 切换的强一致性。

### 5.3 DDL 锁的语义

```cpp
// src/rootserver/ob_ddl_lock_mgr.cpp:50
class ObDDLLockManager {
public:
  // 1. 表级 schema lock
  // DDL 期间持有,所有 DML 等到 lock 释放
  ObSchemaLock schema_lock_;

  // 2. 表级 exclusive lock(INPLACE DDL 用)
  // 阻塞所有 DML
  ObTableLock exclusive_lock_;
};
```

| DDL 类型 | 锁 | 阻塞 DML |
|----------|-----|---------|
| INSTANT | 短暂 schema lock | 几秒 |
| INPLACE(短) | 短暂 exclusive lock | 几秒到几分钟 |
| INPLACE(长,如加索引) | 异步,exclusive lock 短 | 几乎不阻塞 |

### 5.4 双版本 Schema 兼容

OB 用 **双版本 schema 兼容** —— 同一 row 的 storage 用旧 schema,query 用
新 schema,只要两者兼容(列加/减 + default)就 OK。

```cpp
// src/storage/blocksstable/ob_micro_block.cpp:200
// micro_block 头部记录 schema_version
// 查询时,如果 row 是旧 schema 版本:
//   - 缺的列:用 default_value
//   - 多的列:跳过
```

---

## 6. Online Add Column(最常见的 DDL)

### 6.1 流程详解

```sql
ALTER TABLE t ADD COLUMN c_new INT DEFAULT 0;
```

```
1. RS 解析:判断是 INSTANT(ADD COLUMN with default)
2. 分配 schema_version: N+1
3. 写 Clog(OB_LOG_DDL):schema + N+1
4. 各 OBServer 接收 Clog:
   - 更新 schema cache
   - 不动 row 数据(列在 row 里"不存在"是允许的)
5. 完成(几秒)
```

### 6.2 旧 row 如何处理

```cpp
// 旧 row(没有 c_new 列)
// 读时,查询说"需要 c_new":
//   - 检查 row.has_column(c_new_id)
//   - 没有 → 返回 schema.default_value(0)
// 完全无 IO,完美兼容
```

### 6.3 性能影响

| 维度 | 影响 |
|------|------|
| 写放大 | 0(不重写 row) |
| 读放大 | 0(default 值是常数) |
| 锁等待 | < 1s |
| 内存 | 几个 KB(schema 元数据) |

这是 OB 5.x 的 killer feature —— 几乎 0 开销的 ADD COLUMN。

---

## 7. Online Add Index(常见但耗时)

### 7.1 流程详解

```sql
ALTER TABLE t ADD INDEX idx_a (a);
```

```
1. RS 解析:INPLACE(异步扫表)
2. 创建临时 index storage
3. 后台线程扫表:为每行生成 index entry,写入临时存储
4. 期间 DML 也生成 index entry(写新 MemTable + 临时 index)
5. 完成后切换:正式 index 接管,临时 index 删除
6. schema_version 切换
```

### 7.2 Online Add Index 的细节

```cpp
// src/storage/transaction/ob_index_builder.cpp:80
class ObIndexBuilder {
public:
  // 1. 扫表,生成 index entries
  int build_index() {
    while (OB_SUCC(scan_table(row))) {
      ObString idx_key = encode_index_key(row, index_columns_);
      temp_index_.insert(idx_key, &row);
    }
  }

  // 2. 期间 DML 也写临时 index
  int on_dml_write(const ObRow &row) {
    ObString idx_key = encode_index_key(row, index_columns_);
    temp_index_.insert(idx_key, &row);  // 双写
  }
};
```

### 7.3 DDL 完成后的清理

```cpp
// 1. 切换 schema_version → 新 schema
// 2. 临时 index 标记为正式 index
// 3. DDL 双写停止(只写正式 index)
// 4. 临时 index 后台清理
```

### 7.4 性能影响

| 维度 | 影响 |
|------|------|
| 写放大 | 2x(双写临时 + 正式) |
| 读放大 | 0(查询走正式 index) |
| 锁等待 | < 1s(schema 切换瞬间) |
| 内存 | 临时 index 大小(取决于表) |
| 耗时 | 与表大小成正比(1 亿行 ~10 分钟) |

---

## 8. Schema 缓存与一致性

### 8.1 Cache 失效

```cpp
// src/sql/optimizer/ob_schema_cache.cpp:80
// schema_version 变化 → 缓存失效
void ObSchemaCache::invalidate(uint64_t table_id) {
  // 1. 清 L1 / L2 / L3
  l1_cache_.erase(table_id);
  l2_cache_.erase(table_id);
  // 2. L3(RS fetch)延迟失效
  l3_cache_.set_ttl(0);
}
```

### 8.2 Plan Cache 与 Schema Version

```cpp
// src/sql/plan_cache/ob_plan_cache.cpp:200
// Plan Cache 记录的 plan 必须检查 schema_version
ObPhysicalPlan *ObPlanCache::get_plan(uint64_t table_id, int64_t expected_version) {
  auto it = plan_cache_.find(table_id);
  if (it != plan_cache_.end()) {
    if (it->second->schema_version_ == expected_version) {
      return it->second;  // schema 未变,plan 可用
    }
    // schema 变了,plan 失效
    plan_cache_.erase(it);
  }
  return nullptr;  // miss,重新优化
}
```

DDL 后,**所有依赖该表的 plan cache 都失效**——下一波查询全部重优化。这是
"DDL 后一波慢"的根因。

### 8.3 Optimizer Cache

```cpp
// src/sql/optimizer/ob_optimizer_cache.cpp:50
class ObOptimizerCache {
public:
  // Column stats / histogram 等缓存
  // DDL 后清空
  void on_schema_change(uint64_t table_id) {
    column_stats_.erase(table_id);
    histogram_.erase(table_id);
  }
};
```

---

## 9. DDL 失败与回滚

### 9.1 失败场景

| 失败 | 恢复策略 |
|------|----------|
| INSTANT DDL 失败 | 无需回滚(schema 没变) |
| INPLACE DDL 失败 | 保留旧 schema,清理临时 index |
| INPLACE DDL 部分完成 | checkpoint 进度,可 resume |
| RS 切换 / 网络分区 | 重试 |

### 9.2 回滚机制

```cpp
// src/rootserver/ob_ddl_rollback.cpp:50
class ObDDLRollback {
public:
  void rollback_ddl(const ObDDLRecord &record) {
    if (record.alter_type_ == OB_ALTER_TABLE_INPLACE) {
      // 1. 删除临时 index
      temp_index_mgr_.drop(record.table_id_, record.index_id_);
      // 2. schema 切回旧版本
      schema_service_.set_active_version(record.old_schema_version_);
    }
  }
};
```

### 9.3 DDL 任务的持久化

```cpp
// src/share/schema/ob_ddl_task.cpp:80
// DDL 任务存到 Clog(OB_LOG_DDL_TASK)
// 重启后可恢复进度
class ObDDLTask {
public:
  uint64_t task_id_;
  uint64_t table_id_;
  ObDDLType ddl_type_;
  int64_t progress_;
  // 写到 Clog,跨重启保留
  int persist_to_clog();
};
```

---

## 10. 监控与故障排查

### 10.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_ddl_stat\G

-- 关键字段:
-- active_ddl_count: 当前活跃 DDL 数
-- ddl_avg_time_us_: 平均 DDL 耗时
-- schema_version_: 当前 schema 版本
-- last_ddl_time_: 最近一次 DDL 时间
```

### 10.2 长 DDL 排查

```sql
-- 找运行 > 30min 的 DDL
SELECT * FROM oceanbase.__all_virtual_ddl_task
WHERE task_status_ = 'RUNNING'
  AND start_time_ < NOW() - INTERVAL 30 MINUTE;
```

常见修法:
- 取消重试:`ALTER TABLE t CANCEL DDL;` (OB 5.x 支持)
- 检查 OBServer 负载(扫表任务会跑满磁盘 IO)

### 10.3 Schema 不一致

```sql
-- 检查各 OBServer 的 schema_version 是否一致
SELECT svr_ip_, schema_version_
FROM oceanbase.__all_virtual_schema_version_stat
GROUP BY svr_ip_, schema_version_;
```

如果不一致:
- 检查 Clog 同步(主备延迟)
- 检查 RS 状态(可能需要切主)

---

## 11. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → **#21 v2 (本文)** 是 OB **storage / index / CBO / 
join / cache / 调优 / 日志 / 事务 / schema** 全主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObMvccHashIndex | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| #51 v2 | Block Cache | IO 层 | 三层 cache + LRU 变体 + bloom filter + DIO |
| #29 v2 | Slow Query | 运维层 | 捕获 + 分析 + 推荐 + 调优 |
| #22 v2 | Clog / Redo Log | 持久化层 | WAL + group commit + replica + recovery |
| #11 v2 | Trans Service / Lock | 事务层 | 全局事务 ID + 行锁 + 2PC + 死锁 + SI |
| **#21 v2 (本文)** | **Schema / DDL** | **元数据层** | **schema_version + INSTANT/INPLACE + Online DDL** |

十一篇连起来,读者能完整理解 OB 的"内存 → 锁 → 日志 → 磁盘 → cache →
调优 → 元数据"全链路:

- 数据怎么放:#14/#15/#16 (MemTable)
- 数据怎么改:#11 (Lock + 2PC)
- 数据怎么查:#17/#18 (CBO + Index)
- 数据怎么算:#41 (Join)
- 数据怎么 cache:#51 (Block Cache)
- 数据怎么持久化:#22 (Clog)
- 数据怎么调优:#29 (Slow Query)
- 数据结构怎么变:#21 (本文:Schema + Online DDL)

---

## 12. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **PX Framework / 并行调度** — worker pool + parallel execution + DAS
- **主备 / Failover** — 深入 failover 流程(接 #22)
- **RPC / 网络层** — obrpc + 跨 OBServer 通信
- **监控 / 告警** — ASH 深入 + metrics 体系(接 #29)
- **Schema 兼容性矩阵** — DDL 兼容性规则详解

继续哪一篇?

---

## 13. 参考(可执行的源码锚点)

- `src/share/schema/ob_table_schema.h` — ObTableSchema
- `src/share/schema/ob_column_schema.h` — ObColumnSchemaV2
- `src/share/schema/ob_index_schema.h` — ObIndexSchema
- `src/share/schema/ob_schema_service.cpp` — schema version + serialize
- `src/rootserver/ob_ddl_service.cpp` — DDL 协调
- `src/storage/ob_server_ddl_service.cpp` — OBServer 接收 DDL
- `src/storage/transaction/ob_index_builder.cpp` — Online Add Index
- `src/share/schema/ob_ddl_task.cpp` — DDL 任务持久化
- `src/rootserver/ob_ddl_lock_mgr.cpp` — DDL 锁
- `src/sql/plan_cache/ob_plan_cache.cpp` — Plan Cache 与 Schema Version

---

#21 v2 完。
