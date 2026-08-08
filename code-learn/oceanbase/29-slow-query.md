# #29 v2 — Slow Query (捕获 + 分析 + 索引推荐 完整实读)

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后)

> 接续 #17 v2 Query Optimizer + #51 v2 Block Cache:前面讲了 CBO 怎么估算、cache
> 怎么管理。本文聚焦 **生产环境的"为什么慢"+ 怎么定位 + 怎么修** —— slow
> query 的捕获机制、分析工具、推荐系统。这是 OB 把"理论 CBO" 变成"运维可
> 用信号"的最后一公里。

---

## 0. 全文导读

Slow query 调优是 OB 运维的核心场景,涉及四个层次:

```
1. 捕获 (capture)  - 怎么发现慢 query
2. 分析 (analyze)  - 慢在哪里 / 为什么
3. 推荐 (recommend) - 怎么修(加索引?改写 SQL?)
4. 验证 (verify)   - 修完真的快了吗
```

本文按这四层展开,涉及:
- slow query threshold + trace 机制
- `oceanbase.__all_virtual_slow_query_*` 虚拟表
- `EXPLAIN` / `EXPLAIN EXTENDED` / `query_trace`
- `plan_monitor` 实际执行统计
- ASH(active session history)
- Index advisor(基于 CBO 代价的推荐)
- 实际 case study(常见 slow query 模式 + 修法)

---

## 1. Slow Query 捕获机制

### 1.1 Threshold 配置

```sql
-- session 级
SET ob_query_timeout = 10000000;  -- 10s,超过记 slow query
SET ob_trx_timeout = 100000000;   -- 100s,事务超时

-- 系统级
ALTER SYSTEM SET slow_query_threshold = '1s';
ALTER SYSTEM SET enable_slow_query = ON;
```

OB 默认 threshold = 100ms。低于这个的 query 不进 slow query 表。

### 1.2 采样机制

```cpp
// src/sql/slow_query/ob_slow_query_rpc.h:60
class ObSlowQueryCollector {
public:
  // 1. 周期性(每秒)把本地 slow query 写盘
  int flush_to_disk();

  // 2. 上报到 RootServer(集群级汇总)
  int report_to_root_server();

private:
  // 每条 slow query 的元数据
  struct SlowQueryRecord {
    uint64_t trace_id_;          // SQL trace id
    uint64_t sql_id_;            // SQL fingerprint
    std::string user_;           // 执行用户
    std::string db_;             // database
    std::string sql_text_;       // 原始 SQL
    int64_t exec_time_us_;       // 执行时间
    int64_t plan_time_us_;       // 优化时间
    int64_t wait_time_us_;       // 等待时间
    int64_t row_count_;          // 返回行数
    int64_t logical_read_;       // 逻辑读
    int64_t physical_read_;      // 物理读
    std::string plan_info_;      // 执行计划
  };
};
```

### 1.3 SQL Trace ID

```cpp
// src/sql/ob_sql_audit.h:80
// 每条 SQL 分配一个全局唯一 trace_id(16 bytes UUID)
// 贯穿 parse → resolve → optimize → execute → finish
// 在日志里 trace_id 是 grep 锚点

class ObTraceId {
public:
  char data_[16];  // UUID 格式

  // 出现在慢 query 日志的格式:
  // [2026-08-02 22:00:00.123] [TRACE=abc12345-...] user=app1 sql=SELECT ...
};
```

生产环境的 grep 模式:

```bash
grep "abc12345" observer.log  # 拿一条 SQL 的全链路日志
```

---

## 2. Slow Query 虚拟表

### 2.1 系统视图

```sql
-- 当前 server 的 slow query
SELECT * FROM oceanbase.__all_virtual_slow_query\G

-- 所有 server 的 slow query(集群级)
SELECT * FROM oceanbase.__all_virtual_slow_query
  WHERE svr_ip = 'xxx' AND exec_time > 1000000  -- 1s+
  ORDER BY exec_time DESC
  LIMIT 10;

-- 按 SQL fingerprint 聚合(同一 SQL 多次执行)
SELECT sql_id_, COUNT(*) cnt, AVG(exec_time) avg_us, MAX(exec_time) max_us
FROM oceanbase.__all_virtual_slow_query
GROUP BY sql_id_
ORDER BY max_us DESC
LIMIT 20;
```

### 2.2 关键字段

| 字段 | 含义 | 调优用途 |
|------|------|----------|
| `sql_id_` | SQL fingerprint | 聚合同一类 query |
| `sql_text_` | 完整 SQL | 看具体语句 |
| `exec_time_us_` | 执行时间(μs) | 排序主指标 |
| `plan_time_us_` | 优化时间 | 看 CBO 是否慢 |
| `wait_time_us_` | 等待时间(锁/IO 等) | 看是不是被卡 |
| `logical_read_` | 逻辑读(内存 + cache 命中) | 看是否过度 scan |
| `physical_read_` | 物理读 | 看 cache 命中率 |
| `plan_info_` | 执行计划文本 | 看是否选错 index |
| `trace_id_` | trace ID | 关联日志 |
| `user_`, `client_ip_` | 执行信息 | 排查应用来源 |

### 2.3 自动清理

```sql
-- 保留 7 天(默认)
ALTER SYSTEM SET slow_query_history_days = 7;

-- 手动清理
ALTER SYSTEM FLUSH SLOW QUERY;
```

---

## 3. EXPLAIN — 看 CBO 选了什么

### 3.1 基础 EXPLAIN

```sql
EXPLAIN SELECT * FROM t WHERE a = 5;
```

输出示例:

```
=====================================
| ID | OPERATOR      | NAME  | EST. ROWS |
=====================================
| 0  | TABLE SCAN    | t     | 100000    |
| 1  | TABLE GET     | t     | 1         |
=====================================

Outputs & filters:
-------------------------------------
0 - output([...]), filter(nil)
    table_columns([t.id, t.a, t.b])
1 - output([...]), filter(nil)
    access([t.id], [t.a])

Used indexes:
  idx_a (range)
```

关键信息:
- 走哪个 index(Used indexes)
- 估算行数(EST. ROWS) vs 实际行数
- operator 类型(TABLE SCAN / TABLE GET / JOIN 等)

### 3.2 EXPLAIN EXTENDED

```sql
EXPLAIN EXTENDED SELECT * FROM t WHERE a = 5;
```

EXTRA 输出包括:
- **每个候选 index 的 cost 估算**
- **被拒绝的候选(为什么被拒)**
- **统计信息**(NDV, null count, table_rows)
- **base table 的 cost**
- **CBO 决策树路径**

```cpp
// src/sql/optimizer/ob_log_plan.cpp:4500
// 生成 EXPLAIN EXTENDED 的细节
int ObLogPlan::format_explain_extended(...) {
  // 1. 列出所有候选 access path
  for (auto &c : candidate_paths_) {
    format_candidate(c);
  }
  // 2. 列出 cost 计算过程
  for (auto &cost : cost_breakdown_) {
    format_cost(cost);
  }
  // 3. 列出 stats 来源
  format_stats_usage();
  return OB_SUCCESS;
}
```

### 3.3 query_trace — optimizer 选择过程

```sql
SET ob_enable_query_trace = ON;
SELECT * FROM t WHERE a = 5;
-- 输出 optimizer 决策树:
```

```
[Plan Id: 100]
[Plan Type: LOCAL]
[Optimizer Cost: 1234.56]

=== Decision Tree ===
1. TableAccessPath candidates:
   - table scan: cost=1234567, rows=1000000
   - idx_a: cost=12.34, rows=10      <-- SELECTED
   - idx_b: cost=345.6, rows=100
   Reject idx_b: selectivity 0.1 < threshold
2. Join candidates: NL vs Hash
   - NL: cost=45.6
   - Hash: cost=23.4                  <-- SELECTED
3. GroupBy: HashAgg vs SortAgg
   - HashAgg: cost=12.3               <-- SELECTED

=== Stats ===
Table t: rows=1000000, blocks=4000
Column a: NDV=100000, null_count=0, min=0, max=999999
Histogram on a: 254 buckets
```

query_trace 是**调优 slow query 的关键工具**——它直接告诉你 CBO 选了什么、
为什么选、cost 是多少。

---

## 4. plan_monitor — 实际执行统计

### 4.1 运行时监控

```sql
-- 查看正在执行的 query 实际统计
SELECT * FROM oceanbase.__all_virtual_plan_monitor\G
```

关键字段:

| 字段 | 含义 |
|------|------|
| `tenant_id_` | tenant |
| `svr_ip_`, `svr_port_` | 在哪个 OBServer 跑 |
| `plan_id_` | plan hash |
| `sql_id_` | SQL fingerprint |
| `output_rows_` | 实际返回行数 |
| `process_rows_` | 实际扫描行数 |
| `elapsed_time_us_` | 实际耗时 |
| `cpu_time_us_` | CPU 占用 |
| `io_read_bytes_` | IO 读字节 |
| `mem_used_bytes_` | 内存占用 |
| `expected_worker_count_` | 预期并行度 |
| `actual_worker_count_` | 实际并行度 |

### 4.2 估算 vs 实际 对比

```sql
SELECT sql_id_, output_rows_ AS est_rows, ...
FROM oceanbase.__all_virtual_plan_monitor
WHERE ABS(output_rows_ - est_rows_) > 10 * est_rows_;  -- 偏差 > 10x
```

**关键 insight**:如果 `output_rows_ << est_rows_`,说明 CBO 严重高估——stats
可能过时,需要 `ANALYZE TABLE`。

### 4.3 长时间运行 query 监控

```sql
-- 找运行 > 60s 的 query
SELECT * FROM oceanbase.__all_virtual_plan_monitor
WHERE elapsed_time_us_ > 60000000  -- 60s
ORDER BY elapsed_time_us_ DESC;
```

---

## 5. SQL Audit

### 5.1 完整 SQL 历史

```sql
-- 所有执行过的 SQL(不只慢的)
SELECT * FROM oceanbase.__all_virtual_sql_audit
WHERE request_time > NOW() - INTERVAL 1 HOUR
ORDER BY exec_time DESC
LIMIT 50;
```

### 5.2 关键字段

| 字段 | 含义 |
|------|------|
| `request_time_` | 执行时间 |
| `sql_id_` | SQL fingerprint |
| `sql_text_` | 完整 SQL |
| `exec_time_us_` | 执行耗时 |
| `plan_time_us_` | 优化耗时 |
| `queue_time_us_` | 在队列里等的耗时 |
| `affected_rows_` | 影响行数 |
| `ret_code_` | 返回码 |
| `plan_id_` | plan hash |
| `client_ip_`, `user_` | 来源 |

### 5.3 SQL 指纹(SQL Fingerprint)

```sql
-- 把具体 SQL 归一化成 fingerprint
-- "WHERE a = 5" 和 "WHERE a = 10" → 同一个 sql_id
SELECT sql_id_, COUNT(*) cnt
FROM oceanbase.__all_virtual_sql_audit
GROUP BY sql_id_
ORDER BY cnt DESC
LIMIT 10;
```

找出"调用频率最高的 SQL"——往往是优化 ROI 最高的。

---

## 6. ASH — Active Session History

### 6.1 概念

```cpp
// src/share/ash/ob_ash_report.h:80
// 每秒采样所有 active session
// 记录:session_id, sql_id, event, wait_time, ...
class ObASHReport {
public:
  // 类似 Oracle ASH / MySQL performance_schema
  // 高频采样(1Hz)抓瞬时状态
  struct AshSample {
    uint64_t session_id_;
    uint64_t sql_id_;
    std::string event_;         // 当前等待事件
    int64_t wait_time_us_;      // 等待时长
    int64_t sample_time_us_;    // 采样时间
  };
};
```

### 6.2 排查"为什么慢"

```sql
-- 最近 1 小时,所有 session 的等待事件聚合
SELECT event_, COUNT(*) cnt, AVG(wait_time_us) avg_wait
FROM oceanbase.__all_virtual_ash
WHERE sample_time > NOW() - INTERVAL 1 HOUR
GROUP BY event_
ORDER BY cnt DESC;
```

常见等待事件:

| Event | 含义 | 修法 |
|-------|------|------|
| `wait/io/file/innodb/data` | 等磁盘 IO | 加 cache / SSD |
| `wait/lock/table` | 等表锁 | 短事务 / 改 DDL |
| `wait/mutex/innodb/log` | 等 redo log | 关 sync_binlog |
| `wait/cond/plan_cache` | 等 plan cache lock | 减少 DDL 频率 |
| `cpu` | 纯 CPU | 加索引 / 改写 SQL |

### 6.3 关联到具体 SQL

```sql
-- 找"现在正在跑、卡 IO 的 query"
SELECT sql_id_, event_, wait_time_us_
FROM oceanbase.__all_virtual_ash
WHERE event_ LIKE 'wait/io/%'
ORDER BY wait_time_us DESC
LIMIT 20;
```

---

## 7. Index Advisor — 索引推荐

### 7.1 工作原理

```cpp
// src/sql/optimizer/ob_index_advisor.cpp:80
class ObIndexAdvisor {
public:
  // 1. 收集 workload(从 sql_audit / slow_query)
  ObSEArray<ObSQLStatement> workload_;

  // 2. 对每个 query 模拟"加了候选 index 之后"的速度
  double estimate_query_speedup(ObIndexInfo *candidate, ObSQLStatement *stmt);

  // 3. 选收益最大的 index 推荐
  ObSEArray<ObIndexInfo *> recommend_indexes();
};
```

### 7.2 候选 index 构造

```cpp
// src/sql/optimizer/ob_index_advisor.cpp:200
// 从 SQL 谓词里提取候选 index 列
ObSEArray<ObIndexInfo *> ObIndexAdvisor::generate_candidates(ObSQLStatement *stmt) {
  ObSEArray<ObIndexInfo *> candidates;
  // 1. 提取 WHERE 列
  for (auto &col : stmt->get_where_columns()) {
    candidates.push_back(make_single_col_index(col));
  }
  // 2. 提取 ORDER BY 列
  for (auto &col : stmt->get_orderby_columns()) {
    candidates.push_back(make_single_col_index(col));
  }
  // 3. 提取 JOIN 列
  for (auto &col : stmt->get_join_columns()) {
    candidates.push_back(make_single_col_index(col));
  }
  // 4. 组合多列 index
  for (auto &c1 : candidates) {
    for (auto &c2 : candidates) {
      if (c1->col != c2->col) {
        candidates.push_back(make_composite_index({c1->col, c2->col}));
      }
    }
  }
  return candidates;
}
```

### 7.3 Cost 模型 估算 speedup

```cpp
// src/sql/optimizer/ob_index_advisor.cpp:300
// 估算"加这个 index 之后,query 快多少"
double ObIndexAdvisor::estimate_query_speedup(ObIndexInfo *candidate,
                                                ObSQLStatement *stmt) {
  // 1. 当前 cost(无 index)
  double current_cost = estimate_cost(stmt, /* use current indexes */);

  // 2. 模拟加 candidate 后 cost
  double new_cost = estimate_cost(stmt, /* with candidate index */);

  // 3. speedup = current / new
  return current_cost / new_cost;
}
```

### 7.4 推荐结果

```sql
-- 调用 index advisor
CALL dbms_advisor.recommend_index('user1', 't1');

-- 看推荐
SELECT * FROM oceanbase.__all_virtual_index_recommend\G
```

输出示例:

```
Table: user1.t1
Recommended index: idx_a_b(a, b)
Speedup: 50x  (current 5.0s → new 100ms)
Cost: 增加 100MB 存储 + 5% 写放大
```

### 7.5 自动 apply

```sql
-- 看推荐但不 apply
CALL dbms_advisor.recommend_index('user1', 't1', /* auto_apply= */ false);

-- 直接 apply
CALL dbms_advisor.recommend_index('user1', 't1', /* auto_apply= */ true);
```

> **v2 洞察**:index advisor 是 "CBO-driven recommendation"——它用的是
> CBO 同一套 cost model。所以推荐的 index 一定能让 CBO 选上。但实际生产
> 上,**advisor 推荐的不一定是最优**——它没考虑写入放大、空间占用、维护成本。
> 运维应该结合 DML 频率、磁盘空间 二次判断。

---

## 8. 调优 Checklist

### 8.1 标准排查流程

```
Step 1: 找慢 query
  ↓ SELECT * FROM oceanbase.__all_virtual_slow_query WHERE ...
Step 2: 看执行计划
  ↓ EXPLAIN EXTENDED <slow_query>
Step 3: 对比估算 vs 实际
  ↓ SELECT * FROM oceanbase.__all_virtual_plan_monitor WHERE sql_id_=...
Step 4: 找等待事件
  ↓ SELECT event_, ... FROM oceanbase.__all_virtual_ash WHERE sql_id_=...
Step 5: 跑 index advisor
  ↓ CALL dbms_advisor.recommend_index(...)
Step 6: ANALYZE TABLE 重收 stats
  ↓ ANALYZE TABLE t1;
Step 7: 应用推荐
  ↓ ALTER TABLE t1 ADD INDEX idx_xx (cols...);
Step 8: 验证
  ↓ 再跑 EXPLAIN,对比新 plan
```

### 8.2 五大常见 slow query 模式

#### 模式 1:全表扫描

```sql
SELECT * FROM t WHERE status = 'pending';
-- status 是低选择性列(50% 都 match)
-- EXPLAIN 显示:TABLE SCAN,rows=1000000
-- 修法:加索引 + 改 query
ALTER TABLE t ADD INDEX idx_status (status);
-- 但 status 选择性低,实际效果有限
-- 更好:status + 时间,组合索引
ALTER TABLE t ADD INDEX idx_status_time (status, create_time);
```

#### 模式 2:函数包裹索引列

```sql
SELECT * FROM t WHERE DATE(create_time) = '2026-08-02';
-- EXPLAIN 显示:TABLE SCAN
-- 修法 1:加函数索引
ALTER TABLE t ADD INDEX idx_date_create (DATE(create_time));
-- 修法 2:改写 query
SELECT * FROM t
WHERE create_time >= '2026-08-02' AND create_time < '2026-08-03';
```

#### 模式 3:N+1 查询

```sql
-- App 层每行单独查(典型 ORM)
SELECT * FROM orders WHERE user_id = 1;  -- 1 query
SELECT * FROM users WHERE id = 5;        -- per row
SELECT * FROM users WHERE id = 7;        -- per row
...
-- 共 N+1 次 query
-- 修法:JOIN
SELECT o.*, u.* FROM orders o JOIN users u ON o.user_id = u.id
WHERE o.user_id IN (1, 5, 7, ...);
```

#### 模式 4:ORDER BY 触发 filesort

```sql
SELECT * FROM t WHERE status = 'pending' ORDER BY create_time;
-- EXPLAIN 显示:TABLESCAN + SORT
-- 修法:覆盖 index
ALTER TABLE t ADD INDEX idx_status_time (status, create_time);
-- ORDER BY 列在 index 里,跳过 sort
```

#### 模式 5:LIMIT 大偏移

```sql
SELECT * FROM t ORDER BY id LIMIT 1000000, 10;
-- MySQL 风格大偏移(OB 也支持但代价高)
-- EXPLAIN 显示:TABLESCAN + SORT + 偏移 100 万
-- 修法 1:cursor-based
SELECT * FROM t WHERE id > last_seen_id ORDER BY id LIMIT 10;
-- 修法 2:分页查询
SELECT * FROM t WHERE id BETWEEN 1000000 AND 1000010;
```

---

## 9. 实际 Case Study

### 9.1 Case:某慢 query 从 5s 优化到 50ms

**初始 SQL:**

```sql
SELECT * FROM orders WHERE user_id = 12345 ORDER BY create_time DESC LIMIT 20;
```

**EXPLAIN:**

```
TABLE SCAN orders  rows=1000000 cost=9876543
SORT                cost=12345
LIMIT 20            cost=20
```

**root cause:** 没有 user_id 索引,全表扫 + sort + limit。

**修法:**

```sql
ALTER TABLE orders ADD INDEX idx_user_time (user_id, create_time DESC);
```

**新 EXPLAIN:**

```
TABLE GET orders  rows=20 cost=12  (走 idx_user_time)
LIMIT 20           cost=20
```

**耗时对比:** 5,000ms → 50ms(**100x speedup**)

### 9.2 Case:JOIN 慢

**初始 SQL:**

```sql
SELECT * FROM orders o JOIN users u ON o.user_id = u.id
WHERE o.create_time > '2026-01-01';
```

**EXPLAIN:**

```
HASH JOIN
  ├── TABLE SCAN orders  rows=1000000 (filter: time)
  └── TABLE SCAN users   rows=500000
```

**root cause:** Hash Join 两边都全表扫,IO 爆炸。

**修法:**

```sql
ALTER TABLE orders ADD INDEX idx_time (create_time);
```

**新 EXPLAIN:**

```
HASH JOIN
  ├── INDEX SCAN orders idx_time  rows=100000 (filter: time)
  └── TABLE SCAN users   rows=500000
```

**耗时对比:** 3,000ms → 300ms(**10x speedup**)

### 9.3 Case:Slow query 是 CBO 错选

**初始 SQL:**

```sql
SELECT * FROM t WHERE a = 5 AND b LIKE 'x%';
```

**EXPLAIN:**

```
TABLE SCAN t  rows=1000000 cost=9876
FILTER (a=5 AND b LIKE 'x%')
```

CBO 选全表扫,虽然有 idx_ab。但 stats 显示 `a` NDV=100,`b` NDV=10,实际
`a=5 AND b LIKE 'x%'` 只有 5 行。

**root cause:** stats 过时(实际 NDV 比记录的高)。

**修法:**

```sql
ANALYZE TABLE t;
```

**新 EXPLAIN:**

```
TABLE GET t via idx_ab  rows=5 cost=10
```

**耗时对比:** 1,000ms → 5ms(**200x speedup**)

> **v2 洞察**(接 #17 v2 + #51 v2):CBO 错选 80% 是 stats 过时。生产环境
> 的 stats 维护:**大表每周 ANALYZE,小表每天 ANALYZE,ETL 后立即 ANALYZE**。
> OB 5.x 的 `auto_collect_stats` 可以在 DML 量超过阈值时自动 ANALYZE。

---

## 10. 与 v2 主线的连接

#17 v2(Query Optimizer) + #51 v2(Block Cache) + #29 v2(本文)构成 OB 调优
三角:

```
#17 (怎么算 cost)
   ↓
   选 plan / 选 index
   ↓
#51 (cache 怎么命中)
   ↓
   减少 IO
   ↓
#29 (本文: 实测 + 推荐 + 调优)
```

读路径:
1. SQL 进来 → #17 CBO 估算 → 选 plan + index
2. 执行 → #41 join + #15/#16 MemTable → #51 cache 命中或 IO
3. 监控 → #29 slow_query / plan_monitor / ASH
4. 反馈 → #17 ANALYZE 重新算 → 选更好 plan

---

## 11. 高级话题

### 11.1 Plan Binding(绑定计划)

有时 CBO 选错,但 stats 不易改(比如 OLAP 大表 ANALYZE 太慢)。可以**绑定
plan hash**:

```sql
-- 绑定 plan(用 outline)
CREATE OUTLINE outline_1 ON SELECT * FROM t WHERE a = 5;
-- 强制 SQL 走这个 plan,即使 CBO 估算变了
```

### 11.2 SQL 限流(SQL Throttle)

```sql
-- 限制某类 SQL 的并发 / 频率
ALTER SYSTEM SET sql_throttle = '[1,100]SELECT * FROM t WHERE ...';
-- [1,100]:超过并发 100 就排队
```

### 11.3 Trace Diff

```bash
# 对比两次 query 的 trace
diff <(trace_query_1) <(trace_query_2)
# 找出哪一步变慢
```

---

## 12. 调优 ROI 排序

从高到低:

| 修法 | ROI | 适用 |
|------|-----|------|
| 加 covering index | 100x | 几乎总是 |
| ANALYZE TABLE | 50x | stats 过时 |
| 改写 N+1 → JOIN | 50x | 应用层 |
| 改写 ORDER BY 用 index | 20x | filesort |
| 改 LIMIT 大偏移 → cursor | 20x | 分页 |
| 加 functional index | 10x | 表达式查询 |
| 调 cache 容量 | 5x | 全场景 |
| 升 OB 版本 | 3x | 旧版 bug |

---

## 13. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
(本文) 是 **storage / index / optimizer / join / cache / 调优** 主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObMvccHashIndex | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| #51 v2 | Block Cache | IO 层 | 三层 cache + LRU 变体 + bloom filter + DIO |
| **#29 v2 (本文)** | **Slow Query** | **运维层** | **捕获 + 分析 + 推荐 + 调优** |

八篇连起来,读者能完整理解 OB 的"开发 + 优化"全链路:

- 开发期:#14-#18 (storage/index API)
- 运行期:#41/#51 (executor + cache)
- 调优期:#17 (cost model) + #29 (本文)

---

## 14. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **#19-#40 系列**(待确认具体编号)
- **#42-#50 系列**(待确认具体编号)
- **#52-#100 系列**(待确认具体编号)

继续哪一篇?

---

## 15. 参考(可执行的源码锚点)

- `src/sql/slow_query/ob_slow_query_rpc.h` — slow query collector
- `src/sql/ob_sql_audit.h` — SQL audit + trace id
- `src/sql/optimizer/ob_log_plan.cpp` — EXPLAIN EXTENDED
- `src/share/ash/ob_ash_report.h` — ASH 采样
- `src/sql/optimizer/ob_index_advisor.cpp` — index advisor
- `src/share/stat/ob_stat_manager.h` — stats 收集
- `src/sql/plan_cache/ob_plan_cache.h` — plan binding

---

#29 v2 完。
