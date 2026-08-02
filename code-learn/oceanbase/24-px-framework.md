# #24 v2 — PX Framework / 并行调度 (Parallel Execution 完整实读)

> 接续 #41 v2 Join Operators + #51 v2 Block Cache + #17 v2 Query Optimizer:前
> 面讲了 "join 怎么算" 和 "cache 怎么管理"。本文聚焦 **"大查询怎么并行"**
> ——OB 的 PX Framework (Parallel eXecution)。这是 OB 在 AP/OLAP 场景下甩开
> 传统数据库的关键架构。

---

## 0. 全文导读

OB 的并行执行有两层:

```
1. Intra-OBServer PX (单节点多线程并行)
   - Worker Pool + Task Queue + Data Exchange
2. Inter-OBServer DAS (跨节点并行)
   - Direct Attach Service + 分布式调度
```

本文按"架构 → Worker Pool → Task 调度 → Data Exchange → DAS → 性能调
优"展开。

---

## 1. PX 整体架构

### 1.1 物理计划分解

```
SQL: SELECT count(*) FROM t1 JOIN t2 ON ...
  ↓
ObPhysicalPlan (logical)
  ↓ PX 改写
ObPxPhysicalPlan (parallel)
  ├── DML Op (root, 1 worker)
  │     ├── Exchange (gather)
  │     └── Join (N workers)
  │           ├── Exchange (redistribute by t1.id)
  │           ├── Scan t1 (N workers)
  │           └── Exchange (redistribute by t2.t1_id)
  │                 └── Scan t2 (N workers)
```

PX 把物理计划**改写**成 "DAG of Exchange + Op"—— 每个 Exchange 是数据
流边界,每个 Op 是并行执行的算子。

### 1.2 三种并行度

```cpp
// src/sql/px/ob_px_coord.h:80
// PX 有三个并行度维度:
class ObPxCoord {
public:
  // 1. DFO (Data Flow Operator) 数:子计划的并行度
  int64_t dfo_count_;
  // 2. 每个 DFO 内的 worker 数
  int64_t worker_per_dfo_;
  // 3. 跨 OBServer 的并行度(DAS)
  int64_t ob_server_count_;
};
```

### 1.3 ObPxPhysicalPlan

```cpp
// src/sql/px/ob_px_physical_plan.h:60
class ObPxPhysicalPlan {
public:
  // 1. root DFO(单 OBServer 上跑)
  ObPxDfoSpec *root_dfo_;
  // 2. 子 DFO(可能跨 OBServer)
  ObSEArray<ObPxDfoSpec *> sub_dfos_;
  // 3. 计划 ID
  uint64_t plan_id_;
};
```

---

## 2. Worker Pool

### 2.1 ObPxWorkerPool

```cpp
// src/sql/px/ob_px_worker_pool.h:80
class ObPxWorkerPool {
public:
  // 1. worker 线程池(默认 = OBServer CPU 核数)
  std::vector<std::thread> workers_;
  size_t worker_count_ = std::thread::hardware_concurrency();
  // 2. 任务队列(无锁 / 锁队列)
  ObLockFreeQueue<ObPxTask *> task_queue_;
  // 3. worker 状态
  enum WorkerState { IDLE, RUNNING, STOPPED };
};
```

### 2.2 Worker 循环

```cpp
// src/sql/px/ob_px_worker.cpp:50
void ObPxWorker::run() {
  while (running_) {
    ObPxTask *task = task_queue_.pop();
    if (task == nullptr) {
      sleep(1ms);  // 没任务时休眠
      continue;
    }
    // 执行 task
    task->execute();
    // 标记完成
    task->mark_done();
  }
}
```

### 2.3 Worker 数量调整

```sql
-- 系统级
ALTER SYSTEM SET px_workers_per_cpu = 2;  -- 每 CPU 2 个 worker

-- Query 级
SELECT /*+ PARALLEL(8) */ * FROM t;  -- 8 个 worker 并行
```

---

## 3. Task 调度

### 3.1 ObPxTask

```cpp
// src/sql/px/ob_px_task.h:100
class ObPxTask {
public:
  // 1. task 所属 DFO
  uint64_t dfo_id_;
  // 2. task 内的 operator 树
  ObPxOpSpec *op_tree_;
  // 3. task 状态
  enum State { PENDING, RUNNING, DONE, FAILED };
  // 4. 输入输出 channel
  ObPxChannel *input_;
  ObPxChannel *output_;
};
```

### 3.2 Task 调度器

```cpp
// src/sql/px/ob_px_scheduler.cpp:80
class ObPxScheduler {
public:
  // 1. 调度策略:负载均衡
  void schedule_tasks() {
    // 1.1 收集待调度 task
    ObSEArray<ObPxTask *> pending_tasks;
    collect_pending(pending_tasks);
    // 1.2 按 worker 负载分配
    for (auto *task : pending_tasks) {
      // 选负载最低的 worker
      auto *worker = worker_pool_.pick_least_loaded();
      worker->assign(task);
    }
  }
};
```

### 3.3 Task 状态机

```
PENDING → RUNNING → DONE
                  ↘ FAILED
```

```cpp
// src/sql/px/ob_px_task.cpp:200
void ObPxTask::execute() {
  state_ = RUNNING;
  try {
    // 1. 执行 operator 树(从 root 开始)
    ObPxOp *op = root_op_;
    while (op) {
      op->process();
      op = op->next();
    }
    state_ = DONE;
  } catch (...) {
    state_ = FAILED;
    // 通知 coordinator
    coordinator_->on_task_failed(this);
  }
}
```

---

## 4. Data Exchange

### 4.1 Exchange 模式

```cpp
// src/sql/px/ob_px_exchange_op.h:60
enum ObExchangeMode {
  // 1. 单播(发给单一 worker)
  PX_EXCHANGE_SINGLE,
  // 2. 广播(发给所有 worker)
  PX_EXCHANGE_BCAST,
  // 3. Hash 分发(按 key hash)
  PX_EXCHANGE_HASH,
  // 4. Range 分发(按 key range)
  PX_EXCHANGE_RANGE,
};
```

### 4.2 Hash Exchange 实现

```cpp
// src/sql/px/ob_px_exchange_op.cpp:80
class ObPxHashExchange : public ObPxExchangeOp {
public:
  // 每行按 join key hash 分发到 N 个目标 worker
  int distribute(const ObRow &row) override {
    // 1. 计算 hash 分发 key
    ObString hash_key = extract_key(row);
    // 2. 选目标 worker
    size_t target = hash(hash_key) % n_targets_;
    // 3. 写到目标 channel
    channels_[target]->write(row);
  }
};
```

### 4.3 Channel 缓冲

```cpp
// src/sql/px/ob_px_channel.h:50
// channel 是 producer/consumer 之间的 buffer
// 防止慢 worker 卡住快 worker

class ObPxChannel {
public:
  // 1. 环形 buffer(默认 64KB)
  char buffer_[65536];
  size_t write_pos_;
  size_t read_pos_;
  // 2. 同步原语
  std::mutex mtx_;
  std::condition_variable not_empty_;
  std::condition_variable not_full_;
};
```

### 4.4 数据序列化

```cpp
// src/sql/px/ob_px_row_serialization.cpp:50
// 跨线程/跨 OBServer 数据传输需要序列化
// OB 用紧凑二进制格式(类似 OB Row 编码)
int serialize_row(const ObRow &row, char *buf, size_t &len) {
  // 1. 写每列
  for (size_t i = 0; i < row.count_; ++i) {
    const ObObj &cell = row.cells_[i];
    buf += cell.serialize(buf);
    len += cell.get_serialize_size();
  }
  return OB_SUCCESS;
}
```

---

## 5. DAS (Direct Attach Service)

### 5.1 DAS 的角色

```
场景:大表 JOIN 小表
  t1 (1 亿行) JOIN t2 (1000 行) ON t1.id = t2.id

传统:把 t2 拉到自己节点,做 hash join
       ↑ 但 t2 在另一个 OBServer,网络传输浪费
       
DAS:把 join 推到 t2 所在节点
       ↑ 避免数据传输
```

DAS 把 **算子下推到数据所在节点**,避免 shuffle。

### 5.2 DAS 实现

```cpp
// src/sql/engine/das/ob_das_op.h:80
class ObDASOp {
public:
  // 1. DAS op 类型
  enum Type {
    DAS_OP_SCAN,         // 远程 scan
    DAS_OP_LOOKUP,       // 远程 PK lookup
    DAS_OP_JOIN,         // 远程 hash join
    DAS_OP_AGGREGATE,    // 远程聚合
  };
  // 2. DAS op 在哪个 OBServer 执行
  ObAddr location_;
};
```

### 5.3 DAS Join 流程

```cpp
// src/sql/engine/das/ob_das_join_op.cpp:100
int ObDASJoinOp::execute() {
  // 1. 检查内表(小表)能否下推
  if (can_pushdown_inner_table()) {
    // 2. 把 inner table 下推到 inner 所在 OBServer
    ObDASOp das_join;
    das_join.type_ = DAS_OP_JOIN;
    das_join.location_ = inner_table_location_;
    // 3. RPC 触发 DAS 执行
    rpc_->send(inner_addr_, OB_DAS_EXECUTE, das_join);
    // 4. DAS 在 inner 所在节点做 hash join
    // 5. 拿回 join 结果
  }
}
```

### 5.4 DAS vs PX

| 场景 | 选 DAS | 选 PX |
|------|--------|-------|
| **大表 JOIN 小表** | ✅ | ❌(shuffle 大表浪费) |
| **小表 JOIN 大表** | ❌ | ✅(大表并行 scan) |
| **跨 OBServer 聚合** | ✅ | ❌ |
| **单 OBServer 大查询** | ❌ | ✅ |

OB 优化器自动选择 —— 取决于表大小 + 节点分布。

---

## 6. PX 的执行流程

### 6.1 协调器

```cpp
// src/sql/px/ob_px_coord.cpp:80
class ObPxCoord {
public:
  // 协调整个 PX plan 的执行
  int execute_plan(ObPxPhysicalPlan &plan) {
    // 1. 先调度 leaf DFO(scan 端)
    for (auto *dfo : plan.sub_dfos_) {
      if (dfo->is_leaf()) {
        schedule_dfo(dfo);  // 启动 leaf worker
      }
    }
    // 2. 等 leaf 完成,启动中间 DFO
    wait_leaf_done();
    for (auto *dfo : plan.sub_dfos_) {
      if (!dfo->is_leaf() && !dfo->is_root()) {
        schedule_dfo(dfo);
      }
    }
    // 3. 最后调度 root DFO
    schedule_dfo(plan.root_dfo_);
    // 4. 等所有 DFO 完成
    wait_all_done();
    return OB_SUCCESS;
  }
};
```

### 6.2 DFO 调度

```cpp
// src/sql/px/ob_px_dfo.cpp:100
void ObPxDfo::schedule() {
  // 1. 把 DFO 拆成 N 个 task(N = worker_per_dfo)
  ObSEArray<ObPxTask *> tasks;
  split_dfo_into_tasks(this, tasks);
  // 2. 每个 task 分给 worker
  for (auto *task : tasks) {
    worker_pool_.assign_task(task);
  }
}
```

### 6.3 Task 完成回调

```cpp
// src/sql/px/ob_px_task.cpp:300
void ObPxTask::mark_done() {
  state_ = DONE;
  // 通知 coordinator:这个 task 完成
  coordinator_->on_task_done(this);
}

void ObPxCoord::on_task_done(ObPxTask *task) {
  // 1. 计数 done_tasks_++
  done_task_count_++;
  // 2. 如果所有 task 完成,触发下个 DFO
  if (done_task_count_ == total_task_count_) {
    schedule_next_dfo();
  }
}
```

---

## 7. Exchange 的实现细节

### 7.1 跨 DFO Exchange

```
DFO 1 (Scan t1)           DFO 2 (Join)
  Worker 1  ──hash(a)──►  Worker 1
  Worker 2  ──hash(b)──►  Worker 2
  Worker 3  ──hash(c)──►  Worker 3
```

数据按 `hash(join_key)` 分发,**保证 join key 相同的行落在同一个 worker**。

### 7.2 跨 OBServer Exchange

```
OBServer A (Scan t1)       OBServer B (Join)
  Worker 1  ───RPC────►   Worker 1
  Worker 2  ───RPC────►   Worker 2
```

跨 OBServer 通过 RPC(obrpc 协议)传输——比线程内交换慢。

### 7.3 Null-Aware Exchange

某些 join 类型(如 anti join with NULL)需要 **broadcast 所有 outer rows**
到每个 worker——broadcast exchange。

```cpp
// src/sql/px/ob_px_exchange_op.cpp:300
class ObPxBroadcastExchange : public ObPxExchangeOp {
public:
  int distribute(const ObRow &row) override {
    // 同一行发给所有 worker
    for (auto *ch : channels_) {
      ch->write(row);
    }
  }
};
```

Broadcast 适合 inner table 小的场景(避免 hash shuffle)。

---

## 8. 资源管理

### 8.1 内存控制

```cpp
// src/sql/px/ob_px_mem_control.cpp:50
class ObPxMemControl {
public:
  // 1. query 级内存上限
  int64_t query_mem_limit_;  // 默认 1GB
  // 2. 当前内存使用
  std::atomic<int64_t> mem_used_;
  // 3. 超限检查
  bool check_limit(int64_t need) {
    if (mem_used_ + need > query_mem_limit_) {
      return false;  // 超限
    }
    mem_used_ += need;
    return true;
  }
};
```

### 8.2 临时文件 Spill

```cpp
// src/sql/px/ob_px_spill.cpp:80
// 内存超限时,把中间结果写到磁盘
class ObPxSpill {
public:
  int spill_to_disk(ObPxChannel &ch) {
    // 1. 申请临时文件
    ObString tmp_file = "/tmp/px_spill_<uuid>.dat";
    // 2. 序列化 channel 数据
    while (ch.has_data()) {
      auto row = ch.read();
      write_to_file(tmp_file, row);
    }
    // 3. 重读时反序列化
    return OB_SUCCESS;
  }
};
```

### 8.3 资源隔离

```sql
-- 设置 query 并行度上限
ALTER SYSTEM SET max_parallel_degree = 32;

-- 设置 query 内存上限
ALTER SYSTEM SET px_max_memory_per_query = '4G';
```

---

## 9. 性能优化

### 9.1 并行度选择

```cpp
// src/sql/optimizer/ob_opt_parallel.cpp:80
// 优化器估算最优并行度
int estimate_parallel_degree(ObLogicalOperator *op) {
  // 1. 表行数 / 单核处理能力 = 理论并行度
  int64_t table_rows = get_table_rows(op);
  int64_t rows_per_cpu = 1000000;  // 每 CPU 100 万行
  int64_t theoretical = table_rows / rows_per_cpu;
  // 2. 限制在 [1, max_parallel_degree]
  return clamp(theoretical, 1, max_parallel_degree_);
}
```

### 9.2 数据倾斜

```cpp
// 优化器检测 hash 分发是否均匀
// 不均匀时,选 broadcast 而不是 hash

int ObOptimizer::select_exchange_mode(...) {
  // 1. 估算每个 worker 的行数
  int64_t rows_per_worker = total_rows / n_workers;
  // 2. 如果 NDV(join_key) < n_workers,可能倾斜
  //    → 选 broadcast exchange
  if (ndv < n_workers) {
    return PX_EXCHANGE_BCAST;
  }
  return PX_EXCHANGE_HASH;
}
```

### 9.3 Network 优化

```cpp
// src/sql/px/ob_px_net.cpp:50
// 跨 OBServer Exchange 用 batch + compression 优化
int ObPxNetChannel::send_batch(const ObRowBatch &batch) {
  // 1. 序列化 batch(整批,不是逐行)
  size_t len = serialize_batch(batch);
  // 2. 压缩(zstd)
  size_t compressed = compress(buf_, len);
  // 3. 单次 RPC 发送
  rpc_->send(peer_, buf_, compressed);
}
```

---

## 10. 监控与故障排查

### 10.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_px_stat\G

-- 关键字段:
-- px_worker_count_: worker 总数
-- px_running_task_count_: 当前运行 task 数
-- px_exchange_send_bytes_: 发送字节
-- px_exchange_recv_bytes_: 接收字节
-- px_spill_count_: spill 到磁盘次数
```

### 10.2 长并行 query 排查

```sql
-- 找运行 > 30s 的并行 query
SELECT * FROM oceanbase.__all_virtual_plan_monitor
WHERE elapsed_time_us_ > 30000000
  AND expected_worker_count_ > 1;
```

### 10.3 数据倾斜排查

```sql
-- 看每个 worker 的实际处理行数
SELECT worker_id_, processed_rows_
FROM oceanbase.__all_virtual_px_worker_stat
WHERE plan_id_ = <plan_id>;
```

如果 worker 间行数差距 > 10x,就是数据倾斜——考虑改写 SQL 或加 hint。

---

## 11. 调优 Checklist

```
□ Query 是否真的需要 PX?(小 query 并行反而慢)
□ parallel degree 是否合理?(默认 = CPU 数 / 2)
□ hash 分发 key 是否均匀?(避免 skew)
□ 内存是否够?(超限会 spill 到磁盘)
□ 网络是否够?(跨 OBServer exchange 走网络)
□ 临时文件是否充足?(spill 需要 /tmp 空间)
```

---

## 12. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → **#24 v2 (本文)** 是 OB **storage / index /
CBO / join / cache / 调优 / 日志 / 事务 / schema / 并行** 全主线:

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
| #21 v2 | Schema / DDL | 元数据层 | schema_version + INSTANT/INPLACE + Online DDL |
| **#24 v2 (本文)** | **PX Framework** | **并行层** | **Worker Pool + Task 调度 + Data Exchange + DAS** |

十二篇连起来,读者能完整理解 OB 的"单线程 → 多线程 → 多节点 → 调优"全
链路:

- 单线程执行:#14-#18 (MemTable + Index + CBO)
- 多线程 join:#41 (NL/Hash/Merge)
- IO 优化:#51 (Block Cache)
- 多线程并行:#24 (本文:PX + DAS)
- 调优:#29 (Slow Query)
- 持久化:#22 (Clog)
- 事务:#11 (Trans Service)
- 元数据:#21 (Schema)

---

## 13. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **主备 / Failover** — 深入 failover 流程(接 #22)
- **RPC / 网络层** — obrpc + 跨 OBServer 通信
- **监控 / 告警** — ASH 深入 + metrics 体系(接 #29)
- **#19-#20 / #25-#40 / #42-#100 系列**（待确认具体编号）

继续哪一篇?

---

## 14. 参考(可执行的源码锚点)

- `src/sql/px/ob_px_coord.h` — PX 协调器
- `src/sql/px/ob_px_physical_plan.h` — PX 物理计划
- `src/sql/px/ob_px_worker_pool.h` — Worker Pool
- `src/sql/px/ob_px_worker.cpp` — Worker 循环
- `src/sql/px/ob_px_scheduler.cpp` — Task 调度器
- `src/sql/px/ob_px_task.h` — Task 定义
- `src/sql/px/ob_px_exchange_op.h` — Data Exchange
- `src/sql/px/ob_px_dfo.cpp` — DFO 调度
- `src/sql/engine/das/ob_das_op.h` — DAS op
- `src/sql/engine/das/ob_das_join_op.cpp` — DAS Join
- `src/sql/px/ob_px_mem_control.cpp` — 内存控制
- `src/sql/px/ob_px_spill.cpp` — 临时文件 spill

---

#24 v2 完。