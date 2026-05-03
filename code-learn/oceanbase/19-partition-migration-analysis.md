# 19 — 分区迁移与负载均衡：Rebalance 与 Transfer

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

前 18 篇文章覆盖了存储引擎（MVCC、SSTable、LS Tree）、共识层（PALF、Election、Clog）、以及查询优化器与索引系统。现在我们把目光投向分布式数据库的运维核心能力——**分区迁移（Partition Migration）与负载均衡（Load Balancing）**。

在分布式系统中，数据动态分布不是一次性的：节点会宕机、扩容需要搬数据、热点分区需要拆分、磁盘水位需要均衡。OceanBase 的 HA（High Availability）子系统就是处理这一切的工程实现。

本章分析的代码位于 `src/storage/high_availability/`（44 个 .h 文件），这一层管理日志流（LogStream, LS）在节点间的迁移和副本均衡。

### 迁移系统在整个架构中的位置

```
┌──────────────────────────────────────────────────────────────────┐
│                      RootServer / OB Load Balancer                │
│   ┌─ 故障检测 (ObServerManager)                                   │
│   ├─ 负载计算 (ObPartitionBalanceer)                             │
│   └─ 迁移指令下发 → __all_ls_migration_task 内表                │
├──────────────────────────────────────────────────────────────────┤
│                    HA 子系统 (storage/high_availability)          │
│   ObLSMigrationHandler  ←  LS 迁移主入口                          │
│   ├─ ObLSPrepareMigration     → PREPARE 阶段                      │
│   ├─ ObLSMigration           → BUILD / MIGRATE 阶段               │
│   └─ ObLSCompleteMigration   → COMPLETE 阶段                      │
│   ObTransferHandler/Service  → Partition Transfer                 │
│   ObLSRebuildCbImpl          → Replica Rebuild                    │
│   ObLSMemberListService      → 成员管理                           │
│   ObLSBlockTxService         → 迁移阻塞策略                       │
├──────────────────────────────────────────────────────────────────┤
│                    LS Tree / PALF 层                              │
│   文章 07 — LS 的结构与角色                                        │
│   文章 11 — PALF 日志的同步原理                                    │
│   文章 12 — Election 选举（迁移后需重新选举）                       │
└──────────────────────────────────────────────────────────────────┘
```

---

## 1. 迁移系统的整体架构

### 1.1 核心组件总览

| 组件 | 文件 | 职责 |
|------|------|------|
| `ObLSMigrationHandler` | `ob_ls_migration_handler.h` | 每个 LS 一个迁移处理器，状态机驱动 |
| `ObLSPrepareMigration` | `ob_ls_prepare_migration.h` | 迁移准备阶段 — 创建 LS + 全量 Tablet 同步 |
| `ObLSMigration` | `ob_ls_migration.h` | 迁移执行阶段 — Tablet 级别的 SSTable 拷贝 + PALF 日志同步 |
| `ObLSCompleteMigration` | `ob_ls_complete_migration.h` | 迁移完成阶段 — 角色切换 + Meta 表更新 |
| `ObTransferHandler` | `ob_transfer_handler.h` | Partition Transfer — Tablet 在 LS 间转移 |
| `ObTransferService` | `ob_transfer_service.h` | Transfer 调度线程 |
| `ObLSRebuildCbImpl` | `ob_ls_rebuild_cb_impl.h` | 副本重建回调 |
| `ObLSMemberListService` | `ob_ls_member_list_service.h` | LS 成员列表管理与变更 |
| `ObLSBlockTxService` | `ob_ls_block_tx_service.h` | 迁移期间事务阻塞/恢复 |

### 1.2 迁移触发路径

迁移不是凭空发生的。RootServer 中的负载均衡器持续检测集群状态：

```
RootServer 检测条件
├── 节点磁盘使用率 > 阈值 → 将部分 LS 迁移到低负载节点
├── 新节点加入集群 → 从高负载节点迁入 LS
├── 节点宕机 → 在存活节点重建副本
├── Partition Split/Merge → 触发 Transfer
└── Zone 级别容灾调整 → 跨 Zone 副本重分布

迁移指令写入 __all_ls_migration_task 内表

↓

目标节点的 ObLSMigrationHandler::process() 读取任务并执行
```

---

## 2. 迁移状态机（ObLSMigrationHandler）

### 2.1 状态机定义

OceanBase 的 LS 迁移由严谨的状态机驱动，定义在 `ob_ls_migration_handler.h` 中：

**文件：** `src/storage/high_availability/ob_ls_migration_handler.h`，第 30–57 行

```cpp
enum class ObLSMigrationHandlerStatus : int8_t
{
  INIT = 0,            // 初始状态
  PREPARE_LS = 1,      // 准备阶段 — 创建新 LS，分配资源
  WAIT_PREPARE_LS = 2,  // 等待准备阶段 DAG 完成
  BUILD_LS = 3,        // 构建阶段 — 迁移 Tablet 数据
  WAIT_BUILD_LS = 4,    // 等待构建阶段 DAG 完成
  COMPLETE_LS = 5,     // 完成阶段 — 切换角色
  WAIT_COMPLETE_LS = 6, // 等待完成阶段 DAG 完成
  FINISH = 7,          // 完成 — 上报结果，清理资源
  MAX_STATUS,
};
```

### 2.2 状态转换图

```
                               ret != OB_SUCCESS
  ┌────────────────────────────────────────────────────────────────────┐
  │                                                                    │
┌─┴──┐  ┌──────────┐  ┌───────────────┐  ┌────────┐  ┌─────────────┐  ┌─────┴───────┐  ┌────────────────┐  ┌──────┐
│INIT│─►│PREPARE_LS│─►│WAIT_PREPARE_LS│─►│BUILD_LS│─►│WAIT_BUILD_LS│─►│ COMPLETE_LS ├─►│WAIT_COMPLETE_LS│─►│FINISH│
└────┘  └──────────┘  └───┬─┬────▲────┘  └────────┘  └───┬─┬────▲───┘  └──▲──┬────▲──┘  └────┬────▲──────┘  └──────┘
                          │ │    │                       │ │    │         │  │    │          │    │
                          │ └wait┘                       │ └wait┘         │  └────┘          └wait┘
                          └──────────────────────────────┴───────────────┘   ret != OB_SUCCESS
                             ret != OB_SUCCESS || result != OB_SUCCESS        && !is_complete_
```

状态转换的核心原则：
- 每步执行一个 DAG Net（DAG 网络），通过 DAG 调度器异步执行
- `WAIT_*` 状态轮询检查对应 DAG Net 是否完成
- SCM（准一致性）相关的检查在进入 PREPARE 前校验 `check_before_do_task_()`，见第 151 行
- 任何状态失败都可通过 `handle_failed_task_()` 处理，第 129 行

### 2.3 ObLSMigrationHandler 的核心接口

```cpp
class ObLSMigrationHandler : public ObIHAHandler
{
  // 核心生命周期
  int init(ObLS *ls, bandwidth_throttle, svr_rpc_proxy, storage_rpc, sql_proxy);
  int add_ls_migration_task(const share::ObTaskId &task_id, const ObMigrationOpArg &arg);
  virtual int process();                              // 被 DAG 调度器定时调用
  void destroy();
  void stop();
  int cancel_task(const share::ObTaskId &task_id, bool &is_exist);
  bool is_complete() const;
  int set_result(const int32_t result);

  // 状态机处理方法
  int do_init_status_();           // 初始化任务上下文
  int do_prepare_ls_status_();     // 触发 PREPARE DAG Net
  int do_build_ls_status_();       // 触发 BUILD DAG Net
  int do_complete_ls_status_();    // 触发 COMPLETE DAG Net
  int do_finish_status_();         // 上报结果，报告 meta table
  int do_wait_status_();           // 轮询等待 DAG Net 完成

private:
  // 状态数据
  ObLSMigrationHandlerStatus status_;      // 当前状态（第 181 行）
  int32_t result_;                          // 执行结果（第 182 行）
  ObStorageHASrcInfo chosen_src_;           // 选定的数据源（第 185 行）
  share::SCN advance_checkpoint_scn_;       // 推进的 checkpoint（第 190 行）
  ObLSMigrationCostStatic cost_static_;     // 耗时统计（第 191 行）
};
```

---

## 3. 迁移 DAG 体系（ObLSMigration → ObMigrationDagNet）

迁移的执行不是同步函数调用，而是通过 DAG 调度器编排为 DAG Net 异步执行。核心类在 `ob_ls_migration.h` 中定义。

### 3.1 DAG 层级结构

```
ObMigrationDagNet                     ← 一次迁移的完整调度单元
├── ObInitialMigrationDag             ← 初始化：从源端获取 LS 元信息
│   └── ObInitialMigrationTask
│
├── ObStartMigrationDag               ← 启动迁移：创建本地 LS，加入 Learner 列表
│   └── ObStartMigrationTask
│
├── ObSysTabletsMigrationDag          ← 迁移系统 Tablet
│   └── ObSysTabletsMigrationTask
│
├── ObDataTabletsMigrationDag         ← 迁移数据 Tablet（批量）
│   └── ObDataTabletsMigrationTask
│       ├── ObTabletGroupGenerateDag    ← 分组生成
│       │   └── ObTabletGroupGenerateTask
│       ├── ObTabletGroupMigrationDag   ← 每组迁移（并行）
│       │   └── ObTabletGroupMigrationTask
│       │       ├── ObTabletMigrationDag (对每个 Tablet)
│       │       │   └── ObTabletMigrationTask
│       │       │       ├── 全量 SSTable 拷贝 (macro block)
│       │       │       ├── 增量拷贝 (minor merge)
│       │       │       └── ObTabletFinishMigrationTask
│       │       └── ...
│       └── ...
│
└── ObMigrationFinishDag              ← 收尾：更新 Meta 表，通知 RootServer
    └── ObMigrationFinishTask
```

### 3.2 ObMigrationCtx — 迁移上下文

**文件：** `src/storage/high_availability/ob_ls_migration.h`，第 36–66 行

`ObMigrationCtx` 保存迁移过程中需要的所有状态：

```cpp
struct ObMigrationCtx : public ObIHADagNetCtx
{
  uint64_t tenant_id_;
  ObMigrationOpArg arg_;               // 迁移参数（源/目标 LS ID 等）
  share::SCN local_clog_checkpoint_scn_; // 本地日志检查点 SCN
  int64_t src_ls_rebuild_seq_;          // 源端 LS 重建序列号
  int64_t start_ts_;
  int64_t finish_ts_;
  share::ObTaskId task_id_;

  // 数据源信息
  ObStorageHASrcInfo minor_src_;       // 增量数据源
  ObStorageHASrcInfo major_src_;       // 全量数据源
  ObLSMetaPackage src_ls_meta_package_; // 源 LS 元信息

  // Tablet 映射表
  ObArray<common::ObTabletID> sys_tablet_id_array_;
  ObArray<common::ObTabletID> data_tablet_id_array_;
  ObHATableInfoMgr ha_table_info_mgr_;
};
```

### 3.3 Tablet 级别数据拷贝（ObTabletMigrationTask）

这是迁移中最核心也是最耗时的部分——**SSTable 数据的跨节点拷贝**。

**文件：** `src/storage/high_availability/ob_ls_migration.h`，第 353–421 行

```cpp
class ObTabletMigrationTask : public ObITask
{
  // 核心方法
  int generate_minor_copy_tasks_();      // 增量 SSTable 拷贝（第 365 行）
  int generate_major_copy_tasks_();      // 全量 BASE SSTable 拷贝（第 368 行）
  int generate_ddl_copy_tasks_();        // DDL 产生的 SSTable 拷贝（第 371 行）
  int generate_inc_major_copy_tasks_();  // 增量 MAJOR 拷贝（第 377 行）
  int generate_mds_copy_tasks_();        // MDS 数据拷贝（第 405 行）

  // 物理拷贝核心
  int generate_physical_copy_task_();    // Macro Block 级别物理拷贝（第 384 行）
  int generate_tablet_finish_migration_task_(); // 完成 Tablet 迁移（第 390 行）
};
```

数据拷贝的几种策略：

| 拷贝类型 | 内容 | 方式 |
|----------|------|------|
| **Major Copy** | BASE SSTable | 全量 Macro Block 物理拷贝 |
| **Minor Copy** | Minor SSTable | 增量数据（不重复拷贝 BASE） |
| **DDL Copy** | DCL SSTable | DDL 产生的临时 SSTable |
| **Inc Major** | 增量 MAJOR | MAJOR 合并后的增量部分 |
| **MDS Copy** | MDS 数据 | Meta Data Service 记录 |

---

## 4. 副本重建回调（ObLSRebuildCbImpl）

当 LS 需要从源端重建副本时，`ObLSRebuildCbImpl` 是入口。

**文件：** `src/storage/high_availability/ob_ls_rebuild_cb_impl.h`，第 29–51 行

```cpp
class ObLSRebuildCbImpl
{
public:
  int init(ObLS *ls, bandwidth_throttle, svr_rpc_proxy, storage_rpc);
  int on_rebuild();                 // 重建入口（第 39 行）
  bool is_rebuilding();             // 是否正在重建（第 40 行）
  void destroy();

private:
  int check_ls_in_rebuild_status_();    // 检查重建状态（第 43 行）
  int execute_rebuild_();               // 执行重建流程（第 44 行）
  int wakeup_rebuild_service_();        // 唤醒重建服务（第 45 行）
};
```

重建服务自动选择最优数据源（Paxos 成员中进度最快的副本），通过 `ObStorageHASrcInfo` 记录数据源信息。

---

## 5. Transfer 机制

### 5.1 Transfer vs Migration

**LS 迁移（Migration）：** 整个 LS 从节点 A 搬到节点 B，涉及 LS 内所有 Tablet。

**Partition Transfer：** Tablet 在同一个 Zone 内的不同 LS 之间移动（LS 本身不跨节点）。主要用于：
- 分区 Split（一个分区过大，拆成两个）
- 分区 Merge（多个小分区合并）
- 负载均衡（将 Tablet 从热点 LS 移到冷 LS）

### 5.2 ObTransferService — Transfer 调度线程

**文件：** `src/storage/high_availability/ob_transfer_service.h`，第 28–54 行

```cpp
class ObTransferService : public share::ObThreadPool
{
public:
  int init(ObLSService *ls_service);
  void run1();           // 调度线程主循环
  void wakeup();
  int start();
  void stop();
  void wait();

private:
  int get_ls_id_array_();
  int scheduler_transfer_handler_();    // 调度 Transfer Handler
  int do_transfer_handler_();            // 执行 Transfer Handler 处理
  ObLSService *ls_service_;
  ObSEArray<share::ObLSID, 16> ls_id_array_;
};
```

### 5.3 ObTransferHandler — Transfer 执行器

**文件：** `src/storage/high_availability/ob_transfer_handler.h`，第 44–466 行

这是 `.h` 文件中方法最多的类之一（超过 70 个方法）。以下是核心流程：

```
Transfer 处理主流程

do_leader_transfer_()           ← Leader 执行转移决策
  │
  ├→ get_transfer_task_()       ← 从 __all_ls_transfer_task 内表获取任务
  │
  ├→ do_with_start_status_()    ← 处理 START 状态
  │   ├→ init_transfer_ls_info_()
  │   ├→ check_self_is_leader_()
  │   ├→ lock_src_and_dest_ls_member_and_learner_list_()
  │   ├→ do_trans_transfer_start_()
  │   │   ├→ do_trans_transfer_start_prepare_()   ← 准备阶段
  │   │   ├→ wait_tablet_write_end_()             ← 等待写完成
  │   │   └→ do_trans_transfer_start_v2_()        ← 执行转移启动
  │   ├→ do_trans_transfer_dest_prepare_()        ← 目标 LS 准备
  │   └→ do_tx_start_transfer_out_()             ← 事务转移出去
  │
  ├→ do_with_doing_status_()    ← 处理 DOING 状态
  │   ├→ do_tx_start_transfer_in_()              ← 事务转移到目标 LS
  │   │   ├→ inner_tx_start_transfer_in_()
  │   │   ├→ update_all_tablet_to_ls_()
  │   │   └→ update_all_session_tablet_to_temporary_table_()
  │   ├→ lock_tablet_on_dest_ls_for_table_lock_()
  │   └→ update_transfer_status_()
  │
  └→ do_with_aborted_status_()  ← 处理 ABORTED 状态（回滚）
      ├→ do_trans_transfer_aborted_()
      └→ wait_transfer_in_tablet_abort_()
```

Transfer 状态机：

```
START → [源端准备] → [目标端准备] → DOING → [数据转移] → [事务切换] → FINISHED
  │                                                          │
  └──→ ABORTED ←─────────────────────────────────────────────┘
                   任何阶段出错都可回滚
```

### 5.4 Transfer 期间的事务处理

Transfer 的核心难点是**在保证一致性的前提下，将正在执行的事务也迁移到新 LS 上**。这是通过 `do_tx_start_transfer_out_()` 和 `do_tx_start_transfer_in_()` 配合完成的：

```
┌──────────────────────────┐         ┌──────────────────────────┐
│       源 LS               │         │      目标 LS              │
│  阻塞新写入 → block_tx_()  │         │                          │
│  ┌──────────────────┐     │         │  ┌──────────────────┐    │
│  │ 已提交 → 数据拷贝  │     │   RPC    │  │ 接收数据写入      │    │
│  │ 未提交 → TX 上下文 │────┼─────────┼─►│ 未提交 TX 继续执行 │    │
│  │         拷贝      │     │         │  └──────────────────┘    │
│  └──────────────────┘     │         │                          │
│  等待 replay 到 start_scn │         │  update_all_tablet_to_ls_ │
│  更新 Meta 表             │         │  广播新位置               │
└──────────────────────────┘         └──────────────────────────┘
```

---

## 6. 成员列表管理（ObLSMemberListService）

**文件：** `src/storage/high_availability/ob_ls_member_list_service.h`，第 26–87 行

```cpp
class ObLSMemberListService
{
public:
  int init(ObLS *ls, logservice::ObLogHandler *log_handler);

  // 成员变更操作
  int add_member(const common::ObMember &member, ...);           // 第 39 行
  int replace_member(const common::ObMember &old, ...);          // 第 42 行
  int switch_learner_to_acceptor(const common::ObMember &learner); // 第 45 行
  int replace_member_with_learner(const common::ObMember &old);    // 第 48 行
  int replace_learners(const common::ObMember &learner, ...);     // 第 51 行

  // Transfer SCN 管理
  int get_max_tablet_transfer_scn(...);                         // 第 55 行
  int get_leader_config_version_and_transfer_scn_(...);          // 第 58 行
};
```

成员变更的几种场景：

1. **迁移新副本** → `add_member` 先以 Learner 加入，然后 `switch_learner_to_acceptor`
2. **替换故障副本** → `replace_member` 原子替换
3. **Transfer** → 需要同时锁定源和目标 LS 的成员列表，通过 `lock_src_and_dest_ls_member_and_learner_list_()`
4. **SCN 检查** → `check_ls_transfer_scn_validity_()` 确保 Transfer 期间版本一致性

---

## 7. 迁移期间的阻塞策略（ObLSBlockTxService）

迁移必须保证一致性，因此在数据同步阶段需要阻止新的写入。

**文件：** `src/storage/high_availability/ob_ls_block_tx_service.h`，第 23–58 行

```cpp
class ObLSBlockTxService
{
public:
  // 阻塞/恢复操作
  int ha_block_tx(const share::SCN &block_scn);        // 阻塞事务（第 46 行）
  int ha_kill_tx(const share::SCN &kill_scn);           // Kill 已有事务（第 47 行）
  int ha_unblock_tx(const int64_t ha_seq);              // 解除阻塞（第 48 行）

  // Leader 切换协议
  void switch_to_follower_forcedly();
  void switch_to_leader();
  void switch_to_follower_gracefully();
  void resume_leader();

  // 日志回放
  int replay(const share::SCN &scn, const int64_t ha_seq);

private:
  int check_is_leader_();
  int check_seq_(const int64_t ha_seq);
  int update_seq_(const int64_t ha_seq);

  int64_t cur_seq_;     // 当前阻塞序列号（第 57 行）
  ObLS *ls_;
};
```

### 阻塞时序

```
                       时间 ──►
Normal Ops:  |--- write ----|--- write ----|--- write ----|
             ↑  ha_block_tx(SCN₁)
              ↓             ↑ ha_unblock_tx(seq₁)
Blocked:     |--- BLOCKED ---|
              ↑ ha_kill_tx(SCN₁)
Kill TX:     |--- KILL TX ----|

迁移的阻塞触发点：

PREPARE → 未阻塞
BUILD   → block_tx → 数据同步完成 → unblock_tx
COMPLETE→ block_tx → 角色切换 → unblock_tx
```

阻塞的时间窗口要尽量短。实际的阻塞只在 **COMPLETE 阶段** 的最后一小段才触发。

---

## 8. 完整迁移数据流

### 8.1 LS 迁移时序（完整流程）

```
源节点 (Src)                 目标节点 (Dst)              RootServer
   │                            │                         │
   │     Trigger: 负载不均 / 故障恢复                        │
   │                            │                         │
   │                            │  创建 __all_ls_migration_task
   │                            │◄────────────────────────┘
   │                            │
   │                    ┌───────┴────────┐
   │                    │ 1. INIT        │
   │                    │ task_list_ 追加 │
   │                    └───────┬────────┘
   │                            │
   │                    ┌───────┴────────┐
   │                    │ 2. PREPARE     │
   │                    │ 创建 LS 对象    │
   │                    │ 分配 LS ID     │
   │                    │ 设置 DAG       │
   │                    └───────┬────────┘
   │                    ┌───────┴────────┐
   │                    │ 3. WAIT_PREPARE│
   │                    │ 轮询 DAG 完成   │
   │                    └───────┬────────┘
   │                            │
   │◄─── fetch_ls_info RPC ─────┤
   │─── src_ls_meta_package ───►│
   │                            │
   │                    ┌───────┴────────┐
   │                    │ 4. BUILD_LS    │
   │                    │ join_learner_list_
   │◄─── 加入 Learner ──┤
   │                    │ ls_online_()
   │                    │                │
   │                    │ begin DAG Net: │
   │                    │ ├─ SysTablets  │
   │◄─── 拷贝系统 Tablet ─┤              │
   │                    │ ├─ DataTablets │
   │◄─── block_tx ──────┤  │             │
   │                    │  ├─ TabletGroup│
   │◄─── 全量 + 增量拷贝 ─┤  │            │
   │                    │  ├─ ...        │
   │◄─── Sync PALF log ─┤  └─ Finish     │
   │                    │ └─ FinishDag   │
   │                    └───────┬────────┘
   │                    ┌───────┴────────┐
   │                    │ 5. COMPLETE_LS │
   │                    │ switch_learner__
   │                    │   _to_acceptor  │
   │                    │ update_member   │
   │                    │   _list         │
   │                    │ release_old_    │
   │                    │   replica       │
   │◄─── 成员变更 ──────┤                │
   │                    ├─ report_meta_   │
   │                    │   table         │
   │                    └───────┬────────┘
   │                            │
   │                    ┌───────┴────────┐
   │                    │ 6. FINISH      │
   │                    │ report_result_  │
   │                    │ cleanup          │
   │                    └───────┬────────┘
   │                            │
   │ 释放旧副本                  │  更新位置缓存
   │◄──────────────────────────►│◄────────────────────────┘
```

### 8.2 Tablet 数据拷贝细节

```
ObTabletMigrationTask::process()
  │
  ├→ 1. build_copy_table_key_info_()      ← 确定哪些 SSTable 需要拷贝
  │
  ├→ 2. build_copy_sstable_info_mgr_()    ← 构建拷贝信息管理器
  │
  ├→ 3. generate_physical_copy_task_()    ← 生成 Macro Block 拷贝任务
  │   ├→ generate_minor_copy_tasks_()     ← 增量 SSTable 级别拷贝
  │   ├→ generate_major_copy_tasks_()     ← 全量 MAJOR SSTable 拷贝
  │   ├→ generate_ddl_copy_tasks_()       ← DDL SSTable 拷贝
  │   ├→ generate_inc_major_copy_tasks_() ← 增量 MAJOR 拷贝
  │   └→ generate_mds_copy_tasks_()       ← MDS 数据拷贝
  │
  ├→ 4. generate_tablet_finish_migration_task_() ← 完成拷贝
  │   ├→ check_tablet_replica_validity_()  ← 校验副本有效性
  │   ├→ update_ha_expected_status_()     ← 更新 HA 状态
  │   └→ try_update_tablet_()            ← 更新 Tablet 元数据
  │
  └→ 5. check_transfer_seq_equal_()       ← 检查 Transfer 序列号一致性
```

---

## 9. 与前面文章的关联

| 文章 | 关联点 | 说明 |
|------|--------|------|
| `07-ls-logstream-analysis` | **LS 结构** | 迁移的粒度为 LS 级别，迁移后 LS 的 Tablet 集合不变 |
| `11-palf-analysis` | **PALF 日志同步** | BUILD 阶段需要同步 PALF 日志，确保新副本的日志进度与源一致 |
| `12-election-analysis` | **Election** | 迁移完成后，新位置的 LS Leader 可能变更，触发重新选举 |
| `08-ob-sstable-analysis` | **SSTable 存储** | 迁移中拷贝的是 SSTable 的 Macro Block，复用存储层的数据格式 |

---

## 10. 设计决策分析

### 10.1 为什么要用全量 + 增量两阶段同步？

OceanBase 的迁移不是一个原地复制操作，而是一个**在线迁移**。

```
全量：  先拷贝 BASE SSTable，可能已经落后
    │
增量 1： 同步 BASE 之后的 Minor SSTable
    │
增量 2： 再次同步新的增量（可能还需 PALF 日志）
    │
阻塞：  短暂阻塞写入，同步最后一小段增量
    │
完成：  切换角色
```

**为什么不能只做全量？**
- 数据一直在写入，全量拷贝过程中源端数据在变
- 如果全量完成后直接切换，会有大量遗漏数据

**为什么不能只做增量？**
- 新节点上没有数据底座，增量需要完整的 BASE 才能应用

因此全量 + 增量是最小化阻塞窗口的标准分布式模式。

### 10.2 迁移期间的写入阻塞窗口

OceanBase 的迁移通过精细的阶段划分，将阻塞窗口压缩到最短：

- **PREPARE + 大部分 BUILD** → 源端完全正常服务（无阻塞）
- **BUILD 最后一步** → `ObLSBlockTxService::ha_block_tx()` 阻塞新事务
- **PALF 日志同步完成** → `ha_unblock_tx()` 解除阻塞

阻塞时间 ≈ 最后一小段增量同步 + 日志同步 + 角色切换的时间，通常在秒级甚至毫秒级。

### 10.3 Transfer vs Rebuild 的选择策略

OceanBase 根据触发条件选择不同的恢复策略：

| 场景 | 策略 | 理由 |
|------|------|------|
| 节点宕机 | **Rebuild** | 源 LS 可能不可用，从其他副本重建 |
| 新节点加入 | **Migration** | 将整个 LS 搬到新节点 |
| 负载均衡 | **Migration** | LS 级别搬移 |
| 热点分区 | **Transfer** | 只需移动部分 Tablet，不必搬整个 LS |
| 分区 Split/Merge | **Transfer** | DDL 操作，仅涉及 Tablet 级别的变更 |

### 10.4 为什么要有 Lift/Checkpoint 推进？

迁移期间，`ObLSMigrationHandler` 保留 `advance_checkpoint_scn_`（第 190 行）和 `last_advance_checkpoint_ts_`（第 189 行）：

```cpp
int64_t last_advance_checkpoint_ts_;
share::SCN advance_checkpoint_scn_;
```

推进 checkpoint 的原因：
1. 迁移完成后，源端可能会马上被删除，需要确保 checkpoint 已经推进到安全位置
2. 避免迁移后依赖源端数据做 PALF 日志回收

---

## 11. 源码索引

| 文件 | 路径 | 核心类/符号 |
|------|------|-------------|
| `ob_ls_migration_handler.h` | `src/storage/high_availability/` | `ObLSMigrationHandler`，第 84 行 |
| `ob_ls_prepare_migration.h` | `src/storage/high_availability/` | `ObLSPrepareMigrationCtx`，第 36 行 |
| `ob_ls_migration.h` | `src/storage/high_availability/` | `ObMigrationDagNet`，第 125 行；`ObTabletMigrationTask`，第 354 行 |
| `ob_ls_complete_migration.h` | `src/storage/high_availability/` | `ObLSCompleteMigrationCtx`，第 36 行 |
| `ob_ls_rebuild_cb_impl.h` | `src/storage/high_availability/` | `ObLSRebuildCbImpl`，第 29 行 |
| `ob_transfer_handler.h` | `src/storage/high_availability/` | `ObTransferHandler`，第 44 行 |
| `ob_transfer_service.h` | `src/storage/high_availability/` | `ObTransferService`，第 28 行 |
| `ob_ls_member_list_service.h` | `src/storage/high_availability/` | `ObLSMemberListService`，第 26 行 |
| `ob_ls_block_tx_service.h` | `src/storage/high_availability/` | `ObLSBlockTxService`，第 23 行 |
| `ob_tablet_transfer_info.h` | `src/storage/high_availability/` | Tablet Transfer 元信息 |
| `ob_transfer_partition_task.h` | `src/rootserver/` | RootServer 端 Transfer 任务 |
| `ob_tenant_transfer_service.h` | `src/rootserver/` | RootServer 端 Transfer 调度 |

---

## 12. 总结

OceanBase 的分区迁移与负载均衡系统展示了一个分布式 OLTP 数据库在 HA 层面的工程实践：

1. **DAG 驱动** — 每个迁移阶段都是一个 DAG Net，通过 DAG 调度器异步执行，支持并行和重试
2. **状态机保证正确性** — 8 个状态的严谨转换，处理各种异常路径（失败、取消、超时）
3. **全量 + 增量两阶段** — 最小化写入阻塞窗口，实现在线迁移
4. **分而治之** — LS 迁移（跨节点）和 Tablet Transfer（同节点 LS 间）分别处理不同粒度的场景
5. **事务一致性** — Transfer 期间通过 tx_ctx 的移动保证分布式事务不中断

结合前面文章中分析的 LS Tree（文章 07）、PALF（文章 11）、Election（文章 12），可以看出 OceanBase 的整个数据生命周期是一条完整的链路：数据写入 → 日志共识 → 存储持久化 → 迁移与再均衡。
