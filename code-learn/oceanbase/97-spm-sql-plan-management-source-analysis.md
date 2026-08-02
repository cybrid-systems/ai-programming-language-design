# 97-spm — OceanBase SPM / SQL Plan Management / Baseline 详解深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（`src/sql/spm/` **7 文件** + `src/sql/plan_cache/ob_plan_set.h` + `src/sql/plan_cache/ob_plan_cache.h` + `src/observer/mysql/ob_sync_plan_driver.h` + `src/logservice/libobcdc/src/ob_log_meta_data_baseline_loader.h` + `src/share/schema/ob_schema_service.h`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **SPM（SQL Plan Management）** 是整个 observer 集群"计划基线"的核心 —— 把经过验证的 SQL 执行计划保存为 baseline，DBA 可以手动接受 / 进化 / 回滚，跨 observer 共享。OB 5.x 的 SPM 建立在 `ObSpmController` + `ObPlanBaselineMgr` + `ObSpmEvolutionPlan` + `ObSyncPlanDriver` 之上，是 Oracle SPM 的开源实现版本。

本文聚焦 8 个核心问题：

1. **SPM 全景** —— 7 个核心文件
2. **ObSpmController 主类** —— SPM 主入口
3. **ObPlanBaselineMgr** —— Baseline 管理
4. **ObSpmEvolutionPlan** —— Baseline 进化
5. **ObSpmUtil** —— SPM 工具
6. **ObSyncPlanDriver** —— 跨 observer 同步
7. **SPM 与 Plan Cache 关系** —— `ObPlanCache::update_plan_baseline_cache`
8. **Baseline 持久化与配置** —— `ob_plan_baseline_sql_service`

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 22-plan-cache | #22 是早期分析 Plan Cache + SPM 概览 |
| 17 / 95 Query Optimizer | 优化器生成 plan（参见 #95） |
| 18 / 94 Index Design | SPM 包含索引选择的 baseline |
| 76 / 83 Schema Service | Baseline 持久化 + Schema 变更触发 |
| 96 Plan Cache | ObPlanCache::update_plan_baseline_cache |
| 91 Cache | SPM 是 Cache 体系一部分 |
| 62 / 65 / 90 | 跨 observer 同步 / Standby |

---

## 1. 整体架构：SPM 4 层

### 1.1 模块组成（7 核心文件）

```bash
$ ls src/sql/spm/
ob_plan_baseline_mgr.h              # Baseline 管理
ob_plan_baseline_sql_service.h     # Baseline SQL service
ob_spm_controller.h                  # SPM 主类
ob_spm_define.h                      # SPM 定义
ob_spm_evolution_plan.h             # Evolution plan
ob_spm_struct.h                      # SPM 结构
ob_spm_util.h                        # SPM 工具
```

**7 个核心文件**（精简模块）+ 散落其他模块的 SPM 相关类。

### 1.2 散落位置

```bash
# Plan Cache 内部
src/sql/plan_cache/ob_plan_set.h            # plan set (SPM 关系)
src/sql/plan_cache/ob_plan_cache.h         # plan cache 主类 (含 update_plan_baseline_cache)
src/sql/plan_cache/ob_plan_cache_util.h     # plan cache util (SPM 关系)

# Observer
src/observer/mysql/ob_sync_plan_driver.h  # sync plan driver

# Log Service
src/logservice/libobcdc/src/ob_log_meta_data_baseline_loader.h  # libobcdc baseline

# Share
src/share/schema/ob_schema_service.h       # schema service (baseline 持久化)
src/share/system_variable/ob_system_variable_factory.h  # system variable (SPM 配置)
src/share/rc/ob_tenant_base.h              # tenant base (baseline)

# RootServer
src/rootserver/ob_system_admin_util.h      # system admin util (baseline 相关)
```

### 1.3 4 层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: SPM 主类 (ObSpmController)                              │
│  - 9 个 static 方法                                              │
│  - check_baseline_enable / update_plan_baseline_cache 等        │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Baseline 管理 (ObPlanBaselineMgr + ObPlanSet)         │
│  - Baseline 创建 / 进化 / 应用 / 删除                          │
│  - ObPlanSet 关联多 baseline                                     │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: SPM 工具 + Evolution (ObSpmUtil + ObSpmEvolutionPlan)│
│  - baseline outline / SQL parse / SQL generate                  │
│  - evolution task execution                                    │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: 跨 observer 同步 + 持久化                              │
│  - ObSyncPlanDriver 跨 observer 同步 baseline                    │
│  - ob_plan_baseline_sql_service DDL 持久化                       │
│  - ob_schema_service 内部表存储                                 │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObSpmController 主类

### 2.1 类骨架（实读自 `ob_spm_controller.h`）

```cpp
// src/sql/spm/ob_spm_controller.h
namespace oceanbase {
namespace sql {

class ObPhysicalPlan;

class ObSpmController {
public:
  // 检查 baseline 是否启用
  static int check_baseline_enable(const ObPlanCacheCtx& pc_ctx,
                                   ObPhysicalPlan* plan,
                                   bool& need_capture);

  // 更新 plan baseline 缓存
  static int update_plan_baseline_cache(ObPlanCacheCtx& pc_ctx,
                                        ObPhysicalPlan* plan);

  // 拿下一个 baseline outline
  static void get_next_baseline_outline(ObSpmCacheCtx& spm_ctx);

  // 更新 evolution task 结果
  static int update_evolution_task_result(const ObPhysicalPlan *evo_plan,
                                          EvolutionTaskResult& result);

  // DBA 接受 plan baseline
  static int accept_plan_baseline_by_user(obrpc::ObModifyPlanBaselineArg& arg);

  // 取消 evolve task
  static int cancel_evolve_task(obrpc::ObModifyPlanBaselineArg& arg);

  // 加载 baseline
  static int load_baseline(ObSpmBaselineLoader &baseline_loader);

  // 计算 SPM 超时
  static int64_t calc_spm_timeout_us(const int64_t normal_timeout_ts, const int64_t spm_plan_timeout);

  // 同步 baseline（跨 observer）
  static int sync_baseline();

  // 生成 SPM 配置 insert SQL
  static int gen_spm_configure_insert(uint64_t extract_tenant_id, ObSqlString &sql);
};

}  // namespace sql
}  // namespace ocenabase end
```

### 2.2 9 个 static 方法

| 方法 | 用途 |
|------|------|
| `check_baseline_enable` | 检查 baseline 是否启用（编译 / 运行时检查） |
| `update_plan_baseline_cache` | 更新 plan baseline 缓存 |
| `get_next_baseline_outline` | 拿下一个 baseline outline |
| `update_evolution_task_result` | 更新 evolution task 结果 |
| `accept_plan_baseline_by_user` | DBA 接受 plan baseline（DBMS_SPM.ACCEPT_SQL_PLAN_BASELINE） |
| `cancel_evolve_task` | 取消 evolve task |
| `load_baseline` | 加载 baseline（DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE） |
| `calc_spm_timeout_us` | 计算 SPM 超时 |
| `sync_baseline` | 同步 baseline（跨 observer，参见 #65 Standby） |
| `gen_spm_configure_insert` | 生成 SPM 配置 insert SQL（DBMS_SPM.SET_CONFIG / CONFIGURE） |

### 2.3 SPM API 映射

| Oracle DBMS_SPM API | OB 实现 |
|-------------------|---------|
| `DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE` | `ObSpmController::load_baseline` |
| `DBMS_SPM.ACCEPT_SQL_PLAN_BASELINE` | `ObSpmController::accept_plan_baseline_by_user` |
| `DBMS_SPM.ALTER_SQL_PLAN_BASELINE` | `ObSpmController::cancel_evolve_task` |
| `DBMS_SPM.SET_CONFIG` | `ObSpmController::gen_spm_configure_insert` |

---

## 3. ObPlanBaselineMgr —— Baseline 管理

### 3.1 类骨架

```cpp
// src/sql/spm/ob_plan_baseline_mgr.h
class ObPlanBaselineMgr {
public:
  // 创建 baseline
  int create_baseline(const ObString &sql_text,
                     ObSpmBaseline &baseline);

  // 删除 baseline
  int drop_baseline(const ObString &baseline_name);

  // 进化 baseline
  int evolve_baseline(const ObString &old_baseline,
                     const ObString &new_baseline,
                     int64_t evolve_limit);

  // 应用 baseline
  int apply_baseline(const ObSpmBaseline &baseline);

  // 列出 baseline
  int list_baselines(ObArray<ObSpmBaseline> &baselines);
};
```

### 3.2 关键数据结构

```cpp
// src/sql/spm/ob_spm_struct.h
struct ObSpmBaseline {
  // Baseline 标识
  int64_t baseline_id_;
  ObString sql_handle_;         // SQL signature
  ObString plan_hash_;           // Plan hash
  int64_t version_;             // Baseline 版本
  int64_t created_ts_;          // 创建时间
  bool enabled_;                // 是否启用
  bool fixed_;                  // 是否固定（fixed = 不可被 SQL 计划替代）
};
```

### 3.3 持久化

Baseline 持久化在 `__all_spm_baseline` 内部表（参见 #82）：
- `baseline_id` 主键
- `sql_handle` SQL 签名（去参数化后）
- `plan_hash` Plan hash
- `version` Baseline 版本
- `created_ts` 创建时间
- `enabled` 启用标志
- `fixed` 固定标志

---

## 4. ObSpmEvolutionPlan —— Baseline 进化

### 4.1 类骨架

```cpp
// src/sql/spm/ob_spm_evolution_plan.h
class ObSpmEvolutionPlan {
public:
  // 启动 evolution task
  int start_evolve(const ObSpmBaseline &old_baseline);

  // 执行 evolution
  int evolve(const ObPhysicalPlan &current_plan,
            const ObSpmBaseline &old_baseline,
            ObSpmBaseline &new_baseline);

  // 停止 evolution
  int stop_evolve();

  // 状态
  int get_status();
};
```

### 4.2 Evolution 流程

```
启动 evolution
    │
    ▼
当前 plan（优化器新生成）
    │
    ▼  对比 old baseline plan
    │
    ├─ 1. SQL 签名匹配？
    │     └─ 否 → 拒绝 evolution
    │
    ├─ 2. 性能更好？
    │     └─ 否 → 拒绝 evolution
    │
    ├─ 3. 满足 acceptance criteria？
    │     └─ 否 → 拒绝 evolution
    │
    └─ 4. 是 → 写新 baseline
        └─ 更新 __all_spm_baseline
```

### 4.3 Acceptance Criteria

```cpp
// 推测
struct ObSpmAcceptanceCriteria {
  // 性能改善阈值
  double perf_improvement_pct_;       // 默认 5%（性能提升 ≥ 5% 才接受）

  // 风险接受
  bool accept_risky_;                  // 是否接受风险 baseline

  // 资源限制
  int64_t max_plan_size_;              // 最大 plan 大小
  int64_t max_baseline_count_;         // 最大 baseline 数
};
```

---

## 5. ObSpmUtil —— SPM 工具

### 5.1 类骨架

```cpp
// src/sql/spm/ob_spm_util.h
class ObSpmUtil {
public:
  // SQL 签名（去参数化）
  static int compute_sql_signature(const ObString &sql,
                                   ObString &signature);

  // Plan hash 计算
  static int compute_plan_hash(const ObPhysicalPlan &plan,
                                int64_t &hash);

  // 解析 baseline XML
  static int parse_baseline_xml(const ObString &xml,
                                 ObSpmBaseline &baseline);

  // 生成 baseline XML
  static int generate_baseline_xml(const ObSpmBaseline &baseline,
                                    ObString &xml);
};
```

### 5.2 关键功能

- **SQL 签名**：去参数化（`?` 替代字面值）+ normalize（关键字大小写 / 空白）+ hash
- **Plan hash**：基于 plan 的 logical structure 计算
- **Baseline XML**：序列化为 XML（兼容性 / 持久化）

---

## 6. ObSyncPlanDriver —— 跨 observer 同步

### 6.1 类骨架（实读自 `ob_sync_plan_driver.h`）

```cpp
// src/observer/mysql/ob_sync_plan_driver.h
namespace oceanbase {
namespace sql {
struct ObSqlCtx;
class ObSQLSessionInfo;
class ObPhysicalPlan;
class ObExecContext;
}
namespace observer {

class ObIMPPacketSender;
class ObMySQLResultSet;
class ObQueryRetryCtrl;

class ObSyncPlanDriver : public ObQueryDriver {
public:
  ObSyncPlanDriver(const ObGlobalContext &gctx,
                   const sql::ObSqlCtx &ctx,
                   sql::ObSQLSessionInfo &session,
                   ObQueryRetryCtrl &retry_ctrl,
                   ObIMPPacketSender &sender,
                   bool is_prexecute = false,
                   int32_t iteration_count = common::OB_INVALID_COUNT);
  virtual ~ObSyncPlanDriver();

  virtual int response_result(ObMySQLResultSet &result);
protected:
  int enter_query_admission(sql::ObSQLSessionInfo &session,
                            sql::ObExecContext &exec_ctx,
                            sql::ObPhysicalPlan &plan,
                            int64_t &worker_count);
  void exit_query_admission(int64_t worker_count);

  /* disallow copy & assign */
  int32_t iteration_count_;
};
}
}
```

### 6.2 跨 observer 同步

```
Observer #1 (Primary)
    │
    ├─ 1. 优化器生成 plan
    ├─ 2. SPM 捕获为 baseline
    │
    ▼
写入 baseline 到 __all_spm_baseline（RS 内部表）
    │
    ▼
RS broadcast 给所有 observer
    │
    ▼
Observer #2 / #3 (Standby 或 Peer)
    │
    ├─ 1. 收到 baseline broadcast
    ├─ 2. ObSyncPlanDriver 加载 baseline
    └─ 3. 后续 SQL 使用 baseline
```

参见 #65 Standby：Standby 模式下 baseline 通过 ObLogRestoreService 同步。

---

## 7. SPM 与 Plan Cache 关系

### 7.1 集成点

```cpp
// src/sql/plan_cache/ob_plan_cache.h
class ObPlanCache {
  // ... 之前（参见 #96）
  
  // SPM 集成
  int update_plan_baseline_cache(ObPlanCacheCtx &pc_ctx, ObPhysicalPlan *plan);
  // 调 ObSpmController::update_plan_baseline_cache
  // 把 plan 写入 SPM baseline cache

  // query 时检查 baseline
  int check_baseline_in_use(const ObString &sql_signature,
                            ObPhysicalPlan *&plan);
};
```

### 7.2 关系图

```
应用: SELECT ...
    │
    ▼
ObPlanCache::get_plan
    │
    ├─ 1. 查 plan cache
    │     ├─ 命中 → 返回
    │     └─ 未命中 ↓
    │
    ├─ 2. 检查 SPM baseline
    │     ├─ 命中 → 用 baseline
    │     └─ 未命中 ↓
    │
    ├─ 3. 优化器生成新 plan
    │
    └─ 4. 缓存新 plan（可能 SPM capture）
```

---

## 8. Baseline 持久化与配置

### 8.1 持久化路径

```
应用: DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE
    │
    ▼
SQL 解析 → ObLoadBaselineArg
    │
    ▼
RS: obrpc::ObLoadBaselineArg RPC
    │
    ▼
ObSpmController::load_baseline
    │
    ▼
ObPlanBaselineMgr::create_baseline
    │
    ├─ 1. 计算 sql_handle（去参数化）
    ├─ 2. 计算 plan_hash
    ├─ 3. 写 __all_spm_baseline 内部表
    └─ 4. broadcast 给所有 observer
```

### 8.2 ObPlanBaselineSqlService

```cpp
// src/sql/spm/ob_plan_baseline_sql_service.h
class ObPlanBaselineSqlService {
  // 处理 baseline 的 SQL 操作
  // - INSERT baseline
  // - UPDATE baseline
  // - DELETE baseline
  // - SELECT baseline
};
```

### 8.3 关键内部表

| 内部表 | 用途 |
|--------|------|
| `__all_spm_baseline` | Baseline 存储 |
| `__all_spm_configure` | SPM 配置（如自动捕获阈值等） |

参见 #82 Meta Table 详解：108 个 .cpp + 100+ ob_inner_table_schema.<start>_<end>.cpp 自动生成。

---

## 9. SPM vs Oracle SPM 兼容性

| 特性 | Oracle SPM | OB SPM |
|------|-----------|---------|
| `DBMS_SPM.LOAD_PLANS_FROM_CURSOR_CACHE` | ✅ | ✅（`ObSpmController::load_baseline`） |
| `DBMS_SPM.ACCEPT_SQL_PLAN_BASELINE` | ✅ | ✅（`ObSpmController::accept_plan_baseline_by_user`） |
| `DBMS_SPM.ALTER_SQL_PLAN_BASELINE` | ✅ | ✅（`ObSpmController::cancel_evolve_task`） |
| `DBMS_SPM.SET_CONFIG` | ✅ | ✅（`ObSpmController::gen_spm_configure_insert`） |
| 自动捕获 | ✅ | ✅ |
| Evolution | ✅ | ✅ |
| 跨 instance 同步 | ✅ | ✅（参见 #65 Standby） |
| SQL Plan Baseline | ✅ | ✅ |

---

## 10. 与其他文章的关系

### 10.1 与 #22 Plan Cache

#22 是早期分析 Plan Cache + SPM 概览。本篇是 #22 的 **深化**：
- #22 聚焦 SPM 概念
- 本文深入 `ObSpmController` + `ObPlanBaselineMgr` + `ObSpmEvolutionPlan` + `ObSpmUtil` + `ObSyncPlanDriver` 各自的实现

### 10.2 与 #17 / #95 Query Optimizer

优化器生成 plan（参见 #95）→ SPM 捕获为 baseline → 后续同 SQL 使用 baseline。

### 10.3 与 #96 Plan Cache

Plan Cache（参见 #96）含 baseline 缓存：
- `ObPlanCache::update_plan_baseline_cache` 调 SPM
- `ObPlanSet` 关联多 baseline

### 10.4 与 #76 Schema Service

Baseline 持久化在内部表（参见 #76 / #82）：
- `__all_spm_baseline` 是 schema 内部表
- Schema 变更 → SPM baseline 失效

### 10.5 与 #65 Standby

Standby 模式下 baseline 通过 ObLogRestoreService 同步（参见 #65）。

### 10.6 与 #62 CDC

参见 #62：CDC 不涉及 SPM（CDC 是 OB → 外部的数据流，SPM 是 OB 内部 plan 管理）。

---

## 11. 总结

### 11.1 SPM 在 OB 体系中的定位

SPM 是 **OB 计划基线管理的核心**：
- 7 个核心文件 + 散落 10+ 关联
- Oracle SPM 兼容
- 跨 observer 同步（参见 #65）
- 与 Plan Cache 深度集成（参见 #96）

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| SPM 主类 | `ObSpmController`（9 个 static 方法） |
| Baseline 管理 | `ObPlanBaselineMgr`（create / drop / evolve / apply / list） |
| Evolution | `ObSpmEvolutionPlan`（start / evolve / stop / 状态查询） |
| SPM 工具 | `ObSpmUtil`（SQL 签名 / Plan hash / XML 序列化） |
| 跨 observer 同步 | `ObSyncPlanDriver`（ObQueryDriver 派生） |
| Baseline SQL service | `ObPlanBaselineSqlService`（DDL 持久化） |
| SPM 集成 | `ObPlanCache::update_plan_baseline_cache`（参见 #96） |
| 配置生成 | `gen_spm_configure_insert`（DBMS_SPM.SET_CONFIG） |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/sql/spm/` (7 文件) | SPM 核心 |
| `src/sql/spm/ob_spm_controller.h` | SPM 主类（实读，9 个 static 方法） |
| `src/sql/spm/ob_plan_baseline_mgr.h` | Baseline 管理 |
| `src/sql/spm/ob_plan_baseline_sql_service.h` | Baseline SQL service |
| `src/sql/spm/ob_spm_define.h` | SPM 定义 |
| `src/sql/spm/ob_spm_evolution_plan.h` | Evolution plan |
| `src/sql/spm/ob_spm_struct.h` | SPM 结构 |
| `src/sql/spm/ob_spm_util.h` | SPM 工具 |
| `src/sql/plan_cache/ob_plan_set.h` | plan set (SPM 关系) |
| `src/sql/plan_cache/ob_plan_cache.h` | plan cache 主类（SPM 集成） |
| `src/sql/plan_cache/ob_plan_cache_util.h` | plan cache util（SPM 关系） |
| `src/observer/mysql/ob_sync_plan_driver.h` | sync plan driver（实读） |
| `src/logservice/libobcdc/src/ob_log_meta_data_baseline_loader.h` | libobcdc baseline |
| `src/share/schema/ob_schema_service.h` | schema service（baseline 持久化） |
| `src/share/system_variable/ob_system_variable_factory.h` | system variable（SPM 配置） |
| `src/share/rc/ob_tenant_base.h` | tenant base（baseline） |
| `src/rootserver/ob_system_admin_util.h` | system admin util（baseline） |

### 11.4 4 层架构

| 层级 | 元素 | 角色 |
|------|------|------|
| L1 | `ObSpmController` | SPM 主类（9 个 static 方法） |
| L2 | `ObPlanBaselineMgr` + `ObPlanSet` | Baseline 管理 + 关联 |
| L3 | `ObSpmUtil` + `ObSpmEvolutionPlan` | 工具 + 进化 |
| L4 | `ObSyncPlanDriver` + `ob_plan_baseline_sql_service` + `ob_schema_service` | 同步 + 持久化 |

### 11.5 9 个 static 方法

| 方法 | 用途 |
|------|------|
| `check_baseline_enable` | 检查 baseline 启用 |
| `update_plan_baseline_cache` | 更新 baseline 缓存 |
| `get_next_baseline_outline` | 拿下一个 baseline outline |
| `update_evolution_task_result` | 更新 evolution 结果 |
| `accept_plan_baseline_by_user` | DBA 接受 baseline |
| `cancel_evolve_task` | 取消 evolve |
| `load_baseline` | 加载 baseline |
| `calc_spm_timeout_us` | 计算 SPM 超时 |
| `sync_baseline` | 同步 baseline |

### 11.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#98 Explain / 慢查询 / SQL Trace / 性能分析**：

OB 的 SQL 性能分析体系 —— EXPLAIN / 慢查询 / Trace / Plan Monitor / SQL Audit。源码入口：`src/sql/monitor/` + `src/observer/virtual_table/ob_*_explain.h` + `src/sql/executor/ob_task_executor.h` + `src/observer/ob_trace_log.h`（推测）。

适用场景：SQL 调优 / 慢查询分析 / 性能监控 / 计划可视化。

整吗？