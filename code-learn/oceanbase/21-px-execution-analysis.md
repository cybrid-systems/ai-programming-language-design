# 21-px-execution — PX 并行执行：PX 调度、DTL 算子间数据传输

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

前 20 篇文章覆盖了 OceanBase 从存储引擎（MVCC、Memtable、SSTable、LS Tree）到 SQL 执行引擎（DAS 层、优化器、索引设计）再到分布式运维（分区迁移、备份恢复）的完整技术栈。

现在深入 SQL 执行引擎的最后一块核心拼图——**PX（Parallel eXecution）并行执行框架**。

当一条 SQL 被优化器生成执行计划后，PX 框架负责将其**跨节点、多线程并行执行**。OceanBase 的 PX 设计借鉴了 Oracle 的 PX 框架思想，但基于其分布式存储引擎做了大量适配。

### PX 的定位

```
SQL 客户端
    │
    ▼
解析器 → 优化器 → PX 执行框架 ←── 本文
                         │
                    ┌────┴────┐
                    │         │
               DAS 服务    Exchange 算子
                    │         │
               ┌────┘         └────┐
               │                    │
          存储引擎                 DTL 层
        (Memtable/SSTable)    (节点间数据传输)
```

### 核心概念

| 概念 | 缩写 | 职责 |
|------|------|------|
| **DFO** | Data Flow Operator | 可并行执行的算子树片段，PX 的最小调度单元 |
| **QC** | Query Coordinator | 查询协调者（`ObPxCoordOp`），管理整个 PX 查询生命周期 |
| **SQC** | Sub Query Coordinator | 子协调者（`ObPxSqcMeta`），管理单节点上的 Worker |
| **Worker** | PX Worker | 实际执行算子中 open/get_next_row/close 的线程 |
| **Exchange Op** | Transmit/Receive | 连接上游 DFO 和下游 DFO 的数据传输算子 |
| **DTL** | Data Transfer Layer | PX 数据交换的底层传输层，提供跨节点通道 |

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 09-sql-executor | DAS 层是 PX Worker 访问存储引擎的底层服务 |
| 17-query-optimizer | 优化器生成执行计划，PX 框架将其切分为 DFO |
| 19-partition-migration | PX 调度时需要考虑分区位置和迁移状态 |

---

## 1. 整体架构

### 1.1 三层架构

PX 执行框架分为三层：

```
┌──────────────────────────────────────────────────────────┐
│                    QC 层（协调层）                          │
│                                                          │
│  ObPxCoordOp                                              │
│    ├─ 管理 DFO DAG                                        │
│    ├─ 调度 DFO 到 SQC                                     │
│    ├─ 建立 DTL Channel 连接                               │
│    └─ 收集 Worker 返回的结果                               │
└──────────────────────┬───────────────────────────────────┘
                       │ RPC（init_sqc/init_task）
                       ▼
┌──────────────────────────────────────────────────────────┐
│                   SQC 层（调度层）                          │
│                                                          │
│  ObPxSqcMeta                                              │
│    ├─ 接收 QC 下发的 DFO 定义                              │
│    ├─ 反序列化执行计划                                     │
│    ├─ 创建 Worker 线程                                    │
│    └─ 管理 Worker 生命周期                                 │
└──────────────────────┬───────────────────────────────────┘
                       │ 本地线程创建
                       ▼
┌──────────────────────────────────────────────────────────┐
│                  Worker 层（执行层）                        │
│                                                          │
│  ObPxWorker                                               │
│    ├─ 执行 DFO 中的算子链                                  │
│    ├─ 通过 DTL Channel 与上下游通信                        │
│    └─ 通过 GranulePump 动态领取扫描任务                     │
└──────────────────────────────────────────────────────────┘
```

### 1.2 DFO DAG

PX 执行的核心是将执行计划切分为 DFO DAG（有向无环图）。每个 DFO 包含一组算子，DFO 之间通过 Exchange 算子连接。

```
  ┌───────── DFO 0 (Root) ─────────┐
  │  ObPxFifoCoordOp / MSCoordOp   │   ← 收集结果
  │      │                         │
  │  Exchange: ReceiveOp           │   ← 从子 DFO 接收数据
  └─────────────┬─────────────────┘
                │
  ┌─────────────▼─────────────────┐
  │       DFO 1 (Join)             │
  │  HashJoin / NestedLoopJoin    │
  │      │              │          │
  │  ReceiveOp    RepartReceiveOp │   ← 接收两个子 DFO 的数据
  └──────┬──────────────┬─────────┘
         │              │
  ┌──────▼──┐    ┌──────▼────────┐
  │ DFO 2   │    │  DFO 3        │
  │ Scan    │    │  Scan         │
  │Transmit │    │RepartTransmit │   ← 重分区后发送
  └─────────┘    └───────────────┘
```

---

## 2. 核心数据结构

### 2.1 ObPxCoordOp — 查询协调者（QC）

**文件**: `src/sql/engine/px/ob_px_coord_op.h` (第 32-157 行)

`ObPxCoordOp` 是整个 PX 查询的入口点。它是 SQL 算子模型中的一种特殊算子，继承自 `ObOpOperator`。

```cpp
class ObPxCoordOp : public ObOpOperator {
  // ... 核心成员
  ObPxCoordInfo coord_info_;            // 协调信息，含 DFO 管理器
  ObDfo *root_dfo_;                     // 根 DFO（最上层的协调 DFO）
  bool use_serial_scheduler_;           // 是否使用串行调度器
  int64_t px_sequence_id_;              // PX 序列 ID
  ObPxTimeRecorder time_recorder_;      // 性能计时器
  ObServerAliveChecker server_alive_checker_; // 节点存活检查器
};
```

**关键方法**（第 49-131 行）:

| 方法 | 作用 |
|------|------|
| `inner_open()` | 打开 QC，触发 DFO 调度 |
| `inner_close()` | 关闭 QC，清理资源 |
| `inner_drain_exch()` | Drain Exchange 通道 |
| `init_dfo_mgr()` | 初始化 DFO 管理器 |
| `terminate_running_dfos()` | 终止运行中的 DFO |
| `wait_all_running_dfos_exit()` | 等待所有 DFO Worker 退出 |
| `setup_loop_proc()` | 设置消息循环处理 |
| `check_all_sqc()` | 检查所有 SQC 状态 |
| `receive_channel_root_dfo()` | 接收根 DFO 的 Channel |

### 2.2 ObPxCoordInfo — 协调上下文

**文件**: `src/sql/engine/px/ob_px_scheduler.h` (第 106-177 行)

`ObPxCoordInfo` 是 QC 使用的协调上下文，包含 DFO 管理器、RPC 代理、消息循环等：

```cpp
class ObPxCoordInfo {
  // ...
  ObPxObDfoMgr dfo_mgr_;               // DFO 管理器
  ObPieceMsgCtxMgr piece_msg_ctx_mgr_;   // 分片消息上下文管理器
  ObPxRpcProxy rpc_proxy_;              // RPC 代理
  bool all_threads_finish_;             // 所有线程是否完成
  int first_error_code_;                // 首个错误码
  ObPxMsgLoop msg_loop_;                // 消息循环
  ObPxCoordOp *coord_;                  // 关联的 QC 算子
  ObP2PDfoMap p2p_dfo_map_;             // P2P DFO 映射
  RuntimeFilterDependencyInfo rf_dpd_info_; // 运行时过滤依赖信息
};
```

### 2.3 ObDfo — Data Flow Operator

**文件**: `src/sql/engine/px/ob_dfo.h` (第 478-842 行)

`ObDfo` 是 PX 框架最核心的数据结构，代表一个可并行执行的算子树片段。

**状态机**（第 48-54 行）:
```
WAIT → BLOCK → RUNNING → FINISH
                         → FAIL
```

**核心成员**（第 765-842 行）:

```cpp
class ObDfo {
  ObPhysicalPlan *phy_plan_;           // 物理执行计划
  const ObOpSpec *root_op_spec_;       // 根算子 Spec
  int64_t dop_;                         // Degree of Parallelism
  int64_t assigned_worker_cnt_;        // 分配的 Worker 数
  int64_t used_worker_cnt_;            // 实际使用的 Worker 数
  bool is_single_;                      // 是否为单线程 DFO
  bool is_root_dfo_;                    // 是否为根 DFO
  ObIArray<ObDfo*> child_dfos_;        // 子 DFO 列表
  ObDfo *parent_;                       // 父 DFO
  ObIArray<ObPxSqcMeta*> sqcs_;        // 该 DFO 上的所有 SQC
  ObIArray<ObPxTask*> tasks_;           // 该 DFO 的所有任务

  // 通道信息
  ObIArray<ObDfoChSet*> transmit_ch_sets_;  // Transmit Channel 集合
  ObIArray<ObDfoChSet*> receive_ch_sets_map_;// Receive Channel 集合
  ObIArray<ObDfoChInfo> dfo_ch_infos_;      // DFO Channel 信息

  // 分发策略
  ObGranuleMappingType in_slave_mapping_type_;
  ObGranuleMappingType out_slave_mapping_type_;
  ObPartChMap part_ch_map_;              // 分区 -> Channel 映射
  ObDistMethod dist_method_;             // 数据分发方法
};
```

**关键方法**（第 548-731 行）:

| 方法 | 作用 |
|------|------|
| `set_root_dfo() / is_root_dfo()` | 标识/判断根 DFO |
| `set_dop() / get_dop()` | 设置/获取并行度 |
| `set_single() / is_single()` | 单线程模式标识 |
| `set_phy_plan()` | 关联物理执行计划 |
| `append_child_dfo()` | 添加子 DFO，构建 DAG |
| `get_child_dfos()` | 获取所有子 DFO |
| `build_tasks()` | 在 DFO 上构建任务 |
| `prepare_channel_info()` | 准备通道信息 |
| `fill_channel_info_by_sqc()` | 按 SQC 填充通道信息 |
| `is_leaf_dfo()` | 是否为叶子 DFO（扫描类） |
| `has_scan_op()` | 是否包含扫描算子 |
| `has_dml_op()` | 是否包含 DML 算子 |
| `need_access_store()` | 是否需要访问存储 |

### 2.4 ObPxSqcMeta — 子协调者元数据

**文件**: `src/sql/engine/px/ob_dfo.h` (第 200-475 行)

`ObPxSqcMeta` 描述每个 SQC 的完整元数据，包含通道信息、位置信息、任务计数等。

```cpp
class ObPxSqcMeta {
  int64_t execution_id_;
  int64_t qc_id_;
  int64_t sqc_id_;
  int64_t dfo_id_;
  ObDtlChannel *qc_channel_;            // 与 QC 通信的 Channel
  ObDtlChannel *sqc_channel_;           // 与子任务通信的 Channel
  ObAddr exec_addr_;                     // 执行地址
  int64_t task_count_;                   // 任务数
  bool is_fulltree_;                     // 是否为全树模式
  ObIArray<ObTabletID> px_tablets_info_; // 涉及的 Tablet 信息
};
```

### 2.5 ObPxTask — 最小执行单元

**文件**: `src/sql/engine/px/ob_dfo.h` (第 958-1152 行)

Worker 实际执行的最小单位。一个 DFO 会拆分成多个 Task，分配给不同的 Worker。

```cpp
class ObPxTask {
  int64_t qc_id_, dfo_id_, sqc_id_, task_id_;
  ObDtlChannel *task_channel_;          // 任务数据通道
  ObDtlChannel *sqc_channel_;           // 与 SQC 的通信通道
  ObAddr exec_addr_;                     // 执行地址
  int rc_;                               // 执行结果
  bool is_use_local_thread_;             // 是否使用本地线程
  bool is_fulltree_;                     // 是否全树模式
  // ... 包含事务描述、影响行数、反馈信息等
};
```

### 2.6 ObPxWorker — Worker 线程

**文件**: `src/sql/engine/px/ob_px_worker.h`

Worker 线程接收 `ObPxTask` 后，执行其中的算子链（open → get_next_row → close）。Worker 的生命周期由 SQC 管理。

### 2.7 调度器类层次

**文件**: `src/sql/engine/px/ob_px_scheduler.h` (第 180-267 行)

```
ObDfoSchedulerBasic          ← 基础调度器
    │
    ├── ObPxTerminateMsgProc ← 终止消息处理
    │
    └── ObPxMsgProc          ← 通用消息处理
```

---

## 3. PX 查询完整数据流

### 3.1 时序图

```
QC (ObPxCoordOp)                SQC (ObPxSqcMeta)              Worker
      │                               │                           │
      │ 1. 优化器生成执行计划           │                           │
      │ 2. 切分 DFO DAG                │                           │
      │ 3. 计算 DFO 调度顺序            │                           │
      │                               │                           │
      │ 4. RPC: init_sqc ──────────→  │                           │
      │     (传递序列化的 DFO 定义)     │ 5. 反序列化执行计划        │
      │                               │ 6. 创建 Worker 线程        │
      │                               │                           │
      │                               │ 7. 分配 Task ─────────→   │
      │                               │     (传递 ObPxTask)       │
      │                               │                           │
      │                               │                           │ 8. Worker 初始化
      │                               │                           │    - 打开算子
      │                               │                           │    - 建立 DTL Channel
      │                               │                           │
      │ 9. 收到 SQC Init 完成消息 ←───│                           │
      │                               │                           │
      │10. 建立 DTL Channel 连接       │                           │
      │    (Transmit ↔ Receive)       │                           │
      │                               │                           │
      │                               │                           │11. 执行算子 get_next_row
      │                               │                           │    - 从 DTL 接收数据
      │                               │                           │    - 计算
      │                               │                           │    - 写入 DTL 发送
      │                               │                           │
      │12. 接收结果行                  │                           │
      │    ←────────── DTL Channel ──────────────────────────→   │
      │                               │                           │
      │13. 收到 SQC Finish 消息 ←─────│                           │
      │                               │                           │
      │14. 清理资源                   │                           │
      │    - 销毁 Channel              │                           │
      │    - 回收 Worker               │                           │
```

### 3.2 具体执行路径

#### 阶段一：QC Open

`ObPxCoordOp::inner_open()` 是 PX 执行的入口，其流程：

1. **初始化 DFO 管理器** (`init_dfo_mgr()`) — 从执行计划中解析 DFO DAG
2. **设置根 DFO** — 找到最上层的 CoordOp DFO
3. **初始化通道** — 建立 QC 与根 DFO 之间的 DTL Channel
4. **调度根 DFO** — `coord_info_->dfo_mgr_.schedule_root_dfo()`
5. **启动消息循环** — `setup_loop_proc()`
6. **等待结果** — 在消息循环中接收 SQC/Worker 的反馈

#### 阶段二：DFO 调度

调度器按依赖顺序调度 DFO：

1. 先调度**叶子 DFO**（TableScan 等不需要上游数据的算子）
2. 叶子 DFO 完成后，调度**中间 DFO**（Join 等需要组合数据的算子）
3. 最后调度**根 DFO**（收集最终结果）

调度过程：
- QC 通过 RPC (`init_sqc`) 将 DFO 定义发送到目标节点
- 目标节点的 `ObPxSqcHandler` 接收后，创建 SQC
- SQC 为该 DFO 创建 Worker 线程
- Worker 上创建算子实例

#### 阶段三：Channel 建立

Worker 初始化后，在 `ObPxTransmitOp::init_channel()` 和 `ObPxReceiveOp::init_channel()` 中建立 DTL Channel：

```
Producer DFO (TransmitOp)      Consumer DFO (ReceiveOp)
      │                               │
      │ 1. 创建 DTL Channel            │
      │    (OBDTL.create_channel)      │
      │                               │
      │ 2. 发送 Channel Ready 消息 ──→ │
      │                               │ 3. 接收 Channel Ready
      │                               │ 4. 链接 Channel 到 ReceiveOp
      │                               │
      │←── Receive 确认 ───────────── │
      │                               │
      │ 5. 开始发送数据                 │ 6. 开始接收数据
      │    (send_rows)                 │    (get_next_row)
```

#### 阶段四：数据执行

Worker 执行生命周期：
```
// 伪代码
worker.main() {
    task = get_assigned_task();
    op = task->get_root_op();
    op->open();
    while (op->get_next_row(row) == OB_SUCCESS) {
        // DFO 内部处理 row
        // 如果是中间层，通过 DTL 发送给下游
    }
    op->close();
}
```

#### 阶段五：结果收集

- 根 DFO 的 `ObPxFifoCoordOp` 或 `ObPxMSCoordOp` 收集所有 Worker 返回的行
- 通过 QC 的消息循环接收行数据
- QC 返回给上层 SQL 执行器

#### 阶段六：清理

1. `ObPxCoordOp::inner_close()` 被调用
2. `terminate_running_dfos()` — 终止所有运行中的 DFO
3. `wait_all_running_dfos_exit()` — 等待退出
4. `destroy_all_channel()` — 销毁 DTL Channel
5. `free_allocator()` — 释放内存

---

## 4. Exchange 算子体系

Exchange 算子位于 `src/sql/engine/px/exchange/` 目录，是连接 DFO 间的数据传输桥梁。

### 4.1 文件清单

```
exchange/
├── ob_px_transmit_op.h/.cpp          ← 基础发送算子
├── ob_px_receive_op.h/.cpp           ← 基础接收算子
├── ob_px_repart_transmit_op.h/.cpp   ← 重分区发送算子
├── ob_px_dist_transmit_op.h/.cpp     ← 分布式发送算子
├── ob_px_reduce_transmit_op.h/.cpp   ← 聚合发送算子
├── ob_px_ms_receive_op.h/.cpp        ← 合并排序接收
├── ob_px_ms_coord_op.h/.cpp          ← 合并排序协调
├── ob_px_fifo_coord_op.h/.cpp        ← FIFO 协调算子
├── ob_px_ordered_coord_op.h/.cpp     ← 有序协调算子
├── ob_transmit_op.h/.cpp             ← 底层 Transmit（非 PX）
├── ob_receive_op.h/.cpp              ← 底层 Receive（非 PX）
└── ob_row_heap.h/.cpp                ← 行堆（用于合并排序）
```

### 4.2 TransmitOp — 基础发送算子

**文件**: `src/sql/engine/px/exchange/ob_px_transmit_op.h` (第 100-556 行)

`ObPxTransmitOp` 是 Exchange 发送端的核心算子，负责将上游数据通过 DTL Channel 发送给下游。

**核心流程**：
```
child_op->get_next_row() → transmit(rows) → DTL Channel → ReceiveOp
```

**关键方法**（第 113-156 行）:

| 方法 | 作用 |
|------|------|
| `inner_open()` | 初始化通道、DFC（Data Flow Control） |
| `inner_get_next_row()` | 读上游并发送一行 |
| `inner_get_next_batch()` | 读上游并批量发送 |
| `transmit()` | 核心发送逻辑 |
| `init_channel()` | 初始化 DTL Channel |
| `init_dfc()` | 初始化流量控制 |
| `send_rows()` | 发送批量行 |
| `send_rows_one_by_one()` | 逐行发送 |
| `send_rows_in_batch()` | 批量发送 |
| `send_rows_in_vector()` | 向量化发送 |
| `broadcast_rows()` | 广播发送到所有通道 |
| `send_eof_row()` | 发送 EOF 信号 |

**内部数据结构**（第 459-556 行）:
```cpp
class ObPxTransmitOp {
  // 通道管理
  ObIArray<ObDtlChannel*> ch_blocks_;   // 通道块列表
  ObIArray<ObDtlChannel*> task_channels_;// 任务通道列表
  ObDtlChSet task_ch_set_;              // 通道集合
  bool transmited_;                      // 是否已发送
  bool iter_end_;                        // 是否结束迭代

  // 流量控制
  ObDfc dfc_;                            // Data Flow Control
  ObPxDfcUnblockMsgProc dfc_unblock_msg_proc_;

  // 向量化发送
  VectorSendParams params_;
  ObIArray<ObExpr*> vectors_;
  ObIArray<int64_t> selector_array_;
};
```

### 4.3 RepartTransmitOp — 重分区发送算子

**文件**: `src/sql/engine/px/exchange/ob_px_repart_transmit_op.h`

`RepartTransmitOp` 继承自 `ObPxTransmitOp`，在发送前根据分区键重新计算目标通道。

**重分区策略**:
- **Hash Repartition** — 对分区键做 Hash，均匀分布到下游 Worker
- **Range Repartition** — 按值范围分区
- **List Repartition** — 按值列表分区
- **Broadcast** — 广播到所有下游 Worker

**关键逻辑**:
```
repartition(rows) → 对每行计算 hash(range/list) → 确定目标 Channel → 发送
```

### 4.4 ReduceTransmitOp — 聚合发送算子

**文件**: `src/sql/engine/px/exchange/ob_px_reduce_transmit_op.h`

在发送前做部分聚合（Partial Aggregate），减少网络传输量。

典型使用场景：
```
SQL: SELECT SUM(salary) FROM employees GROUP BY dept_id

Worker 1: 计算 (dept_A, SUM=1000) → ReduceTransmit → Receive 侧做最终 SUM
Worker 2: 计算 (dept_A, SUM=2000) → ReduceTransmit → Receive 侧做最终 SUM
```

### 4.5 ReceiveOp — 基础接收算子

**文件**: `src/sql/engine/px/exchange/ob_px_receive_op.h` (第 89-242 行)

`ObPxReceiveOp` 从 DTL Channel 接收数据，返回给上游算子。

**关键方法**（第 95-156 行）:

| 方法 | 作用 |
|------|------|
| `inner_open()` | 初始化通道、DFC、消息循环 |
| `inner_get_next_row()` | 从通道读取一行 |
| `inner_drain_exch()` | Drain 通道 |
| `try_link_channel()` | 尝试链接通道 |
| `init_channel()` | 初始化接收通道 |
| `get_ch_set()` | 获取通道集合 |
| `active_all_receive_channel()` | 激活所有接收通道 |

### 4.6 MSReceiveOp — 合并排序接收

`ObPxMSReceiveOp` 用于 merge-sort，从多个通道按序读取数据。内部使用 `ObRowHeap` 做多路归并排序。

### 4.7 FIFOCoordOp / OrderedCoordOp — 协调算子

`ObPxFifoCoordOp` — 简单 FIFO 顺序汇集多个 Worker 的输出。
`ObPxOrderedCoordOp` — 保证输出顺序的协调（用于 ORDER BY 场景）。

---

## 5. DTL 数据传输层

DTL（Data Transfer Layer）位于 `src/sql/dtl/`，是 PX 数据交换的底层基础设施。

### 5.1 整体架构

```
                    ┌──────────────────┐
                    │   ObDtl (单例)    │
                    │   Channel 管理器  │
                    └───────┬──────────┘
                            │
          ┌─────────────────┼──────────────────┐
          │                 │                    │
   ┌──────▼──────┐  ┌──────▼──────┐   ┌──────▼──────┐
   │ LocalChannel │  │ RpcChannel  │   │BasicChannel  │
   │ (同进程传输) │  │ (跨进程传输) │   │ (基础抽象)   │
   └──────┬──────┘  └──────┬──────┘   └──────┬──────┘
          │                │                   │
   ┌──────▼──────┐  ┌──────▼──────┐           │
   │ChannelGroup │  │FlowControl  │           │
   └─────────────┘  └─────────────┘           │
                                              │
   ┌──────────────────────────────────────────┘
   │
   ┌▼────────────────┐
   │ Channel Manager │
   │ (通道哈希表管理) │
   └─────────────────┘
```

### 5.2 ObDtl — DTL 全局管理器

**文件**: `src/sql/dtl/ob_dtl.h` (第 89-160 行)

`ObDtl` 是全局单例，管理所有 DTL Channel：

```cpp
class ObDtl {
  bool is_inited_;
  common::ObArenaAllocator allocator_;
  ObDtlRpcProxy *rpc_proxy_;          // RPC 代理
  ObDfcServer *dfc_server_;           // 流量控制服务器
  ObDtlHashTable hash_table_;         // Channel 哈希表（按 ID 查找）
  ObDtlChannelManager ch_mgrs_[HASH_CNT]; // 多组 Channel Manager
};
```

**关键方法**（第 96-147 行）:

| 方法 | 作用 |
|------|------|
| `init()` | 初始化 DTL 全局实例 |
| `create_channel()` | 创建通道（自动选择本地或 RPC） |
| `create_local_channel()` | 创建本地通道（同进程） |
| `create_rpc_channel()` | 创建 RPC 通道（跨进程） |
| `destroy_channel()` | 销毁通道 |
| `get_channel()` | 按 ID 查找通道 |
| `remove_channel()` | 移除通道 |

### 5.3 ObDtlChannel — 数据传输通道

**文件**: `src/sql/dtl/ob_dtl_channel.h`

`ObDtlChannel` 是 DTL 数据传输的基本抽象，支持：
- **同步/异步读写** — 通过 `write()` / `read()` 接口
- **批量传输** — 支持行批量和向量化
- **流量控制** — 背压（Backpressure）机制

Channel 类型：
- `ObDtlLocalChannel` — 同进程内传输（共享内存 Buffer）
- `ObDtlRpcChannel` — 跨进程传输（基于 ObRpc）

### 5.4 ObDtlChannelGroup — 通道组

**文件**: `src/sql/dtl/ob_dtl_channel_group.h`

将多个 Channel 组织为一组，实现：
- **统一管理** — 批量发送、统一 EOF
- **负载均衡** — 在多个 Channel 间分发数据
- **故障隔离** — 单个 Channel 故障不影响整体

### 5.5 流量控制

**文件**: `src/sql/dtl/ob_dtl_flow_control.h`

#### 背压机制

```
Producer → DTL Channel → Consumer
              │
         Flow Control
              │
    ┌─────────┴──────────┐
    │ Buffer 满 → Producer 阻塞│
    │ Buffer 空 → Consumer 阻塞│
    └────────────────────┘
```

- `ObDtlFlowControl` — 流量控制策略
- `ObDfcServer` — 流量控制服务器
- 当接收端处理慢时，发送端会被阻塞，防止内存溢出

### 5.6 DTL 中间结果

**文件**: `src/sql/dtl/ob_dtl_interm_result_manager.h`

支持将 DTL Channel 的数据持久化为中间结果（Interm Result），用于：
- **Rescan** — 重复扫描同一个 DFO 的结果
- **Batch Rescan** — PX Batch Rescan 优化中的中间结果复用

### 5.7 DTL 内存管理

**文件**: `src/sql/dtl/ob_dtl_channel_mem_manager.h`, `ob_dtl_tenant_mem_manager.h`

- `ObDtlChannelMemManager` — Channel 级内存管理
- `ObDtlTenantMemManager` — 租户级内存管理，防止 PX 打爆租户内存

### 5.8 DTL 文件清单

```
src/sql/dtl/
├── ob_dtl.h                    ← DTL 全局管理器
├── ob_dtl_channel.h            ← 通道抽象接口
├── ob_dtl_channel_group.h      ← 通道组
├── ob_dtl_channel_agent.h      ← 通道代理
├── ob_dtl_channel_loop.h       ← 通道消息循环
├── ob_dtl_channel_mem_manager.h ← 通道内存管理
├── ob_dtl_channel_watcher.h    ← 通道监控
├── ob_dtl_flow_control.h       ← 流量控制
├── ob_dtl_fc_server.h          ← 流量控制服务器
├── ob_dtl_local_channel.h      ← 本地通道
├── ob_dtl_rpc_channel.h        ← RPC 通道
├── ob_dtl_basic_channel.h      ← 基础通道实现
├── ob_dtl_buf_allocator.h      ← 缓冲区分配器
├── ob_dtl_linked_buffer.h      ← 链表缓冲区
├── ob_dtl_vectors_buffer.h     ← 向量化缓冲区
├── ob_dtl_local_first_buffer_manager.h ← 本地优先缓冲管理
├── ob_dtl_interm_result_manager.h ← 中间结果管理
├── ob_dtl_tenant_mem_manager.h ← 租户内存管理
├── ob_dtl_msg.h                ← 消息定义
├── ob_dtl_msg_type.h           ← 消息类型
├── ob_dtl_processor.h          ← 消息处理器
├── ob_dtl_task.h               ← DTL 任务
├── ob_dtl_rpc_proxy.h          ← RPC 代理
├── ob_dtl_rpc_processor.h      ← RPC 处理器
└── ob_op_metric.h              ← 算子指标
```

---

## 6. Granule — 数据分片并行

### 6.1 背景

在 PX 中，如果多个 Worker 要并行扫描一张大表，需要将扫描范围切分成多个小块（Granule），由 Worker **动态领取**。这种方式相比静态分配更均衡，能解决**数据倾斜**问题。

### 6.2 GranulePump 架构

```
          ┌──────────────────────────────────────────┐
          │           ObGranulePump                    │
          │                                           │
          │  shared_pool_ ── 全局 Granule 共享池       │
          │  ├─ 包含所有待扫描的 Tablet + Range        │
          │  ├─ Worker 从中领取 Granule               │
          │  └─ 锁保护（spin_lock）                     │
          │                                           │
          │  worker_local_ ── Worker 本地缓存          │
          │  └─ 提前领取一批，减少锁竞争               │
          └─────────────────┬────────────────────────┘
                            │
              ┌─────────────┼─────────────┐
              │             │              │
         Worker 1     Worker 2     Worker N
              │             │              │
          fetch_granule  fetch_granule  fetch_granule
```

### 6.3 核心数据结构

**文件**: `src/sql/engine/px/ob_granule_pump.h`

#### ObGranulePumpArgs（第 76-151 行）
Worker 的 Granule 领取参数，包含：
```cpp
class ObGranulePumpArgs {
  ObGranulePumpOpInfo op_info_;        // 算子信息
  ObIArray<ObTabletID> tablet_arrays_; // Tablet 列表
  int64_t parallelism_;                // 并行度
  int64_t tablet_size_;                // Tablet 大小（用于拆分）
  int64_t pump_version_;               // Pump 版本（用于 Rescan）
};
```

#### ObGranulePump（第 406-590 行）

**关键方法**:

| 方法 | 作用 |
|------|------|
| `init_pump_args()` | 初始化 Pump 参数 |
| `fetch_granule_task()` | Worker 领取一个 Granule 任务 |
| `fetch_granule_from_shared_pool()` | 从共享池领取 |
| `fetch_granule_by_worker_id()` | 按 Worker ID 领取 |
| `fetch_pw_granule_from_shared_pool()` | Partition-Wise Join 场景下的领取 |
| `add_new_gi_task()` | 添加新的 GI 任务 |
| `regenerate_gi_task()` | 重新生成 GI 任务（Rescan） |
| `fill_shared_pool()` | 填充共享池 |
| `refill_pump_with_new_gen_tasks()` | 用新生成的任务重新填充（运行时剪枝） |

#### GranuleSplitter 类层次

`ObGranulePump` 使用不同的 Splitter 将 Tablet/Range 切分成 Granule：

```
ObGranuleSplitter
    ├── ObRandomGranuleSplitter          ← 随机切分（默认）
    ├── ObAccessAllGranuleSplitter       ← 全量访问切分
    ├── ObPartitionWiseGranuleSplitter   ← Partition-Wise Join 切分
    ├── ObAffinitizeGranuleSplitter      ← 亲和性切分
    │   ├── ObNormalAffinitizeGranuleSplitter    ← 普通亲和性
    │   └── ObPWAffinitizeGranuleSplitter        ← PW 亲和性
    └── ObGranuleSplitter 也负责运行时剪枝（runtime partitioning pruning）
```

### 6.4 动态领取 vs 静态分配

| 方式 | 优点 | 缺点 | 适用场景 |
|------|------|------|----------|
| **动态领取** | 负载均衡好，抗倾斜 | 有锁竞争 | 大表扫描，数据分布不均 |
| **静态分配** | 无锁，性能高 | 易倾斜 | 小表，数据均匀，PWJ |

OceanBase 的 GranulePump 采用**先静态分配 + 后动态领取**的混合策略：
1. 首次分配：按 Worker 数量均分 Tablet
2. 动态补货：Worker 扫描完本地任务后，从共享池领取更多

### 6.5 Granule Iterator Op

**文件**: `src/sql/engine/px/ob_granule_iterator_op.h`

`ObGranuleIteratorOp` 是 Granule 扫描迭代器算子，位于 TableScan 之上：

```
GranuleIteratorOp ← 管理 Granule 领取
    │
    ▼
TableScanOp ← 实际扫描数据
```

Granule 领取触发时机：
1. `open()` — 领取第一个 Granule
2. `get_next_row()` 返回 OB_ITER_END — 领取下一个 Granule
3. 所有 Granule 完成 → 返回 OB_ITER_END

---

## 7. Worker 线程与 Admission Control

### 7.1 Worker 生命周期

Worker 线程的生命周期由 SQC 管理：

```
SQC 创建 Worker (ObPxWorkerEnv)
    │
    ▼
Worker 初始化
    ├─ 设置执行上下文（ObExecContext）
    ├─ 反序列化执行计划
    ├─ 创建算子实例
    └─ 建立 DTL Channel
    │
    ▼
Worker 执行
    ├─ root_op->open()
    ├─ while (root_op->get_next_row() == SUCCESS)
    │   └─ 数据处理（视 DFO 而定）
    └─ root_op->close()
    │
    ▼
Worker 完成
    ├─ 发送结果回 SQC
    └─ 线程退出
```

### 7.2 PX Admission Control

**文件**: `src/sql/engine/px/ob_px_admission.h`

PX 需要防止过多的并行执行压垮集群。Admission Control 负责决定是否允许一个新的 PX 查询进入。

#### ObPxAdmission（第 37-54 行）

```cpp
class ObPxAdmission {
  bool admit();                              // 是否允许进入
  int enter_query_admission(ObSQLSessionInfo *session,
                            ObPhysicalPlan *plan,
                            ObExecContext *ctx); // 进入 Admission
  void exit_query_admission(ObSQLSessionInfo *session); // 退出
  int64_t get_parallel_session_target();     // 获取会话级并行目标
};
```

#### ObPxSubAdmission（第 60-66 行）

```cpp
class ObPxSubAdmission {
  bool acquire();   // 获取一个子 admission 资源
  void release();   // 释放
};
```

**Admission 策略**:
1. **服务器级限制** — 全局最大并行 Worker 数
2. **租户级限制** — 每个租户的并行度配额
3. **SQL 级限制** — 单条 SQL 的 `PARALLEL` hint 控制
4. **自适应 DOP** — `get_adaptive_px_dop()` 根据系统负载动态调整

---

## 8. 设计决策

### 8.1 DFO 切分策略

什么可以切分到一个 DFO？
- **可并行算子**：TableScan、HashJoin 的 Probe 侧、Aggregate
- **不可并行**：Limit（无排序时）、某些特殊的 DML 操作

DFO 切分的边界：
- Exchange 算子天然是 DFO 边界
- TransmitOp 在子 DFO 的出口
- ReceiveOp 在父 DFO 的入口

### 8.2 Repartition 策略选择

| 策略 | 方式 | 适用场景 |
|------|------|----------|
| **Hash** | `hash(col) % n` | 通用，数据均衡 |
| **Range** | 按值范围分配 | 排序合并 Join |
| **Broadcast** | 全量广播 | 小表广播给所有 Worker |
| **Hybrid** | Hash + Range 混合 | 窗口函数等复杂场景 |

### 8.3 自适应 DOP

OceanBase 支持根据运行时的负载动态调整并行度：

- `get_adaptive_px_dop()` — 在 `ObPxCoordOp` 中实现
- 基于系统空闲线程数、内存压力、IO 负载等指标
- 避免在系统繁忙时启动过多 Worker

### 8.4 PX 内存管理

- **DTL Buffer 限制** — `ObDtlTenantMemManager` 防止单租户占用过多内存
- **Channel 流量控制** — 背压机制防止生产者过快
- **中间结果管理** — `ObDtlIntermResultManager` 控制中间结果的总大小

### 8.5 运行时剪枝（Runtime Pruning）

在扫描过程中，GranulePump 支持**运行时分区剪枝**：
1. Worker 1 扫描后生成 Runtime Filter（Bloom Filter 或 Min/Max）
2. 通过 DTL Channel 传递给下游
3. 下游的 GranulePump 根据 Filter 跳过不需要扫描的 Tablet

### 8.6 P2P Direct Channel

对于某些特殊场景（如临时表、ODPS 外表），PX 支持 P2P（Peer-to-Peer）的直接通道：
- `ObP2PDfoMap` — 维护 P2P DFO 映射
- `ObP2PDfoMapNode` — 单个 P2P 映射节点
- 绕过 QC，直接在 Worker 间建立数据传输通道

### 8.7 Batch Rescan

对于需要多次扫描的子查询（如 IN 子查询），PX 支持 **Batch Rescan**：
1. 第一次扫描后将中间结果保存在 DTL 缓存中
2. 后续 rescan 直接从缓存读取
3. `ob_px_batch_rescan.h` — Batch Rescan 控制逻辑

---

## 9. 关键代码索引

| 文件 | 行号 | 内容 |
|------|------|------|
| `src/sql/engine/px/ob_px_coord_op.h` | 32-157 | `ObPxCoordOp` — QC 协调算子 |
| `src/sql/engine/px/ob_px_scheduler.h` | 106-177 | `ObPxCoordInfo` — 协调上下文 |
| `src/sql/engine/px/ob_px_scheduler.h` | 180-267 | `ObDfoSchedulerBasic` / `ObPxMsgProc` — 调度器 |
| `src/sql/engine/px/ob_dfo.h` | 478-842 | `ObDfo` — DFO 核心定义 |
| `src/sql/engine/px/ob_dfo.h` | 48-54 | `ObDfoState` — DFO 状态机 |
| `src/sql/engine/px/ob_dfo.h` | 200-475 | `ObPxSqcMeta` — SQC 元数据 |
| `src/sql/engine/px/ob_dfo.h` | 958-1152 | `ObPxTask` — PX 任务 |
| `src/sql/engine/px/ob_px_worker.h` | — | `ObPxWorker` — Worker 线程 |
| `src/sql/engine/px/ob_px_admission.h` | 37-66 | `ObPxAdmission` / `ObPxSubAdmission` |
| `src/sql/engine/px/exchange/ob_px_transmit_op.h` | 100-556 | `ObPxTransmitOp` — 发送算子 |
| `src/sql/engine/px/exchange/ob_px_receive_op.h` | 89-242 | `ObPxReceiveOp` — 接收算子 |
| `src/sql/engine/px/exchange/ob_px_repart_transmit_op.h` | — | `ObPxRepartTransmitOp` — 重分区发送 |
| `src/sql/engine/px/exchange/ob_px_reduce_transmit_op.h` | — | `ObPxReduceTransmitOp` — 聚合发送 |
| `src/sql/engine/px/exchange/ob_px_ms_receive_op.h` | — | `ObPxMSReceiveOp` — 合并排序接收 |
| `src/sql/engine/px/exchange/ob_px_fifo_coord_op.h` | — | `ObPxFifoCoordOp` — FIFO 协调 |
| `src/sql/engine/px/ob_granule_pump.h` | 406-590 | `ObGranulePump` — Granule 分发器 |
| `src/sql/engine/px/ob_granule_pump.h` | 288-397 | Granule Splitter 类层次 |
| `src/sql/engine/px/ob_granule_iterator_op.h` | — | `ObGranuleIteratorOp` — Granule 迭代器 |
| `src/sql/dtl/ob_dtl.h` | 89-160 | `ObDtl` — DTL 全局管理器 |
| `src/sql/dtl/ob_dtl_channel.h` | — | `ObDtlChannel` — 通道抽象 |
| `src/sql/dtl/ob_dtl_channel_group.h` | — | `ObDtlChannelGroup` — 通道组 |
| `src/sql/dtl/ob_dtl_flow_control.h` | — | 流量控制 |
| `src/sql/dtl/ob_dtl_local_channel.h` | — | 本地通道实现 |
| `src/sql/dtl/ob_dtl_rpc_channel.h` | — | RPC 通道实现 |
| `src/sql/dtl/ob_dtl_interm_result_manager.h` | — | 中间结果管理 |
| `src/sql/dtl/ob_dtl_tenant_mem_manager.h` | — | 租户内存管理 |

---

## 10. 总结

PX 并行执行框架是 OceanBase SQL 执行引擎的核心能力之一。通过本文分析，可以看到其设计特点：

1. **三层解耦架构** — QC/SQC/Worker 各司其职，通过 RPC 通信
2. **DFO DAG 调度** — 将执行计划切分为可并行执行的片段，按依赖顺序调度
3. **丰富的 Exchange 算子体系** — 支持 Hash/List/Range/Broadcast 等多种分区策略
4. **DTL 传输层** — 完整的本地 + RPC 通道实现，含流量控制和内存管理
5. **Granule 动态领取** — 解决 Worker 间数据倾斜问题
6. **Admission Control** — 多层级并发控制，防止 PX 打爆集群

下一步可以深入分析：**DFC（Data Flow Control）的详细实现**、**PX 中的 Runtime Filter 技术**、**PX Batch Rescan 优化** 等专题。
