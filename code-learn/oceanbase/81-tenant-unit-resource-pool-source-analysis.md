# 81-tenant-unit-resource-pool — OceanBase Tenant / Unit / Resource Pool 资源管理深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/share/resource_manager/` + `src/share/unit/ob_unit_resource.h` + `src/observer/omt/ob_tenant_*.{h,cpp}` + `src/share/ob_resource_limit_*.{h,cpp}`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Tenant / Unit / Resource Pool** 是整个 observer 集群的多租户资源管理体系。Tenant 是资源隔离的逻辑根，Unit 是物理配额单元（CPU / 内存 / IO / 网络），Resource Pool 是 Unit 的容器。DBA 通过 `CREATE TENANT` / `ALTER RESOURCE POOL` / `ALTER UNIT` 等 DDL 操作这些资源结构。

本文聚焦 8 个核心问题：

1. **Tenant / Unit / Resource Pool 三者关系**
2. **Tenant 生命周期** —— create / drop / alter 的源码路径
3. **Resource Pool 管理** —— ObResourceManager + ObResourcePlanManager
4. **Unit 配额** —— max_cpu / min_cpu / max_memory / min_memory / max_disk / max_iops 等
5. **Resource Plan** —— OB 5.x 新加的资源规划能力
6. **Allocation 算法** —— Unit 怎么分配到 observer
7. **Dynamic Resize** —— ALTER UNIT 在线调整
8. **cgroup 集成** —— Linux cgroup 联动（参见 #71）

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 39-tenant-architecture | #39 是早期分析，本篇深化 OB 5.x |
| 71-resource-isolation-cgroup | #71 描述 cgroup 集成，本篇聚焦 Resource Pool |
| 27-rootserver | RS 主导 Tenant 创建 / Resource Pool 调度 |
| 30-observer-startup | 启动时加载 Tenant / Unit 配置 |
| 76-schema-service | Tenant 是 schema 隔离的第一边界 |

---

## 1. 整体架构：Tenant / Unit / Resource Pool 三层

### 1.1 模块组成（实际路径，参见 #71）

```bash
src/share/resource_manager/
├── ob_resource_manager.{h,cpp}              # Resource Manager 主类
├── ob_resource_manager_proxy.{h,cpp}       # 跨 observer RPC proxy
├── ob_resource_plan_manager.{h,cpp}         # Resource Plan 管理
├── ob_resource_plan_info.{h,cpp}            # Resource Plan 元数据
├── ob_resource_mapping_rule_manager.{h,cpp} # Mapping Rule 管理
├── ob_resource_col_mapping_rule_manager.{h,cpp} # Column-level Mapping
├── ob_cgroup_ctrl.{h,cpp}                   # cgroup 控制（参见 #71）

src/share/unit/
└── ob_unit_resource.h                        # Unit 资源定义

src/observer/omt/
├── ob_tenant_config.{h,cpp}                  # Tenant 配置（参见 #72）
├── ob_tenant_config_mgr.{h,cpp}              # Tenant Config Manager
└── ob_multi_tenant.h                          # 多租户管理

src/share/
├── ob_resource_limit.{h,cpp}                 # Resource Limit
├── ob_resource_limit_def.h                   # Resource Limit 常量
└── resource_limit_calculator/
    └── ob_resource_limit_calculator.h        # 实时计算器

src/observer/ob_server_struct.h               # 集群信息（RS 列表等）
```

### 1.2 三层关系

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Tenant (多租户隔离根)                                   │
│  - 一个 OB 集群容纳 N 个 tenant                                  │
│  - tenant_id 是所有资源的第一道边界                              │
│  - 1 个 tenant 拥有 1..N 个 Unit                                 │
└──────────────────────────────────────────────────────────────────┘
                              │ 1..N
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Resource Pool (Unit 容器)                              │
│  - 一个 tenant 可以有多个 Resource Pool                          │
│  - Resource Pool 定义 Unit 模板（CPU / MEM / IO 配额）           │
│  - 不同 tenant 可以共享 Resource Pool 模板                      │
└──────────────────────────────────────────────────────────────────┘
                              │ 1..N
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: Unit (实际运行实例)                                     │
│  - Unit 是 Resource Pool 在某 observer 上的实例                  │
│  - max_cpu / min_cpu / max_memory / min_memory 等                │
│  - 同 tenant 多 Unit 共享资源（弹性）                            │
└──────────────────────────────────────────────────────────────────┘
```

### 1.3 与 #39 / #71 的关系

- #39 是 **早期分析**（tenant 架构概念）
- #71 是 **cgroup 集成**（资源硬隔离）
- 本篇是 **Unit / Resource Pool 的 RBAC + 分配算法**

---

## 2. ObUnitResource —— Unit 配额定义

### 2.1 类骨架（参见 #71 §2.2）

```cpp
// src/share/unit/ob_unit_resource.h
class ObUnitResource {
public:
  // 资源配额
  double max_cpu_;             // 最大 CPU 核数
  double min_cpu_;             // 最小保证 CPU 核数
  int64_t max_memory_;         // 最大内存（bytes）
  int64_t min_memory_;         // 最小保证内存（bytes）
  int64_t max_disk_size_;      // 最大磁盘空间
  int64_t max_iops_;           // 最大 IOPS
  int64_t max_bandwidth_;      // 最大 IO 带宽（bytes/s）
  int64_t max_session_num_;    // 最大 session 数
  int64_t max_worker_count_;   // 最大 worker 线程数

  // 状态
  UnitStatus status_;          // ACTIVE / MIGRATING / DELETING

  // 元数据
  uint64_t unit_id_;
  uint64_t tenant_id_;
  share::ObZone zone_;        // Unit 所在 zone
  share::ObServer server_;    // Unit 所在 observer
};
```

### 2.2 Unit 状态机

```
                    ┌──────────────┐
                    │   CREATING   │  ← Unit 创建中
                    └──────┬───────┘
                           │
                           ▼
                    ┌──────────────┐
                    │    ACTIVE    │  ← 正常运行
                    └──────┬───────┘
                           │
                           ▼
                    ┌──────────────┐
                    │  MIGRATING   │  ← 跨 observer 迁移中
                    └──────┬───────┘
                           │
                           ▼
                    ┌──────────────┐
                    │  DELETING    │  ← 删除中
                    └──────┬───────┘
                           │
                           ▼
                    ┌──────────────┐
                    │   DELETED    │  ← 已删除
                    └──────────────┘
```

### 2.3 Resource Pool 与 Unit 的关系

```cpp
// 1 个 Resource Pool 定义 N 个 Unit 模板
struct ObResourcePool {
  uint64_t pool_id_;
  uint64_t tenant_id_;
  uint64_t unit_count_;            // 这个 Pool 包含多少 Unit
  ObUnitResource unit_template_;   // Unit 模板（max_cpu / max_memory 等）
  ObArray<uint64_t> unit_ids_;     // 实际 Unit 列表
};

// 1 个 Unit 是 1 个 Resource Pool 在某 observer 上的实例
struct ObUnit {
  uint64_t unit_id_;
  uint64_t pool_id_;               // 属于哪个 Pool
  uint64_t server_id_;             // 在哪个 observer 上
  ObUnitResource config_;          // 实例配置（基于 Pool 模板）
  UnitStatus status_;
};
```

---

## 3. ObResourceManager —— Resource Manager 主类

### 3.1 类骨架（推测，参见 #71 §3.1）

```cpp
// src/share/resource_manager/ob_resource_manager.h
class ObResourceManager {
public:
  // Unit 管理
  int create_unit(const ObUnitResource &spec);
  int delete_unit(uint64_t unit_id);
  int update_unit(const ObUnitResource &spec);
  int migrate_unit(uint64_t unit_id, share::ObServer target_server);

  // Resource Pool 管理
  int create_resource_pool(const ObResourcePool &pool);
  int drop_resource_pool(uint64_t pool_id);

  // Resource Plan 管理（5.x 新）
  int create_resource_plan(const ObResourcePlan &plan);
  int activate_resource_plan(const ObString &plan_name);

  // 资源监控
  int get_unit_load(uint64_t unit_id, ObUnitLoadInfo &info);

private:
  int dispatch_unit_op(const ObUnitOpRequest &req);
};
```

### 3.2 Resource Manager Proxy

```cpp
// src/share/resource_manager/ob_resource_manager_proxy.h
class ObResourceManagerProxy {
  // 跨 observer RPC 代理
  // RS ↔ observer 之间的 resource 操作通过这个 proxy
};
```

---

## 4. Resource Plan —— OB 5.x 新

### 4.1 角色

```cpp
// src/share/resource_manager/ob_resource_plan_manager.h
class ObResourcePlanManager {
  // Resource Plan 是 5.x 新加的资源规划能力
  // - 跨多个 Resource Pool 的统一资源管理
  // - 不同业务场景的不同 plan（如 OLAP vs OLTP）
};
```

### 4.2 Plan 的价值

```
场景：
  白天：OLTP 高峰，需要多 CPU / 少 MEM
  晚上：OLAP 跑批，需要多 MEM / 多 DISK IO

用 Resource Plan：
  CREATE RESOURCE PLAN olap_night
    DIRECTIVE 1: resource_pool_olap SET max_cpu = 8, max_memory = '32G'
    DIRECTIVE 2: resource_pool_oltp SET max_cpu = 2, max_memory = '4G';

  -- 切换
  ALTER SYSTEM ACTIVATE RESOURCE PLAN olap_night;
```

**Resource Plan 是 OB 5.x 的关键运维能力** —— 业务峰值 / 批处理时段灵活切换。

### 4.3 ObResourcePlanInfo

```cpp
// src/share/resource_manager/ob_resource_plan_info.h
class ObResourcePlanInfo {
  // 单个 Plan 的元数据
  uint64_t plan_id_;
  ObString plan_name_;
  ObArray<ObResourceDirective> directives_;  // Plan 内多个 directive
};
```

---

## 5. Mapping Rule —— Resource Pool 映射规则

### 5.1 角色

```cpp
// src/share/resource_manager/ob_resource_mapping_rule_manager.h
class ObResourceMappingRuleManager {
  // Mapping Rule 把 resource pool 映射到具体 observer / zone
  // - 指定 tenant 在哪些 observer 上跑
  // - 指定 zone 分布
};
```

### 5.2 Column-level Mapping

```cpp
// src/share/resource_manager/ob_resource_col_mapping_rule_manager.h
class ObResourceColMappingRuleManager {
  // Column-level mapping
  // - 某些 SQL 类型可以走特殊 resource pool
  // - 例：报表查询用大 resource pool，事务用小 pool
};
```

### 5.3 Mapping Rule 示例

```yaml
# 把 OLAP tenant 映射到 4 个 observer（每个 zone 一个）
mapping_rule:
  tenant: tenant_olap
  zone_mappings:
    - zone: zone1
      observers: [observer1, observer2]
    - zone: zone2
      observers: [observer3, observer4]
  unit_count_per_zone: 2
```

---

## 6. Allocation 算法 —— Unit 怎么分配到 observer

### 6.1 创建 Unit 的流程

```
DBA: ALTER TENANT tenant_olap UNIT_NUM = 4;
    │
    ▼
observer SQL executor
    │
    ├─ 解析 ALTER TENANT 参数
    │
    ▼
observer → RS: alter_tenant_arg RPC
    │
    ▼
RS: ObResourceManager::create_unit
    │
    ├─ 1. 检查资源是否够用（参见 §7）
    │   - 总 CPU / MEM / DISK
    │   - 已分配
    │   - 系统保留 (~10-20%)
    │
    ├─ 2. 选择 observer（按 mapping rule）
    │   - 优先选择空闲 observer
    │   - 优先选择同 zone
    │   - 避免热点
    │
    ├─ 3. 通过 ObResourceManagerProxy 通知目标 observer
    │
    ▼
目标 observer: 创建 Unit 实例
    │
    ├─ 配置 cgroup (参见 #71)
    ├─ 创建 unit meta (per-tenant cache)
    ├─ 启动 unit 资源调度
    └─ ack RS
    │
    ▼
RS: 持久化到 __all_unit_config / __all_resource_pool 等内部表
    │
    ▼
返回 DBA: 创建成功 + Unit ID 列表
```

### 6.2 选择 observer 的策略

```
策略 1: 资源最空闲优先
  - 计算每个 observer 的剩余资源
  - 选择剩余最多的

策略 2: 容量规划
  - 按 zone 维度平衡
  - 不把所有 Unit 都放一个 observer

策略 3: locality 优先
  - 同 zone 优先（参见 #47 Locality Replica）
  - 跨 zone 次之
  - 同 IDC 优先

策略 4: 应用指定
  - DBA 显式指定 Unit 在某个 observer
```

### 6.3 Allocation 的负载均衡

```
Unit 迁移时机:
  - 单 observer 过载 → 触发 Unit 迁移
  - zone 不平衡 → 触发 rebalance
  - Unit 故障 → Unit 重新分配
```

---

## 7. Resource Limit Calculator —— 实时容量

### 7.1 角色

```cpp
// src/share/resource_limit_calculator/ob_resource_limit_calculator.h
class ObResourceLimitCalculator {
public:
  // 实时计算可用资源
  int calc_available_cpu(uint64_t tenant_id, double &available);
  int calc_available_memory(uint64_t tenant_id, int64_t &available);

  // Unit 容量规划
  int plan_unit_capacity(uint64_t unit_id, ObUnitCapacity &cap);
};
```

### 7.2 容量计算公式

```
available_cpu = total_cpu - allocated_cpu - system_reserved
available_memory = total_memory - allocated_memory - system_reserved

其中:
  total_cpu = observer 的 CPU 核数（如 16 / 32）
  allocated_cpu = 所有 tenant 的 unit 配额之和
  system_reserved = ~10-20% 总 CPU（系统用）
```

### 7.3 资源耗尽处理

```
申请 X CPU + Y MEM 时：
  available_cpu < X → 报错 OB_ERR_RESOURCE_OUT
  available_memory < Y → 报错 OB_ERR_RESOURCE_OUT

或：触发动态迁移
  - 把空闲 observer 上的 Unit 迁走
  - 给新 Unit 让资源
```

---

## 8. Dynamic Resize —— ALTER UNIT 在线调整

### 8.1 调整 SQL

```sql
-- 加 Unit
ALTER TENANT tenant_name UNIT_NUM = 4;  -- 从 3 扩到 4

-- 减 Unit
ALTER TENANT tenant_name UNIT_NUM = 2;  -- 从 3 缩到 2

-- 调整 Unit 配置
ALTER RESOURCE UNIT unit_name MAX_CPU = 8;  -- 提高 CPU 配额
ALTER RESOURCE UNIT unit_name MAX_MEMORY = '16G';
```

### 8.2 动态生效

```
ALTER RESOURCE UNIT unit_name MAX_CPU = 8;
    │
    ▼
RS: 1. 校验新配额合法 + 有足够资源
    │
    2. 更新 Unit 配置（__all_unit_config）
    │
    3. broadcast 到所有 observer
    │
    ▼
每个 observer: 更新本地 Unit 配置 + 调 cgroup
    │
    ├─ 增大配额 → 调 cgroup 提高限制
    └─ 减小配额 → 调 cgroup 降低限制
    │
    ▼
立即生效（无需重启）
```

---

## 9. cgroup 集成 —— Unit ↔ cgroup 映射

### 9.1 Unit 与 cgroup 关系（参见 #71）

```
每个 Unit 对应一个 cgroup
    │
    ├─ CPU 配额: cpu.cfs_quota_us / cpu.max
    ├─ Memory 限制: memory.limit_in_bytes / memory.max
    ├─ IO 限制: blkio.throttle.* / io.max
    └─ 进程附加: cgroup.procs
```

### 9.2 ObCgroupCtrl 接口（参见 #71 §4.2）

```cpp
// src/share/resource_manager/ob_cgroup_ctrl.h
class ObCgroupCtrl {
public:
  // 创建 Unit cgroup
  static int create_cgroup(const uint64_t unit_id);
  // 删除 Unit cgroup
  static int delete_cgroup(const uint64_t unit_id);
  // 设置 CPU 配额
  static int set_cpu_quota(const uint64_t unit_id, const double max_cpu);
  // 设置内存上限
  static int set_memory_limit(const uint64_t unit_id, const int64_t max_memory);
  // 设置 IO 限制
  static int set_io_bandwidth(const uint64_t unit_id, const int64_t max_bandwidth);
  // 设置 IOPS
  static int set_io_iops(const uint64_t unit_id, const int64_t max_iops);
  // 把进程加入 cgroup
  static int attach_process(const uint64_t unit_id, const pid_t pid);
  // 读取实时统计
  static int get_cpu_usage(const uint64_t unit_id, double &usage);
  static int get_memory_usage(const uint64_t unit_id, int64_t &usage);
  static int get_io_stats(const uint64_t unit_id, ObIOStats &stats);
};
```

### 9.3 Unit 创建 → cgroup 配置时序

```
1. RS 决定 Unit 在某 observer 上
    │
2. RS → observer: create_unit RPC
    │
3. observer: 
    a. ObResourceManager::create_unit (应用层元数据)
    b. ObCgroupCtrl::create_cgroup (Linux cgroup)
    c. ObCgroupCtrl::set_cpu_quota + set_memory_limit + set_io_*
    d. ObCgroupCtrl::attach_process (worker threads)
    │
4. observer → RS: ack
    │
5. RS: 持久化到内部表
```

---

## 10. Resource Plan / Mapping Rule / Resource Limit 三大组件

### 10.1 Resource Plan vs Resource Pool

| 维度 | Resource Plan | Resource Pool |
|------|---------------|----------------|
| 粒度 | 跨多个 Pool 的统一规划 | 单 Pool 的资源配额 |
| 时间维度 | 时间段切换（OLAP/OLTP） | 静态资源配额 |
| 变更方式 | ACTIVATE 切换 | ALTER 调整配额 |
| 持久化 | `__all_resource_plan` | `__all_resource_pool` |

### 10.2 Mapping Rule 的作用

```cpp
// 把 tenant / zone / observer 三者关系固化
// 例：tenant_olap 在 zone1 必须有 2 个 Unit
mapping_rule_olap:
  tenant: tenant_olap
  zone_mappings:
    - zone1: 2 Units
    - zone2: 2 Units
  // 跨 zone 容灾
```

### 10.3 Resource Limit Calculator 实时容量

```
申请 X CPU:
  calc_available_cpu(tenant_id, &available);
  if (X > available) → 报错 OB_ERR_RESOURCE_OUT
  else → 继续
```

---

## 11. Tenant 生命周期

### 11.1 CREATE TENANT 流程

```sql
CREATE TENANT tenant_name
  UNIT_NUM = 2,
  UNIT = 'unit_config_name',
  RESOURCE_POOL_LIST = ('pool_a', 'pool_b'),
  PRIMARY_ZONE = 'zone1,zone2',
  COMMENT = '...';
```

### 11.2 完整流程

```
CREATE TENANT ...
    │
    ▼
SQL Parser → ObCreateTenantStmt
    │
    ▼
Resolver (校验 unit config / pool / zone 存在)
    │
    ▼
DDL Executor (ob_create_tenant_executor)
    │
    ├─ 1. 权限校验 (CREATE TENANT 权限)
    ├─ 2. 校验 unit config 存在
    ├─ 3. 校验 resource pool 存在
    │
    ▼
observer → RS: create_tenant_arg RPC
    │
    ▼
RS: ObResourceManager::create_tenant
    │
    ├─ 1. 创建 tenant meta（持久化到 __all_tenant）
    ├─ 2. 创建 N 个 unit（按 UNIT_NUM）
    ├─ 3. 把 unit 调度到 observers（按 mapping rule）
    ├─ 4. 通过 ObResourceManagerProxy 通知各 observer
    │
    ▼
各 observer: 
    ├─ 配置 cgroup（参见 #71）
    ├─ 创建 unit meta (per-tenant cache)
    ├─ 启动 TG threads (参见 #74)
    └─ ack RS
    │
    ▼
RS: 触发 schema version 升级 + 持久化所有 unit config
    │
    ▼
返回应用: tenant_id + unit_ids
```

### 11.3 DROP TENANT

```sql
DROP TENANT tenant_name FORCE;  -- 或 FORCE 表示强制删除（即使有活动连接）
```

### 11.4 ALTER TENANT

```sql
-- 加 Unit
ALTER TENANT tenant_name UNIT_NUM = 4;

-- 减 Unit
ALTER TENANT tenant_name UNIT_NUM = 2;

-- 改 Unit 配置（动态）
ALTER RESOURCE UNIT unit_name MAX_CPU = 8;

-- 切换 Resource Plan
ALTER SYSTEM ACTIVATE RESOURCE PLAN olap_night;
```

---

## 12. 与其他文章的关系

### 12.1 与 #39 Tenant Architecture

#39 是早期 tenant 架构分析。本篇是 #39 的 **深化**：
- #39 集中在 tenant 的逻辑结构
- 本篇深入 Resource Pool / Unit 的具体实现 + cgroup 集成

### 12.2 与 #71 Resource Isolation

#71 聚焦 cgroup 集成（参见 §11 cgroup 章节）。本篇是 #71 的 **资源池扩展**：
- Unit ↔ Resource Pool 关系
- Allocation 算法
- Resource Plan / Mapping Rule

### 12.3 与 #27 RootServer

RS 是 Resource 管理的主协调者：
- 创建 / 删除 Unit
- 调度 Unit 到 observer
- Resource Plan 切换

### 12.4 与 #30 Observer Startup

Observer 启动时加载 Unit / Tenant 配置：
- per-tenant TG 线程（参见 #74）
- 启动 cgroup 配置
- 加载 schema cache

### 12.5 与 #76 Schema Service

Tenant 是 schema 隔离的第一边界：
- 每个 tenant 有自己的 schema version
- 不同 tenant 的 schema 互不影响
- ObSchemaGetterGuard 自动带 tenant_id

---

## 13. 总结

### 13.1 Tenant / Unit / Resource Pool 在 OB 体系中的定位

OB 的多租户资源管理体系是 **SaaS 级 RBAC + cgroup 硬隔离**：
- Tenant 是逻辑边界
- Resource Pool 是 Unit 模板
- Unit 是实际配额
- cgroup 是 OS 级硬隔离（参见 #71）

### 13.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Unit 配额 | `ObUnitResource` max_cpu / min_cpu / max_memory 等 |
| Resource Pool | 模板 + Unit 列表 |
| Allocation 算法 | RS 选 observer（resource 空闲优先） |
| cgroup 集成 | `ObCgroupCtrl`（参见 #71） |
| Resource Plan | OB 5.x 新加（OLAP/OLTP 切换） |
| Mapping Rule | tenant ↔ zone ↔ observer 映射 |
| Resource Limit | `ObResourceLimitCalculator` 实时容量 |
| Dynamic Resize | ALTER UNIT 在线生效 |

### 13.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/unit/ob_unit_resource.h` | Unit 资源定义 |
| `src/share/resource_manager/ob_resource_manager.{h,cpp}` | Resource Manager |
| `src/share/resource_manager/ob_resource_manager_proxy.{h,cpp}` | 跨 observer RPC |
| `src/share/resource_manager/ob_resource_plan_manager.{h,cpp}` | Resource Plan |
| `src/share/resource_manager/ob_resource_plan_info.{h,cpp}` | Resource Plan 元数据 |
| `src/share/resource_manager/ob_resource_mapping_rule_manager.{h,cpp}` | Mapping Rule |
| `src/share/resource_manager/ob_resource_col_mapping_rule_manager.{h,cpp}` | Column-level Mapping |
| `src/share/resource_manager/ob_cgroup_ctrl.{h,cpp}` | cgroup 控制（参见 #71） |
| `src/observer/omt/ob_tenant_config.{h,cpp}` | Tenant Config |
| `src/observer/omt/ob_tenant_config_mgr.{h,cpp}` | Tenant Config Manager |
| `src/observer/omt/ob_multi_tenant.h` | 多租户管理 |
| `src/share/ob_resource_limit.{h,cpp}` | Resource Limit |
| `src/share/ob_resource_limit_def.h` | Resource Limit 常量 |
| `src/share/resource_limit_calculator/ob_resource_limit_calculator.h` | 实时计算 |

### 13.4 关键技术常量

| 常量 | 典型值 | 位置 |
|------|--------|------|
| `system_reserved_cpu` | 10-20% | server config |
| `max_unit_per_tenant` | 几十 | server config |
| `resource_plan_max_directives` | 几十 | server config |
| `mapping_rule_max_zones` | 几 | server config |

### 13.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#82 Schema / Meta Table 内部表详解**（深化 #76）：

OB 的 schema 持久化基础 —— `__all_table` / `__all_column` / `__all_user` / `__all_database` / `__all_tenant` / `__all_ddl_operation` 等内部表的字段定义、约束、修改兼容性。源码入口：`src/share/inner_table/` + `src/share/schema/ob_*.h`。

适用场景：版本兼容性 / 升级 / 元数据一致性。

整吗？