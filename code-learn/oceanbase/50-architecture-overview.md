# 50 — 系统架构总览：50 篇全景图、数据流与模块依赖

> OceanBase CE 主线源码深度分析系列 · 收官篇
> 回顾 49 篇文章、~40,000 行分析内容

---

## 0. 写在前面

这是一场历时 50 篇的源码漫游。我们从磁盘最底层的 macro block 起步，穿过 MVCC 版本链、Memtable 哈希表、SSTable 编码格式、Paxos 日志复制、SQL 解析优化、PX 并行执行，一路走到网络层的 MySQL 协议处理。50 篇文章覆盖了 OceanBase 从硬件抽象到 SQL 运行时的完整软件栈。

本文不是新的源码分析。它是一张地图，一张整理了我们走过的所有路径、标注了每个模块的位置和关系的全景图。如果你只读一篇来理解 OceanBase 的整体架构，读这篇就够了。

---

## 1. 分层架构全景

OceanBase 的架构从顶到底可以划分为 **7 个层次**，每个层面向下层提出服务契约，向上层隐藏实现细节：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     SQL Layer — SQL 解析、优化与执行                       │
│  ┌────────┐  ┌────────┐  ┌────────┐  ┌──────────┐  ┌───────────┐       │
│  │ MySQL  │  │        │  │        │  │          │  │           │       │
│  │Protocol│→│ Parser │→│Resolver│→│Optimizer│→│ PlanCache │       │
│  │  (40)  │  │ (23)   │  │  (23)  │  │   (17)   │  │   (22)    │       │
│  └────────┘  └────────┘  └────────┘  └──────────┘  └───────────┘       │
│                          │                                              │
│                          ▼                                              │
│  ┌────────┐  ┌────────┐  ┌────────┐  ┌──────────┐  ┌──────────┐       │
│  │  PX    │  │  DML   │  │  Join  │  │  Aggr   │  │  Sort/   │       │
│  │ (21)   │  │ (31)   │  │ (41)   │  │  (43)   │  │  Window  │       │
│  └────────┘  └────────┘  └────────┘  └──────────┘  └───(42)───┘       │
├─────────────────────────────────────────────────────────────────────────┤
│               DAS Layer — Data Access Service                           │
│  ┌────────────────────────┐  ┌────────────────────────┐                 │
│  │   Data Access Service  │  │   Location Router      │                 │
│  │       (09)             │  │       (37)             │                 │
│  └────────────────────────┘  └────────────────────────┘                 │
├─────────────────────────────────────────────────────────────────────────┤
│               MVCC Layer — 多版本并发控制                                │
│  ┌────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┐              │
│  │ MVCC   │  │ Iterator │  │ Callback │  │ Compact  │  │              │
│  │ Row    │→│ (02)     │→│ (04)     │→│ & GC     │  │              │
│  │ (01)   │  │          │  │          │  │ (05)     │  │              │
│  └────────┘  └──────────┘  └──────────┘  └──────────┘  │              │
│       │           │            │                         │              │
│       ▼           ▼            ▼                         ▼              │
│  ┌────┴───────────┴────────────┴─────────────────────────┴──┐          │
│  │     写冲突检测: Row Conflict Handler (03, 16)              │          │
│  └──────────────────────────────────────────────────────────┘          │
├─────────────────────────────────────────────────────────────────────────┤
│               Memtable — 内存写入缓冲区                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                  │
│  │  Hash Table  │→│   Row Data   │→│   Freezer    │                   │
│  │   (14, 15)   │  │  (14)       │  │   (06)       │                   │
│  └──────────────┘  └──────────────┘  └──────────────┘                  │
├─────────────────────────────────────────────────────────────────────────┤
│               Storage — 持久化存储层                                      │
│  ┌────────┐  ┌──────────┐  ┌──────────┐  ┌────────────┐  ┌────────┐   │
│  │SSTable │→│ Encoding │→│ Macro    │→│  Block     │→│  IO    │   │
│  │ (08)   │  │ (26)     │  │ Block    │  │  Manager   │  │ (44)   │   │
│  │        │  │          │  │ (35)     │  │  (34, 35)  │  │        │   │
│  └────────┘  └──────────┘  └──────────┘  └────────────┘  └────────┘   │
├─────────────────────────────────────────────────────────────────────────┤
│               Consensus — 分布式一致性层                                  │
│  ┌────────┐  ┌──────────┐  ┌────────┐  ┌────────────┐  ┐              │
│  │  PALF  │→│ Election │→│  Clog  │→│ Checkpoint  │  │              │
│  │ (11)   │  │ (12)     │  │ (13)   │  │ (48)        │  │              │
│  └────────┘  └──────────┘  └────────┘  └────────────┘  │              │
│                                    ┌───────────────┐   │              │
│                                    │ Log Service   │   │              │
│                                    │ (49)          │───┘              │
│                                    └───────────────┘                  │
├─────────────────────────────────────────────────────────────────────────┤
│               Coordination — 集群协调层                                   │
│  ┌───────────┐  ┌───────────┐  ┌──────────────┐  ┌────────────┐       │
│  │RootServer │→│    GTS    │→│   Locality   │→│   Tenant   │       │
│  │   (27)    │  │   (28)    │  │    (47)      │  │   (39)     │       │
│  └───────────┘  └───────────┘  └──────────────┘  └────────────┘       │
└─────────────────────────────────────────────────────────────────────────┘
```

每个层只与相邻层通信。SQL 层从不直接操作磁盘块；共识层不知道什么是 MVCC 版本链。这种严格的分层是 OceanBase 能在数千万行代码中保持可维护性的关键。

---

## 2. 数据流路径：一条 SQL 的完整旅程

一条 `SELECT * FROM t1 WHERE id = 42` 从客户端发出到返回结果，走过了整条路径。我们把它完整地画出来：

```
MySQL Client (JDBC/ODBC/mysql CLI)
    │
    │  TCP 连接 (libeasy 事件驱动)
    ▼
┌─────────────────────────────────────┐
│ ObSMHandler (40)                    │
│  · 握手 / 认证                      │
│  · 包解析 → ObMPQuery              │
│  · 会话分配                         │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│ ObSrvMySQLXlator::translate() (40)  │
│  · MySQL 命令 → 处理器分派          │
│  · COM_QUERY → ObMPQueryHandler     │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│ Parser (23)                         │
│  · SQL 文本 → Lex → Yacc           │
│  · Result Tree (ParseNode 树)       │
│  · 语法错误检测                     │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│ Resolver (23)                       │
│  · ParseNode → Statement AST        │
│  · 元数据绑定 (表/列/类型查询)       │
│  · 类型推导 & 隐式转换               │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│ Optimizer (17)                      │
│  · 逻辑优化 (谓词下推/子查询展开)    │
│  · 代价估算 & 计划枚举              │
│  · 索引选择 / Join 顺序             │
│  · 分布式计划生成                   │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│ PX Scheduler (21) / PX DFO          │
│  · 并行度决定 (DOP)                 │
│  · DTL 通道建立                     │
│  · 计划切分 → DF0 / DF1 / ...      │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│ DAS Service (09)                    │
│  · 存储层请求入口                   │
│  · RowID / Tablet Scan / Get        │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│ Location Router (37)                │
│  · 分区键 → 目标 Tablet             │
│  · 本地 / 远端重定向                │
│  · 位置缓存查找                     │
└────────────┬────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐  ┌──────────────────────┐
│ Tablet Scan (MVCC Iterator)        │  │ 检查 Memtable        │
│  · ObMvccEngine::get() → Iterator  │──│  · Hash 查找 rowkey   │
│  · 定位 read transaction           │  │  · 可见性判断 (snap)  │
│  · 准备 snapshot_version           │  │  · 返回最新可见版本    │
└────────────┬────────────────────────┘  └──────────────────────┘
             │                                    │
             ▼                                    ▼
┌──────────────────────┐              ┌──────────────────────────┐
│ SSTable Reader (08)  │              │ Memtable Row (01, 14)    │
│  · Block Cache 查找   │              │  · TransNode 链表遍历    │
│  · Micro Block 解码   │              │  · trans_version 比较   │
│  · Row 重建           │              │  · 返回正确版本          │
└──────┬───────────────┘              └──────────────────────────┘
       │                                        │
       └──────────────┬─────────────────────────┘
                      │
                      ▼ (两路结果合并)
┌──────────────────────────────────────────┐
│ IO Scheduler (44)                        │
│  · mClock 公平调度                       │
│  · 预读 / 批量读取                       │
│  · ObIODevice → AIO / io_uring           │
└──────────────────┬───────────────────────┘
                   │
                   ▼ (如果是冷数据/未命中缓存)
┌──────────────────────────────────────────┐
│ Disk (本地文件系统 / OSS / S3)            │
│  · Macro Block Layout (35)               │
│  · Checksum 验证 (46)                    │
│  · 返回原始字节                          │
└──────────────────────────────────────────┘
```

**关键观察**：这条路径跨越了 7 个架构层，但每一层都只做自己分内的事。协议层不包含任何业务逻辑，存储层不解析 SQL，MVCC 层不关心 Paxos 日志提交。横切关注点（Checksum、Latch、内存管理）则在每层中以内联方式存在。

---

## 3. 50 篇文章的层次结构

以下是 50 篇完整文章按架构层次的分类总览：

### 存储引擎核心（文章 01–10）

| 篇号 | 主题 | 核心文件 / 路径 |
|------|------|----------------|
| 01 | **MVCC Row** — 版本链行结构 | `src/storage/memtable/mvcc/ob_mvcc_row.h` |
| 02 | **MVCC Iterator** — 读取器与可见性判断 | `src/storage/memtable/mvcc/ob_mvcc_iterator.h` |
| 03 | **写写冲突检测** — 锁等待与诊断 | `src/storage/memtable/mvcc/ob_mvcc_row.cpp` |
| 04 | **提交回调链** — Callback 与事务状态机 | `src/storage/memtable/mvcc/ob_mvcc.h` |
| 05 | **Compact & GC** — 版本链压缩 | `src/storage/memtable/mvcc/ob_mvcc_row_compact.h` |
| 06 | **Freezer** — Memtable 冻结与持久化 | `src/storage/memtable/ob_memtable.h` |
| 07 | **LogStream & LS Tree** — 存储容器架构 | `src/storage/ob_ls.h` |
| 08 | **SSTable** — 存储格式与块编码 | `src/storage/sstable/ob_sstable.h` |
| 09 | **DAS 层** — SQL 执行器与存储交互 | `src/sql/das/` |
| 10 | **分布式事务** — 2PC 与事务管理器 | `src/storage/tx/ob_trans_service.h` |

**核心发现**：OceanBase 的 MVCC 实现采用了"数据包含版本链"的嵌入式设计——`ObMvccTransNode` 通过双向链表串联所有历史版本，通过 `snapshot_version` 实现无锁读取。事务提交版本必须等待 Paxos 日志落盘才算正式确立，这是分布式 MVCC 与传统单机 MVCC 的本质区别。

### 分布式共识（文章 11–20）

| 篇号 | 主题 | 核心文件 / 路径 |
|------|------|----------------|
| 11 | **PALF** — Paxos 日志框架 | `src/logservice/palf/` |
| 12 | **Election** — 选主与故障切换 | `src/logservice/election/` |
| 13 | **Clog** — 日志回放 | `src/logservice/clog/` |
| 14 | **Memtable 内部结构** — Hash 表与行存 | `src/storage/memtable/ob_memtable.h` |
| 15 | **KeyBtree** — 自研 B-Tree | `src/storage/memtable/ob_key_btree.h` |
| 16 | **行级冲突处理** — 完整冲突路径 | `src/storage/memtable/mvcc/ob_row_conflict_handler.h` |
| 17 | **查询优化器** — 计划生成与代价估算 | `src/sql/optimizer/` |
| 18 | **索引设计** — 局部/全局索引 | `src/sql/optimizer/` |
| 19 | **分区迁移** — Rebalance 与 Transfer | `src/rootserver/` |
| 20 | **备份恢复** — 数据保护机制 | `src/storage/backup/` |

**核心发现**：PALF 是 OceanBase 分布式共识的灵魂。它不是简单的 Paxos 实现——它将日志结构抽象为文件系统和数据库的混合体，支持成员变更（文章 38）、Learner 同步、日志截断等特性。Clog 回放路径标志着写路径和读路径在 PALF 处的分叉：写路径是 LogService → PALF Propose，读路径是 PALF → Clog Replay → SSTable。

### SQL 执行器（文章 21–30）

| 篇号 | 主题 | 核心文件 / 路径 |
|------|------|----------------|
| 21 | **PX 并行执行** — 调度与 DTL | `src/sql/engine/px/` |
| 22 | **PlanCache** — 执行计划缓存 | `src/sql/plan_cache/` |
| 23 | **Parser & Resolver** — SQL 文本到解析树 | `src/sql/parser/` |
| 24 | **类型系统** — ObObj、ObDatum、ObString | `deps/oblib/src/common/object/` |
| 25 | **内存管理** — Allocator 与内存池 | `deps/oblib/src/lib/alloc/` |
| 26 | **编码引擎** — MicroBlock 编码器 | `src/storage/blocksstable/encoding/` |
| 27 | **RootServer** — 元数据与集群协调 | `src/rootserver/` |
| 28 | **GTS** — 全局时间戳与分布式授时 | `src/rootserver/gts/` |
| 29 | **SQL 诊断** — Plan Monitor 与 SQL Audit | `src/sql/monitor/` |
| 30 | **OBServer 启动** — 模块初始化与服务注册 | `src/observer/ob_server.h` |

**核心发现**：RootServer 是 OceanBase 集群的"大脑"。它管理元数据、分配分区、调度备份、监控健康。其他 OBServer 通过心跳（Heartbeat）向 RootServer 注册并汇报状态。GTS 则是分布式事务的"时钟"——所有事务的 snapshot_version 和 trans_version 都需要 GTS 来确权，没有精确的全局时间戳就没有正确的分布式 MVCC。

### SQL 算子实现（文章 31–40）

| 篇号 | 主题 | 核心文件 / 路径 |
|------|------|----------------|
| 31 | **DML 执行路径** — INSERT/UPDATE/DELETE | `src/sql/engine/dml/` |
| 32 | **表达式引擎** — ObExpr 求值框架 | `src/sql/engine/expr/` |
| 33 | **子查询与 CTE** — 子查询展开与 Recursive CTE | `src/sql/engine/subquery/` |
| 34 | **SSTable Merge** — Mini/Minor/Major/Medium | `src/storage/blocksstable/` |
| 35 | **Macro Block 生命周期** — 分配、GC、回收 | `src/storage/blocksstable/ob_macro_block.h` |
| 36 | **并发控制框架** — MVCC GC、锁模式、隔离级别 | `src/storage/tx/` |
| 37 | **位置缓存与路由** — Location Cache | `src/share/location_cache/` |
| 38 | **PALF 成员变更** — 配置变更与 Learner | `src/logservice/palf/` |
| 39 | **租户架构** — 资源隔离与线程池 | `src/observer/omt/` |
| 40 | **网络与 MySQL 协议** — 连接管理与协议 | `src/observer/mysql/` |

**核心发现**：文章 40 是整个系列的"起点也是终点"。MySQL 协议是用户的入口，也是我们整条分析路径的起点。多租户（文章 39）是 OceanBase 区别于大多数分布式数据库的核心特性——CPU、内存、IO、线程全部以租户为单位隔离，每个租户拥有独立的线程池和队列。PALF 成员变更（文章 38）实现了一种复杂度极高的 Paxos 配置变更算法。

### 高级专题（文章 41–49）

| 篇号 | 主题 | 核心文件 / 路径 |
|------|------|----------------|
| 41 | **Join 算子** — Hash/Nested Loop/Merge Join | `src/sql/engine/join/` |
| 42 | **排序与窗口函数** — Sort Op、Window Function | `src/sql/engine/sort/` |
| 43 | **聚合** — Hash/Bloom/Merge Aggregation | `src/sql/engine/aggregation/` |
| 44 | **IO 子系统** — mClock 调度、预读 | `src/share/io/` |
| 45 | **Latch 体系** — RWLock、Futex、自旋锁 | `deps/oblib/src/lib/lock/` |
| 46 | **数据完整性** — Checksum 体系 | `src/storage/blocksstable/checksum/` |
| 47 | **Locality 与副本分布** | `src/share/ob_locality_info.h` |
| 48 | **Data Checkpoint** — 检查点与日志截断 | `src/storage/checkpoint/` |
| 49 | **Log Service** — 日志生成与回调 | `src/logservice/` |

**核心发现**：IO 子系统（文章 44）是最容易被忽视的"隐藏主角"。所有磁盘操作——SSTable 读取、Clog 写入、Checkpoint 刷盘——都经过 IO Scheduler 的 mClock 公平调度。mClock 是一种基于权重的 IO 调度算法，它确保了多租户场景下的 IO 隔离。Checksum 体系（文章 46）则贯穿整个数据路径，从 Micro Block 到 Macro Block 直到 PALF 日志，每一层都维护自己的校验和。Data Checkpoint（文章 48）是 LSM-Tree 引擎的回传机制——它定义了 "何时可以安全地丢弃日志" 这个核心问题。

---

### 总计

| 指标 | 数值 |
|------|------|
| **文章总数** | **50 篇** |
| **总分析内容** | **~40,000 行** |
| **覆盖代码路径** | **50+ 核心目录** |

---

## 4. 关键设计哲学

从 50 篇分析中，可以提炼出 OceanBase 的几个核心技术决策。它们相互关联、相互支撑，构成了一套完整的设计哲学。

### 4.1 MVCC 隔离与事务

OceanBase 的 MVCC 实现以 `ObMvccRow` 为核心。每一个数据行内嵌一个双向版本链表，所有历史修改通过 `ObMvccTransNode` 节点串联。读请求根据当前事务的 `snapshot_version` 沿着链表找到最适合的可见版本——这个过程完全无锁。

关键设计选择有三点：

1. **版本节点内嵌行数据**：每个 `ObMvccTransNode` 尾部通过柔性数组 `buf_[0]` 承载实际的行数据。这消除了"版本元数据"和"用户数据"之间的指针间接寻址，是典型的 C 语言零开销抽象。

2. **分布式可见性**：与传统单机 MVCC 不同，OceanBase 的事务提交版本号必须等 Paxos 日志在多数副本上落盘后才能最终确定。这意味着版本节点的 `trans_version_` 字段可能经历"预分配→待定→确认"三个状态。文章 04 的 Callback 机制负责在这个状态变化后通知读路径。

3. **写写冲突的分布式处理**：OceanBase 的行级锁由 `ObRowLockCtx` 管理，它实际上维护了一个 rowkey → row_lock 的哈希映射。当 PX 的多个 DFO 线程需要同时写同一行时，冲突检测跨线程进行——这与单机数据库的差别很大。

### 4.2 分布式 Paxos 共识

PALF（Paxos-Structured Log File）是 OceanBase 分布式共识的骨干。它的核心设计哲学是 **"日志即状态"**——所有状态变更都通过 PALF 日志来驱动。

- **PALF 日志流 = LogStream**：每个 LogStream 对应一个独立的 PALF 实例。文章 07 分析了 LogStream 作为"存储引擎的容器"如何管理多个 Tablet。
- **单 Leader 写入**：任何 LogStream 同时只能有一个 Leader 写入日志。这个 Leader 由 Election 模块（文章 12）选举产生。在正常运行时，Leader 负责所有写入请求。
- **Propose → Promise → Commit**：PALF 的写入路径是标准的 Paxos 流程。日志条目的提交意味着它已在多数副本上持久化——这是整个数据库一致性的根基。

PALF 的最精巧设计是它的 **双进度推进**：一方面，日志在 Paxos 组中持续复制（log_progress）；另一方面，Clog 回放模块（文章 13）将已提交的日志应用到 SSTable（replay_progress）。当 replay_progress 追上 log_progress 时，系统处于"热备"状态。

### 4.3 LSM-Tree 存储

OceanBase 的存储引擎采用 LSM-Tree 架构，其核心分级如下：

```
写入路径：Memtable (Writable) → Frozen Memtable (Immutable) → Mini SSTable → Minor SSTable → Major SSTable
                │                      │                         │                │                │
            文章 14, 15             文章 06                    文章 08         文章 34         文章 34
```

每个层级代表数据从"最近写入"到"已持久化合并"的不同阶段：

- **Memtable（文章 14）**：写入的第一站。数据以 Hash 表 + 行存格式存储在内存中。ObKeyBtree（文章 15）是 Memtable 内部用于范围查询的辅助索引。

- **Freeze（文章 06）**：当 Memtable 达到阈值时，冻结线程将其切换为只读状态，新写入进入新的 Memtable。冻结后的 Memtable 等待 Data Checkpoint（文章 48）调度 flush。

- **SSTable（文章 08）**：持久化的表现形式。Micro Block → Macro Block 的两级嵌套编码（文章 26）实现了高压缩率和快速定位的平衡。

- **Merge（文章 34）**：OceanBase 定义了四种 Merge 路径——Mini（Memtable flush）、Minor（若干 Mini SSTable 合并）、Major（全量合并）、Medium（部分合并）。每种 Merge 有不同的触发条件和资源消耗。

LSM-Tree 的关键收益是**写放大与读放大的权衡**：写操作只追加到 Memtable（无原地更新），因此写吞吐极高；但读操作可能需要检查多个层级（Memtable + 多层 SSTable），因此读路径需要精心优化——这正是 Bloom Filter、Block Cache、Encoding 等机制的意义。

### 4.4 多租户架构

OceanBase 的多租户设计（文章 39）是其与大多数分布式数据库（CockroachDB、TiDB）的最大区别。其核心理念是 **"资源隔离是一等公民"**。

```
OBServer 进程
    │
    ├── Tenant 1（如"生产租户"）
    │   ├── 独立的线程池 (ObThWorker × N)
    │   ├── 独立的内存配额 (MemAttr 划分)
    │   ├── 独立的 PL/SQL 函数
    │   └── 独立的 IO 权重 (mClock)
    │
    ├── Tenant 2（如"分析租户"）
    │   ├── 独立的线程池 (ObThWorker × M)
    │   ├── 独立的内存配额
    │   └── ...
    │
    └── Tenant 3（如"测试租户"）
        └── ...
```

每个租户看起来像是一个独立的数据库实例——但共享底层 OBServer 进程。OMT（Observer Multi-Tenant）模块通过 `ObMultiLevelQueue` 实现了线程级 CPU 隔离，通过 `ObIOManager` 的 mClock 调度实现了 IO 隔离。

这个设计的挑战在于：当不同租户的负载模式差异很大时（OLTP vs OLAP），如何在共享进程内既保证隔离又充分利用资源。OceanBase 的解法是"软隔离 + 弹性配额"——每个租户有保证的最小资源，但可以超用空闲资源。

### 4.5 MySQL 兼容性

MySQL 兼容性是 OceanBase 的"面子"——用户不需要改变应用代码就能从 MySQL 迁移过来。文章 40 分析了 MySQL 协议兼容性的实现方式：

```
MySQL 客户端 → 标准 MySQL 协议包 → ObSMHandler → ObSrvMySQLXlator
    → ObMPQueryHandler → SQL 引擎执行
```

OceanBase 没有魔改 MySQL 服务器代码。它从零实现了 MySQL 协议（握手、认证、COM_QUERY、COM_STMT_PREPARE 等），连接到自己的 SQL 引擎上。这意味着 MySQL 生态的工具（mysqldump、mysqlbinlog、JDBC Driver、ODBC Driver）可以直接使用。

这种实现方式的代价是**巨大的协议边界测试**——OBServer 必须正确处理各种 MySQL 协议的边缘情况（大包拆分、认证握手的变化、支持 MySQL 8.0 的 caching_sha2_password 等）。

---

## 5. 源码索引总表

以下是本系列覆盖的关键模块总索引，按功能域分组：

### 存储引擎

| 模块 | 路径 | 功能 | 文章 |
|------|------|------|------|
| MVCC Row | `src/storage/memtable/mvcc/ob_mvcc_row.h` | 版本链行结构 | 01, 02, 05 |
| MVCC Iterator | `src/storage/memtable/mvcc/ob_mvcc_iterator.h` | 读取器与可见性 | 02 |
| Row Conflict Handler | `src/storage/memtable/mvcc/ob_row_conflict_handler.h` | 写写冲突检测 | 03, 16 |
| MVCC Engine | `src/storage/memtable/mvcc/ob_mvcc_engine.h` | MVCC 引擎入口 | 09 |
| Memtable | `src/storage/memtable/ob_memtable.h` | 内存写入缓冲区 | 06, 14 |
| KeyBtree | `src/storage/memtable/ob_key_btree.h` | 自研 B-Tree | 15 |
| Freezer | `src/storage/memtable/ob_memtable.h` (freeze) | 冻结调度 | 06 |
| SSTable | `src/storage/sstable/ob_sstable.h` | 持久化数据格式 | 08 |
| SSTable Merge | `src/storage/blocksstable/ob_sstable_merge.h` | 合并策略 | 34 |
| Encoding | `src/storage/blocksstable/encoding/` | MicroBlock 列编码 | 26 |
| Macro Block | `src/storage/blocksstable/ob_macro_block.h` | 块管理与分配 | 35 |
| LogStream | `src/storage/ob_ls.h` | 存储容器 | 07 |
| Data Checkpoint | `src/storage/checkpoint/` | 日志截断调度 | 48 |
| Backup/Restore | `src/storage/backup/` | 数据保护 | 20 |
| IO Manager | `src/share/io/` | IO 调度与 mClock | 44 |
| Checksum | `src/storage/blocksstable/checksum/` | 数据完整性验证 | 46 |

### 分布式共识

| 模块 | 路径 | 功能 | 文章 |
|------|------|------|------|
| PALF | `src/logservice/palf/` | Paxos 日志框架 | 11, 38 |
| Election | `src/logservice/election/` | 选主与切换 | 12 |
| Clog | `src/logservice/clog/` | 日志回放 | 13 |
| LogService | `src/logservice/ob_log_service.h` | 日志生成与回调 | 49 |
| Archive Service | `src/logservice/archiveservice/` | 日志归档 | 20 |

### SQL 引擎

| 模块 | 路径 | 功能 | 文章 |
|------|------|------|------|
| Parser | `src/sql/parser/` | SQL 语法解析 | 23 |
| Resolver | `src/sql/resolver/` | 语义解析与绑定 | 23 |
| Optimizer | `src/sql/optimizer/` | 查询优化与计划生成 | 17 |
| Plan Cache | `src/sql/plan_cache/` | 计划缓存管理 | 22 |
| PX Engine | `src/sql/engine/px/` | 并行执行 | 21 |
| DML | `src/sql/engine/dml/` | INSERT/UPDATE/DELETE | 31 |
| Join | `src/sql/engine/join/` | Hash/NL/Merge Join | 41 |
| Sort/Window | `src/sql/engine/sort/` | 排序与窗口函数 | 42 |
| Aggregation | `src/sql/engine/aggregation/` | 聚合算子 | 43 |
| Expression | `src/sql/engine/expr/` | 表达式求值 | 32 |
| Subquery/CTE | `src/sql/engine/subquery/` | 子查询与 CTE | 33 |
| DAS | `src/sql/das/` | 数据访问服务 | 09 |
| Type System | `deps/oblib/src/common/object/` | ObObj/ObDatum | 24 |

### 集群协调

| 模块 | 路径 | 功能 | 文章 |
|------|------|------|------|
| RootServer | `src/rootserver/` | 元数据与集群管理 | 27 |
| GTS | `src/rootserver/gts/` | 全局时间戳 | 28 |
| Locality | `src/share/ob_locality_info.h` | 副本分布策略 | 47 |
| Location Cache | `src/share/location_cache/` | 位置缓存与路由 | 37 |
| Partition Migration | `src/rootserver/ob_move_handler.h` | 分区迁移 | 19 |
| Index Design | `src/sql/optimizer/` (index) | 索引选择与维护 | 18 |

### 基础设施

| 模块 | 路径 | 功能 | 文章 |
|------|------|------|------|
| Memory Management | `deps/oblib/src/lib/alloc/` | 分配器与内存池 | 25 |
| Latch/Spinlock | `deps/oblib/src/lib/lock/` | 并发原语 | 45 |
| MySQL Protocol | `src/observer/mysql/` | 网络协议处理 | 40 |
| OBServer Startup | `src/observer/ob_server.h` | 进程生命周期 | 30 |
| Tenant | `src/observer/omt/` | 多租户管理 | 39 |
| Transaction | `src/storage/tx/` | 事务管理器与 2PC | 10, 36 |
| SQL Diagnostics | `src/sql/monitor/` | 监控与诊断 | 29 |

---

## 6. 设计哲学中的模式

在 50 篇文章的反复深潜中，有几个模式反复出现，它们构成了 OceanBase 的"代码签名"：

### 6.1 分层抽象与薄接口

OceanBase 的层间接口非常薄。典型例子是 DAS 层（文章 09）——它只负责"给定一个 RowID，获取一行数据"，不关心数据在 Memtable 还是 SSTable 中。这种"查字典"式的窄接口使得每一层都可以独立演化。

另一个例子是 PALF 与 Clog——PALF 只负责日志的 Paxos 复制和持久化，不关心日志内容。Clog 读取 PALF 的日志条目并逐条回放到存储引擎。这种"生产者-消费者"分离使得数据复制和数据回放可以有不同的优化路径。

### 6.2 CAS 而非锁

从 MVCC 的 `TransNodeFlag`（文章 01）到 Latch 系统（文章 45），OceanBase 大量使用 CAS（Compare-And-Swap）原子操作而不是互斥锁。最典型的 pattern 是 `add_flag_()` 中的 CAS loop：

```c
while (true) {
  const uint8_t flag = ATOMIC_LOAD(&flag_status_);
  const uint8_t tmp = (flag | new_flag);
  if (ATOMIC_BCAS(&flag_status_, flag, tmp)) break;
}
```

在热路径（Hot Path）上，CAS 比互斥锁快一个数量级。但 CAS 的正确性验证极其困难——这正是 OceanBase 代码中大量 `doom-lsp` 符号追踪的意义所在。

### 6.3 批处理与向量化

OceanBase 在多个层面做了批处理优化：
- **Redo Log 批处理**（文章 49）：多个 DML 操作合并成一条日志，减少 PALF Propose 次数
- **PX DTL 批处理**（文章 21）：跨节点数据传输以 batch 为单位，而非逐行
- **向量化表达式**：Join、Aggregation、Sort 等算子都有 `_vec_op` 向量化版本，利用批处理压榨 CPU 缓存
- **IO 预读**（文章 44）：IO Scheduler 预测访问模式并批量发起 IO

### 6.4 状态机驱动

OceanBase 中几乎所有核心子系统都是状态机：
- **事务状态机**：Running → Prepare → Committed / Aborted
- **PALF 副本状态**：Follower → Candidate → Leader
- **Memtable 状态**：Writable → Frozen → Flushing → Flushed
- **MVCC 节点状态**：`F_WEAK_CONSISTENT_READ_BARRIER` → `F_COMMITTED` → `F_ABORTED`

状态机的优势是可测试性和可证明性——每篇分析文章几乎都会附上 ASCII 状态转换图，因为理解状态机就是理解系统的核心。

---

## 7. 展望

### 7.1 OceanBase 的未来方向

作为一个持续演进的数据库，OceanBase 在以下方向上还有持续投入：

1. **向量化引擎**：已完成算子级别的向量化，未来可能会将整个执行引擎向量化，类似 Hyper 或 DuckDB 的设计。

2. **物化视图与自动维护**：物化视图是 OLAP 场景的核心需求，OceanBase 的 LSM-Tree 架构使得物化视图的增量维护有天然优势。

3. **多模融合**：OceanBase 已经在支持 JSON、GIS 等半结构化数据，未来可能走向"一库多用"的 HTAP + 多模融合。

4. **云原生与 Serverless**：随着 K8s 部署成为主流，OceanBase 的 OBTenant 抽象如何更好地映射到 Serverless 环境是一个重要的演进方向。

5. **AI 集成**：SQL 诊断（文章 29）已经有了丰富的运行时数据，将这些数据喂给 ML 模型来做自动调优是顺理成章的下一步。

### 7.2 如果你还要继续深入

50 篇文章只是起点。以下是一些值得继续深挖的方向：

- **性能测试与调优**：理解源码后，可以对特定场景做性能基准测试，验证理论分析与实际表现的差异。
- **Bug 追踪**：在 OceanBase GitHub Issues 中找一些已修复的 Bug，读对应的 PR 来理解问题根因和修复方式。
- **特定版本对比**：对比 v3.x 和 v4.x 的架构变化（如从单一 Tablet 到 LogStream 的过渡），理解架构演进的原因。
- **自己动手跑测试**：在本地编译 OceanBase CE 并运行单元测试，用 GDB/LLDB 单步追踪关键路径。

---

## 8. 写在最后

50 篇，40,000 行。从 `ob_mvcc_row.h` 的 ~490 行核心结构，到 `ob_trans_service.h` 的 ~420 行事务入口，到 `src/observer/mysql/` 的 94 个网络模块文件——每一步都是对分布式数据库设计哲学的实践验证。

OceanBase 的代码量巨大（数百万行 C++），但它的架构并不复杂。每个模块解决一个明确的问题，模块之间通过明确的接口通信。这种"复杂的功能，简单的架构"正是好的软件工程的体现。

如果你从这篇总结开始，我建议的阅读路线是：

1. **先读这篇文章** — 建立全景图
2. **然后从文章 01 开始** — MVCC 是存储引擎的基石
3. **依次向下到文章 10** — 理解一个完整的事务从开始到提交的全过程
4. **跳到文章 40 和文章 39** — 理解入口和多租户
5. **根据兴趣深入** — 对共识感兴趣的读 11–13，对 SQL 感兴趣的读 21–23 和 41–43

源码是最好的文档。希望这 50 篇文章能让你的 OceanBase 源码之旅更顺畅。

---

*本系列使用的工具：`doom-lsp`（clangd LSP）进行符号解析，`web-search` 进行概念查询，`tmux` 进行远程开发交互。*
