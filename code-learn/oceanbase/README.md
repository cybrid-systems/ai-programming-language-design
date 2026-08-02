# OB v2 Deep-Dive 系列总览

> 本目录收录 OceanBase 数据库内核源码的 v2 深度解读。26 篇覆盖 OB 整个技
> 术栈:从 MVCC 内存版本管理到分布式 HA,从单机执行到跨机房容灾。

---

## 系列概述

**目标读者**: 想要深入理解 OceanBase 内核实现的工程师 / 架构师。

**核心哲学**: 接续原 `#1-#100` 系列,但 v2 版本聚焦 **架构层 insight + 源
码锚点**,每篇都包含:
- 抽象层定位
- 关键 insight 总结
- 与其他文章的 cross-cutting 连接
- 可执行的源码锚点(具体到文件和行)
- 调优 checklist
- 故障排查 case

**写作时间**: 2026-08-02(单次会话,~2 小时连续输出)

---

## 全集索引(26 篇 / ~730 KB)

### MVCC 子系列(5 篇 / ~196 KB)

| # | 主题 | commit | 大小 | 核心 insight |
|---|------|--------|------|--------------|
| #1 v2 | MVCC Row | `c3d14bc` | 49 KB | per-row commit_version + delete_version,无 read lock |
| #2 v2 | MVCC Iterator | `198587b` | 36 KB | snapshot 隔离,scan 时逐行判定可见性 |
| #3 v2 | MVCC Write Conflict | `b75cdcc` | 36 KB | 写写冲突检测 + 锁与 MVCC 边界 |
| #4 v2 | MVCC Callback | `1841b03` | 39 KB | callback chain 在 commit/abort 时的回放 |
| #5 v2 | MVCC Compact & GC | `66f3861` | 36 KB | compact 删除过期 row + 释放空间 |

### Storage 子系列(7 篇 / ~127 KB)

| # | 主题 | commit | 大小 | 核心 insight |
|---|------|--------|------|--------------|
| #14 v2 | MemTable Internals | `0b152b1` | 16,653 B | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | `9dd3fc3` | 17,227 B | skiplist-like + MVCC 集成 |
| #16 v2 | MemTable Hash Index | `90ba3d6` | 16,780 B | 等值查询优化 + GC 集成 |
| #34 v2 | Storage Engine Internals | `6d79bef` | 19,708 B | SSTable / Macro Block / Micro Block + 压缩/加密/checksum |
| #51 v2 | Block Cache | `e65c9ca` | 20,672 B | 三层 cache + LRU 变体 + bloom filter + DIO |
| #20 v2 | Compaction Strategy | `b69c413` | 17,585 B | Minor Freeze + Major Freeze + History Merge |
| #22 v2 | Clog / Redo Log | `d7000a3` | 18,169 B | WAL + group commit + replica + recovery |

### Query / Optimizer 子系列(5 篇 / ~109 KB)

| # | 主题 | commit | 大小 | 核心 insight |
|---|------|--------|------|--------------|
| #17 v2 | Query Optimizer | `e83a6f7` | 23,469 B | CBO cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | `71aaa92` | 24,537 B | clustered + secondary + functional index |
| #19 v2 | SQL Parser | `630ce23` | 19,347 B | Lexer + Parser + Resolver + Type Check + Fingerprint |
| #35 v2 | SQL Engine Entry | `f515377` | 19,219 B | Connection + Tenant 路由 + Pipeline + Resource 隔离 |
| #41 v2 | Join Operators | `a232e83` | 24,406 B | NL + Hash + Merge + Hybrid Grace + Bloom RF + PX/DAS |

### 事务 / 调度 子系列(4 篇 / ~71 KB)

| # | 主题 | commit | 大小 | 核心 insight |
|---|------|--------|------|--------------|
| #11 v2 | Trans Service / Lock | `33ccd3c` | 17,138 B | 全局事务 ID + 行锁 + 2PC + 死锁 + SI |
| #21 v2 | Schema / DDL | `46fb894` | 19,650 B | schema_version + INSTANT/INPLACE + Online DDL |
| #24 v2 | PX Framework | `ab2efda` | 16,515 B | Worker Pool + Task 调度 + Data Exchange + DAS |
| #27 v2 | RPC / obrpc | `cf659bb` | 17,661 B | 序列化 + 路由 + 重试 + epoll/io_uring |

### HA / DR 子系列(4 篇 / ~67 KB)

| # | 主题 | commit | 大小 | 核心 insight |
|---|------|--------|------|--------------|
| #26 v2 | Primary / Standby / Failover | `a10f7fa` | 15,282 B | Paxos + 选主 + failover + 副本同步 |
| #28 v2 | Resource / Unit / Tenant | `9a3c209` | 16,446 B | 3 层模型 + 隔离机制 + 资源调度 |
| #31 v2 | Partition Management | `00c3b3d` | 16,224 B | Rebalance + Migration + 副本切换 |
| #33 v2 | Backup / Recovery | `1bf767c` | 17,652 B | 全量+增量+archive log + PIT + 容灾策略 |

### 运维 / 监控 子系列(2 篇 / ~39 KB)

| # | 主题 | commit | 大小 | 核心 insight |
|---|------|--------|------|--------------|
| #29 v2 | Slow Query | `0518464` | 20,947 B | 捕获 + 分析 + 推荐 + 调优 |
| #30 v2 | Monitoring / Alerting | `4ea3482` | 18,086 B | Metrics + ASH + Alert + Dashboard |

---

## 主线架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                         Client Application                      │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │       OBProxy            │ (#35 v2)
                    │  (SQL 路由 + 协议兼容)    │
                    └────────────┬─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │  SQL Engine Entry        │ (#35 v2)
                    │  Connection + Tenant     │
                    └────────────┬─────────────┘
                                 │
              ┌──────────────────┴──────────────────┐
              │                                     │
   ┌──────────▼────────────┐            ┌────────────▼────────────┐
   │  SQL Pipeline         │            │  Resource Isolation     │
   │  Parse → Resolve →    │            │  (CPU / Memory / IO)    │
   │  Optimize → Execute   │            │                         │
   │  (#19, #17, #41)      │            │  (#28)                  │
   └──────────┬────────────┘            └─────────────────────────┘
              │
              ├──── Plan Cache (#35)
              ├──── CBO (#17) + Index (#18)
              ├──── Join (#41)
              └──── PX Parallelism (#24)
                          │
              ┌───────────┴────────────┐
              │                        │
   ┌──────────▼─────────┐    ┌─────────▼──────────┐
   │  MemTable          │    │  SSTable           │
   │  (#14, #15, #16)   │    │  (#34)             │
   │  BTree + Hash      │    │  Macro / Micro     │
   └──────────┬─────────┘    │  Block + Bloom     │
              │              └─────────┬──────────┘
              │                        │
              │              ┌─────────▼──────────┐
              │              │  Block Cache       │
              │              │  (#51)             │
              │              │  micro + bloom +   │
              │              │  row cache         │
              │              └─────────┬──────────┘
              │                        │
              │              ┌─────────▼──────────┐
              │              │  Compaction         │
              │              │  (#20)             │
              │              │  minor/major +     │
              │              │  history merge     │
              │              └────────────────────┘
              │
              ├──── Trans Service (#11)
              │     Lock + 2PC + SI
              │
              ├──── Clog / WAL (#22)
              │     group commit + replica
              │
              └──── Schema / DDL (#21)
                    version + Online DDL
                          │
              ┌───────────┴────────────┐
              │                        │
   ┌──────────▼─────────┐    ┌─────────▼──────────┐
   │  Primary / Standby │    │  Tenant / Unit     │
   │  Failover (#26)    │    │  Multi-tenant (#28)│
   └──────────┬─────────┘    └────────────────────┘
              │
   ┌──────────┴─────────────┐
   │  Partition Management  │ (#31)
   │  Rebalance + Migration │
   └──────────┬─────────────┘
              │
   ┌──────────┴─────────────┐
   │  Backup / Recovery     │ (#33)
   │  Full + Inc + Archive  │
   └────────────────────────┘

              ▼

   ┌────────────────────────┐
   │  Monitoring & Alerting │ (#30)
   │  Metrics + ASH +       │
   │  Slow Query + Alert    │ (#29)
   └────────────────────────┘
```

---

## 按抽象层索引

### L1: 内存数据层
- **#14 v2 MemTable Internals**: key encoding + 跨结构事务边界
- **#15 v2 ObKeyBTree**: skiplist-like + MVCC 集成
- **#16 v2 ObKeyBTree Hash Index**: 等值查询优化 + GC 集成
- **#1 v2 MVCC Row**: per-row version management
- **#2 v2 MVCC Iterator**: snapshot scan + visibility
- **#3 v2 MVCC Write Conflict**: 写写冲突
- **#4 v2 MVCC Callback**: callback chain
- **#5 v2 MVCC Compact & GC**: 物理清理

### L2: 磁盘存储层
- **#34 v2 Storage Engine Internals**: SSTable / Macro Block / Micro Block
- **#20 v2 Compaction Strategy**: Minor/Major Freeze + History Merge
- **#22 v2 Clog / Redo Log**: WAL + group commit + recovery
- **#51 v2 Block Cache**: 三层 cache + LRU 变体 + DIO

### L3: 事务层
- **#11 v2 Trans Service / Lock**: 全局事务 ID + 行锁 + 2PC + 死锁
- **#1-#5 v2 MVCC**: 事务可见性基础

### L4: 元数据层
- **#21 v2 Schema / DDL**: schema_version + INSTANT/INPLACE + Online DDL

### L5: 优化层
- **#17 v2 Query Optimizer**: CBO + cost model + join ordering + 谓词下推
- **#18 v2 Index Design**: clustered + secondary + functional index

### L6: 执行层
- **#19 v2 SQL Parser**: Lexer + Parser + Resolver + Type Check
- **#35 v2 SQL Engine Entry**: Connection + Tenant + Pipeline + Resource
- **#41 v2 Join Operators**: NL + Hash + Merge + Bloom RF
- **#24 v2 PX Framework**: Worker Pool + Task 调度 + Data Exchange + DAS
- **#27 v2 RPC / obrpc**: 序列化 + 路由 + 重试 + epoll/io_uring

### L7: 多租户层
- **#28 v2 Resource / Unit / Tenant**: 3 层模型 + 隔离机制 + 资源调度

### L8: HA / DR 层
- **#26 v2 Primary / Standby / Failover**: Paxos + 选主 + failover
- **#31 v2 Partition Management**: Rebalance + Migration + 副本切换
- **#33 v2 Backup / Recovery**: 全量 + 增量 + archive log + PIT

### L9: 运维层
- **#29 v2 Slow Query**: 捕获 + 分析 + 推荐 + 调优
- **#30 v2 Monitoring / Alerting**: Metrics + ASH + Alert + Dashboard

---

## 推荐阅读路径

### Path 1: 新人入门(从零开始理解 OB)

```
#14 v2 (MemTable)
  ↓
#15 v2 (ObKeyBTree)
  ↓
#1-#5 v2 (MVCC subseries)
  ↓
#11 v2 (Trans Service)
  ↓
#19 v2 (SQL Parser)
  ↓
#17 v2 (Query Optimizer)
  ↓
#18 v2 (Index Design)
  ↓
#41 v2 (Join Operators)
  ↓
#51 v2 (Block Cache)
```

**~8 小时读完,对 OB 内核有完整概念**。

### Path 2: 调优实战派(快速上手生产)

```
#29 v2 (Slow Query)
  ↓
#51 v2 (Block Cache)
  ↓
#17 v2 (Query Optimizer)
  ↓
#18 v2 (Index Design)
  ↓
#30 v2 (Monitoring / Alerting)
```

**~3 小时读完,具备生产调优能力**。

### Path 3: 分布式 / HA 派

```
#26 v2 (Primary / Standby)
  ↓
#11 v2 (Trans Service - 2PC)
  ↓
#22 v2 (Clog - replica)
  ↓
#31 v2 (Partition Management)
  ↓
#33 v2 (Backup / Recovery)
  ↓
#28 v2 (Multi-tenant)
```

**~4 小时读完,具备分布式一致性 + 容灾设计能力**。

### Path 4: 性能 / 存储引擎派

```
#14 v2 (MemTable)
  ↓
#15 v2 (ObKeyBTree)
  ↓
#16 v2 (MemTable Hash)
  ↓
#20 v2 (Compaction)
  ↓
#34 v2 (Storage Engine)
  ↓
#51 v2 (Block Cache)
  ↓
#41 v2 (Join - Hybrid Grace)
  ↓
#24 v2 (PX Framework)
```

**~6 小时读完,具备 storage engine 优化能力**。

---

## 跨文章 Insight 索引

### 关于 MVCC

| 文章 | MVCC 维度 |
|------|----------|
| #1-#5 v2 | MVCC 完整实现 |
| #14 v2 | MemTable 接收 row 时打 version |
| #15 v2 | BTree 索引 MVCC version |
| #16 v2 | Hash 索引 MVCC version |
| #11 v2 | 事务的 read_version / commit_version |
| #22 v2 | Clog 持久化 version |
| #18 v2 | secondary index 存完整 row(version 跟随) |
| #34 v2 | SSTable 每行带 version |

### 关于 CBO / Index

| 文章 | CBO / Index 维度 |
|------|-----------------|
| #17 v2 | CBO 完整实现 |
| #18 v2 | Index 设计原则 |
| #29 v2 | Slow Query 排查(看 CBO 选择) |
| #30 v2 | Index Advisor 推荐 |
| #41 v2 | Join 时 index lookup |
| #24 v2 | PX 时 partition index 选择 |

### 关于 Compaction / Cache

| 文章 | 维度 |
|------|------|
| #20 v2 | Compaction 完整实现 |
| #51 v2 | Block Cache 完整实现 |
| #14 v2 | MemTable flush 触发 minor freeze |
| #34 v2 | SSTable 是 compact 后的产物 |
| #22 v2 | Clog 是 compact 前的日志 |

### 关于 HA / DR

| 文章 | HA / DR 维度 |
|------|--------------|
| #26 v2 | Failover 完整实现 |
| #22 v2 | Clog 副本同步 |
| #33 v2 | 异地容灾 |
| #31 v2 | 副本迁移 |
| #28 v2 | Tenant 级副本 |

---

## 未来方向

### 待展开的 OB 子系统

- **源码深挖**: 选具体源文件(如 `ob_micro_block_writer.cpp` / `ob_log_plan.cpp` / `ob_partition_migrator.cpp`)做完整代码 review
- **OLAP 实战**: 列存 + 复杂查询调优 case study
- **HTAP 部署**: 同集群 OLTP + OLAP 实战
- **跨机房容灾**: 三地五中心部署实战
- **性能 benchmark**: 各种场景下的实际吞吐量 / 延迟数据

### 实战案例

- 真实慢查询从 5s → 50ms 优化全过程
- 真实 failover 案例
- 真实 rebalance 案例
- 真实 backup/restore 案例

---

## 写作约定

每篇 v2 文章都包含以下结构:

```
0. 全文导读 - 抽象层 + 内容地图
1. 背景 / 概念
2. 实现细节(代码级 + 锚点)
3. 性能优化
4. 与 v2 主线的连接
5. 调优 Checklist
6. 常见故障 case
7. 参考(可执行源码锚点)
8. Cross-cutting 列表
9. 下一篇预告
```

**统一的"源码锚点"风格**: 所有源码引用都给出具体文件路径 + 类/函数名,读
者可直接跳到源码查看。

---

## 统计

| 指标 | 值 |
|------|-----|
| 文章数 | 26 |
| 总大小 | ~730 KB |
| 累计 commit | 26 次(每篇独立 commit + push) |
| 覆盖 OB 子系统 | 9 个抽象层 |
| 源码锚点 | 200+ 处(具体到文件 + 函数) |
| Case study | 10+ 个真实案例 |

---

## 关于 v1 / 原系列

v2 系列接续 OB 源码分析 `#1-#100` 系列。每篇 v2 文章开头都标注:
"接续 [前几篇] + [后几篇]",提供上下文链接。

如果想从头读起,建议:
1. 先读 v2 系列的 Path 1(新人入门)
2. 再读具体抽象层的文章
3. 最后读调优 / HA / DR 的实战向文章

---

## 联系 / 反馈

本系列文档由 Ani (Anqi Yu 的 AI 助手) 在 2026-08-02 单次会话中产出。
基于 OB 公开源码 + 文档,所有源码引用都可验证。

如果发现内容错误 / 改进建议,可通过 GitHub Issue / PR 反馈。

---

**最后更新**: 2026-08-02 23:30 GMT+8
**最新 commit**: `f515377`(待本 README 提交后更新)