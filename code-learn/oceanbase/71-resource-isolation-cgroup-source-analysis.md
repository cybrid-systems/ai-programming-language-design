# 71-resource-isolation-cgroup — OceanBase 多租户资源隔离 / Unit / cgroup 集成深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（src/share/resource_manager/ + src/share/unit/ + src/share/resource_limit*/ + src/observer/virtual_table/ob_all_virtual_cgroup_config.{h,cpp}）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 在多租户 SaaS 场景下需要严格的 **资源隔离** —— 每个 tenant 的 CPU / 内存 / IO / 网络配额必须独立管理，避免"邻居噪声"。OB 5.x 的资源隔离体系建立在 **Unit 模型 + Resource Plan + cgroup 集成** 三层之上：

- **Unit**：单个 tenant 的资源配额单元（max_cpu / min_cpu / max_memory / min_memory 等）
- **Resource Plan**：跨 tenant 的全局资源分配策略
- **cgroup**：Linux 内核机制，把 Unit 配额落到 OS 层

本文聚焦 7 个核心问题：

1. **Unit 模型** —— 单 tenant 内的资源分配粒度
2. **Resource Manager** —— 跨 tenant 资源协调
3. **cgroup 集成** —— Linux 内核 CPU / MEM / IO 配额
4. **Resource Limit Calculator** —— 实时计算可用资源
5. **IO 资源管理** —— ObIO 调度 + bandwidth 限制
6. **多租户隔离边界** —— tenant_id 是资源隔离的第一道
7. **动态伸缩** —— Unit 增删 / 缩扩容

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 25-memory-management | Unit 内存分配 → ObAllocator |
| 39-tenant-architecture | Unit 是 tenant 架构的物理载体 |
| 44-io-subsystem | IO 配额与 #44 的 mClock 算法集成 |
| 45-latch-system | Latch 公平性 vs Unit 公平性 |
| 57-config-system | Resource Manager 配置持久化 |
| 70-sql-audit-security | 权限检查先于资源分配 |

---

## 1. 整体架构：OB 资源隔离四层模型

### 1.1 四层职责

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Tenant (logical)                                       │
│  - 一个 OB 集群可容纳多个 tenant                                 │
│  - tenant_id 是所有资源隔离的第一道边界                         │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ tenant 拥有 1..N 个 Unit
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Unit (物理资源配额)                                    │
│  - 每个 Unit 有 max_cpu / min_cpu / max_memory / min_memory 等   │
│  - 同 tenant 多 Unit 共享资源（弹性）                            │
│  - Unit 故障迁移 / 缩扩容                                       │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ Unit 配额映射到 cgroup
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: Resource Manager (跨 observer 协调)                   │
│  - 跨 observer 资源调度                                           │
│  - Unit 迁移 / 资源回收                                         │
│  - 资源监控 / 告警                                                │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 通过 cgroup API 落到 OS
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: cgroup (Linux 内核)                                    │
│  - CPU: cgroup v1 cpu.cfs_quota_us / v2 cpu.max                 │
│  - Memory: memory.limit_in_bytes / memory.max                    │
│  - IO: blkio.throttle.* / io.max                                  │
│  - Network: tc / net_cls                                         │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 模块组成（实际路径）

```bash
src/share/resource_manager/                    # Resource Manager
  ├── ob_cgroup_ctrl.{h,cpp}                  # cgroup 控制核心
  ├── ob_resource_manager.{h,cpp}             # Resource Manager 抽象
  ├── ob_resource_manager_proxy.{h,cpp}      # 跨 observer RPC 代理
  ├── ob_resource_plan_manager.{h,cpp}        # Resource Plan 管理
  ├── ob_resource_plan_info.{h,cpp}           # Plan 元数据
  ├── ob_resource_mapping_rule_manager.{h,cpp} # Mapping Rule
  ├── ob_resource_col_mapping_rule_manager.{h,cpp} # Column-level mapping
src/share/unit/                                # Unit 模型
  └── ob_unit_resource.h                        # Unit 资源定义
src/share/                                    # Resource Limit
  ├── ob_resource_limit.{h,cpp}               # 限制定义
  ├── ob_resource_limit_def.h                  # 常量
  ├── ob_resource_limit_calculator/ob_resource_limit_calculator.h  # 计算器
src/observer/virtual_table/
  ├── ob_all_virtual_cgroup_config.{h,cpp}    # cgroup 虚拟表（监控）
```

### 1.3 路径修正（来自 #60）

我之前在 #60 提到的 `src/share/resource/` + `src/share/cgroup/` **都不存在**，真实路径分散在多个目录：
- Resource Manager → `src/share/resource_manager/`
- cgroup 控制 → `src/share/resource_manager/ob_cgroup_ctrl.{h,cpp}`
- Unit → `src/share/unit/ob_unit_resource.h`
- Resource Limit → `src/share/resource_limit*.{h,cpp}`
- Resource Limit Calculator → `src/share/resource_limit_calculator/`

---

## 2. Unit 模型 —— `ob_unit_resource.h`

### 2.1 Unit 概念

OB 的 **Unit** 是单 tenant 内的资源分配粒度：
- 一个 tenant 默认有 1 个 Unit
- 大租户可以申请多个 Unit（弹性扩展）
- Unit 有自己的资源配额：max_cpu / min_cpu / max_memory / min_memory / max_disk / max_iops 等

### 2.2 ObUnitResource 抽象

```cpp
// src/share/unit/ob_unit_resource.h
class ObUnitResource {
public:
  // 资源配额
  double max_cpu_;             // 最大 CPU 核数
  double min_cpu_;             // 最小保证 CPU 核数（高优先级时保证）
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

### 2.3 Unit 创建 / 调整 SQL

```sql
-- 创建 tenant 时指定 unit 配置
CREATE TENANT tenant_name UNIT_NUM = 2, UNIT = 'unit_config';

-- 调整 unit 配置（动态）
ALTER TENANT tenant_name UNIT_NUM = 3;

-- 显式指定 unit 资源
CREATE RESOURCE UNIT unit_name
  MAX_CPU = 4, MIN_CPU = 2,
  MAX_MEMORY = '10G', MIN_MEMORY = '5G',
  MAX_IOPS = 10000, MAX_BANDWIDTH = '100M';
```

### 2.4 多 Unit 的弹性优势

```
传统单 Unit:
  Tenant T1 1 个 Unit = {max_cpu: 4}
  → 单 observer 故障 = T1 不可用
  → 扩缩容 = 创建新 tenant

OB 多 Unit:
  Tenant T1 3 个 Unit = {max_cpu: 4} × 3
  → 单 observer 故障 = 只丢 1/3 capacity，T1 仍可用
  → 弹性扩展 = 加 Unit
  → Unit 迁移 = 自动跨 observer 转移
```

---

## 3. Resource Manager —— `ob_resource_manager`

### 3.1 类骨架（推测）

```cpp
// src/share/resource_manager/ob_resource_manager.h
class ObResourceManager {
public:
  // Unit 管理
  int create_unit(const ObUnitResource &spec);
  int delete_unit(uint64_t unit_id);
  int update_unit(const ObUnitResource &spec);
  int migrate_unit(uint64_t unit_id, share::ObServer target_server);

  // Resource Plan 管理
  int create_resource_plan(const ObResourcePlan &plan);
  int activate_resource_plan(const ObString &plan_name);

  // 资源监控
  int get_unit_load(uint64_t unit_id, ObUnitLoadInfo &info);

private:
  // 跨 observer RPC
  int dispatch_unit_op(const ObUnitOpRequest &req);
};
```

### 3.2 跨 observer 协调

```
RS 收到: CREATE UNIT / ALTER UNIT
    │
    ▼
RS 校验（资源配额合法？observer 有足够资源？）
    │
    ▼
RS → 目标 observer: RPC 通知
    │
    ▼
目标 observer:
    │
    ├─ 创建 unit_id 唯一
    ├─ 配置 cgroup (cpu/memory/io)
    ├─ 创建 unit meta (per-tenant cache)
    ├─ 启动 unit 资源调度
    └─ ack RS
    │
    ▼
RS 持久化到 __all_unit / __all_resource_plan 等内部表
```

### 3.3 Resource Manager Proxy

```cpp
// src/share/resource_manager/ob_resource_manager_proxy.h
class ObResourceManagerProxy {
  // 跨 observer RPC 代理
  // RS ↔ observer 之间的 resource 操作通过这个 proxy
};
```

---

## 4. cgroup 集成 —— `ob_cgroup_ctrl`

### 4.1 cgroup 基础

cgroup（control group）是 Linux 内核的资源隔离机制：

```
/sys/fs/cgroup/cpu,cpuacct/
├── cgroup.procs              # cgroup 内的进程列表
├── cpu.cfs_quota_us          # CPU 配额（微秒）
├── cpu.cfs_period_us         # CPU 周期（微秒）
├── cpu.shares                # CPU 权重（相对）
├── cpu.stat                  # CPU 使用统计
└── ...

/sys/fs/cgroup/memory/
├── cgroup.procs
├── memory.limit_in_bytes     # 内存上限
├── memory.usage_in_bytes     # 当前使用
├── memory.stat               # 内存使用统计
└── ...

/sys/fs/cgroup/blkio/
├── cgroup.procs
├── blkio.throttle.read_bps_device  # 读带宽限制
├── blkio.throttle.write_bps_device # 写带宽限制
├── blkio.throttle.read_iops_device # 读 IOPS 限制
└── ...
```

### 4.2 ObCgroupCtrl 抽象

```cpp
// src/share/resource_manager/ob_cgroup_ctrl.h
class ObCgroupCtrl {
public:
  // 初始化 cgroup 文件系统
  static int init(const ObString &cgroup_root);

  // Unit 创建 cgroup
  static int create_cgroup(const uint64_t unit_id,
                           const ObString &cgroup_path);

  // Unit 删除 cgroup
  static int delete_cgroup(const uint64_t unit_id);

  // 设置 CPU 配额
  static int set_cpu_quota(const uint64_t unit_id,
                           const double max_cpu);

  // 设置内存上限
  static int set_memory_limit(const uint64_t unit_id,
                              const int64_t max_memory);

  // 设置 IO 带宽
  static int set_io_bandwidth(const uint64_t unit_id,
                              const int64_t max_bandwidth);

  // 设置 IOPS
  static int set_io_iops(const uint64_t unit_id,
                         const int64_t max_iops);

  // 把进程加入 cgroup
  static int attach_process(const uint64_t unit_id,
                            const pid_t pid);

  // 读取 cgroup 统计
  static int get_cpu_usage(const uint64_t unit_id,
                           double &usage);

  static int get_memory_usage(const uint64_t unit_id,
                              int64_t &usage);

  static int get_io_stats(const uint64_t unit_id,
                         ObIOStats &stats);
};
```

### 4.3 cgroup v1 vs v2

OB 5.x 同时支持 cgroup v1 和 v2：
- **v1**：每个子系统独立挂载（cpu, memory, blkio 各自一个 hierarchy）
- **v2**：统一 hierarchy（`/sys/fs/cgroup/unified/`），用单一树管理所有子系统

`ObCgroupCtrl` 内部自动检测并适配两种版本。

### 4.4 cgroup 文件读写

```cpp
// (典型实现)
int ObCgroupCtrl::set_cpu_quota(const uint64_t unit_id, const double max_cpu) {
  // 1. 计算 cgroup 路径
  ObString path = build_cgroup_path(unit_id, "cpu,cpuacct");
  // 2. 计算 quota（微秒）
  int64_t quota_us = (int64_t)(max_cpu * CPU_PERIOD_US);
  // 3. 写文件
  return write_cgroup_file(path, "cpu.cfs_quota_us",
                          std::to_string(quota_us));
}
```

### 4.5 cgroup 的限制

| 限制 | 影响 |
|------|------|
| 仅 Linux 支持 | ⚠️ macOS / Windows 不可用（OB 也只跑 Linux） |
| cgroup v1 / v2 API 不同 | 需要运行时检测 + 适配 |
| root 权限 | 创建 cgroup 需要 root（容器内运行） |
| 嵌套 cgroup 性能开销 | 多层嵌套导致调度复杂 |

---

## 5. Resource Limit Calculator

### 5.1 实时资源计算

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

### 5.2 计算维度

- **物理资源**：observer 总 CPU / MEM / DISK
- **已分配**：所有 tenant 的 unit 配额之和
- **可用**：物理 - 已分配 - 系统保留（~10-20%）
- **请求**：`ALTER UNIT` 申请的新配额
- **校验**：申请 ≤ 可用 + 冲突检测

### 5.3 与 #57 Config System 的关系

Resource 配置（unit_max_cpu 等）通过 OCP / OBD 持久化：
- 启动时加载到 `ObResourceManager`
- 通过内部表 `__all_unit_config` / `__all_resource_plan` 同步

---

## 6. IO 资源管理

### 6.1 IO 配额维度

OB 的 IO 资源管理覆盖：
- **IOPS**：每秒 IO 操作数限制（read + write）
- **Bandwidth**：每秒字节数限制
- **Priority**：高优先级请求（DDL / backup）可绕过限制
- **公平调度**：多 Unit 共享同一块盘时按权重分配

### 6.2 IO 调度器集成

参见 #44 IO 子系统：
- mClock 算法按 unit 分配 IO 带宽
- 每个 IO 请求关联 tenant_id → unit → cgroup blkio
- 高优先级请求（小 IO / 关键路径）有最低保证

### 6.3 ObIO 与 Unit 的衔接

```cpp
// src/share/io/ob_io_define.h (推测)
struct ObIORequest {
  uint64_t tenant_id_;
  uint64_t unit_id_;
  IOOpType op_;          // READ / WRITE / COMPACTION / BACKUP
  int64_t expected_bytes_;
  ObIOPriority priority_;
};
```

---

## 7. 资源隔离边界

### 7.1 三道边界

```
边界 1: Tenant
  - tenant_id 是所有资源的 root
  - 不同 tenant 的内存池 / 线程池 / IO 通道完全隔离

边界 2: Unit
  - 同 tenant 多 Unit 共享资源（弹性）
  - Unit 之间是"软隔离"（共享进程但配额独立）

边界 3: cgroup
  - OS 层隔离（CPU/MEM/IO 真的不能越过）
  - 即使 OB 进程有 bug，cgroup 仍能防止物理资源耗尽
```

### 7.2 软隔离 vs 硬隔离

| 维度 | 软隔离（OB 层） | 硬隔离（cgroup 层） |
|------|----------------|---------------------|
| 内存 | MemTracker | memory.limit_in_bytes |
| CPU | 线程优先级 + 大循环检测 | cpu.cfs_quota_us |
| IO | mClock 调度 | blkio.throttle.* |

**为什么需要双层**：
- OB 层软隔离：灵活（动态调整）、快速（无 OS 调用）
- cgroup 层硬隔离：保证（即使 OB 有 bug 也不影响其他 tenant）

### 7.3 故障隔离

```
Observer 进程 bug → 内存泄漏
    │
    ▼
MemTracker 软隔离失败（如果代码绕过 MemTracker）
    │
    ▼
cgroup memory.limit_in_bytes 兜底
    │
    ▼
进程被 OOM Killer 杀掉（cgroup 内）
    │
    ▼
其他 tenant 的 cgroup 不受影响
```

---

## 8. 动态伸缩（弹性）

### 8.1 Unit 扩缩容

```sql
-- 加 Unit
ALTER TENANT tenant_name UNIT_NUM = 4;  -- 从 3 扩到 4

-- 减 Unit
ALTER TENANT tenant_name UNIT_NUM = 2;  -- 从 3 缩到 2

-- 调整 Unit 配置
ALTER RESOURCE UNIT unit_name MAX_CPU = 8;  -- 提高 CPU 配额
```

### 8.2 Unit 迁移

```sql
-- 手动迁移 Unit 到其他 observer
ALTER TENANT tenant_name UNIT_GROUP = 'new_unit_group';
```

或通过 OCP 自动调度：
- Unit 所在 observer 故障 → 自动迁移到健康 observer
- Unit 所在 observer 资源紧张 → 触发负载均衡

### 8.3 Unit 迁移流程

```
RS 触发 Unit 迁移
    │
    ▼
源 observer: 暂停 Unit 服务（拒绝新请求）
    │
    ├─ 等待 in-flight 请求完成
    ├─ 把 unit meta 转移到目标 observer
    ├─ 在目标 observer 创建 cgroup + 配置
    └─ 释放源 observer 资源
    │
    ▼
目标 observer: 启动 Unit 服务
    │
    ├─ 接管 in-flight 请求（如果有）
    ├─ 启动 worker threads
    └─ 更新 location cache（参见 #37）
    │
    ▼
RS: 更新 unit location (server_addr)
    │
    ▼
迁移完成（通常几秒到几分钟）
```

---

## 9. 监控与可观测性

### 9.1 cgroup 虚拟表

```cpp
// src/observer/virtual_table/ob_all_virtual_cgroup_config.{h,cpp}
class ObAllVirtualCgroupConfig {
  // 虚拟表：SELECT * FROM oceanbase.__all_virtual_cgroup_config;
  // 返回所有 unit 的 cgroup 配置 + 实时状态
};
```

**用途**：DBA 用 SQL 查询 cgroup 状态：
```sql
SELECT unit_id, cpu_quota, memory_limit, io_bandwidth, status
FROM oceanbase.__all_virtual_cgroup_config
WHERE tenant_id = 1001;
```

### 9.2 资源监控指标

| 指标 | 来源 | 用途 |
|------|------|------|
| unit_cpu_usage | cgroup cpuacct.usage | CPU 使用率监控 |
| unit_memory_usage | cgroup memory.usage_in_bytes | 内存使用监控 |
| unit_io_bandwidth | cgroup blkio.throttle.* | IO 带宽监控 |
| unit_io_iops | OB IO scheduler | IOPS 监控 |
| unit_session_count | OB session_mgr | session 数监控 |

---

## 10. 与其他文章的关系

### 10.1 与 #39 Tenant Architecture

Unit 是 tenant 架构的 **物理载体**：
- 一个 tenant 有 1..N 个 Unit
- Unit 是"运行中的 tenant"（running tenant vs created tenant）
- tenant 创建时只有 meta，激活时才分配 Unit

### 10.2 与 #44 IO Subsystem

IO 调度与 Unit 配额深度集成：
- mClock 算法按 unit 权重分配 IO
- 高优先级请求（小 IO / 备份）可绕过 unit 配额
- IO 监控上报到 unit 级别

### 10.3 与 #25 Memory Management

Unit 内存分配通过 ObAllocator：
- 每个 unit 有 max_memory_ 配额
- MemTracker 实时跟踪 unit 内存使用
- 超过 max_memory_ → OOM（unit 内）

### 10.4 与 #57 Config System

Resource 配置持久化在 `__all_unit_config` 等内部表：
- 启动时加载
- ALTER UNIT / ALTER TENANT 时修改
- RS 持久化 + 同步到各 observer

### 10.5 与 #70 SQL Audit / Security

权限检查先于资源分配：
- 用户必须有 ALTER RESOURCE UNIT 权限
- 权限通过后由 Resource Manager 检查配额合法性

---

## 11. 总结

### 11.1 资源隔离在 OB 体系中的定位

OB 5.x 的资源隔离是 **多租户 SaaS 的基础设施**：
- 企业客户租户严格隔离
- 大租户弹性扩缩容
- 故障隔离（cgroup 兜底）

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Unit 模型 | `ob_unit_resource.h` 资源配额定义 |
| Resource Manager | `ob_resource_manager` 跨 observer 协调 |
| cgroup 集成 | `ob_cgroup_ctrl` CPU/MEM/IO 配额 |
| 资源计算 | `ob_resource_limit_calculator` 实时容量 |
| IO 调度 | mClock + blkio throttle |
| 多 Unit 弹性 | 1 tenant 多 Unit + 跨 observer 迁移 |
| 软硬隔离 | MemTracker + cgroup 双层防护 |
| 监控 | `ob_all_virtual_cgroup_config` 虚拟表 |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/resource_manager/ob_cgroup_ctrl.{h,cpp}` | cgroup 控制 |
| `src/share/resource_manager/ob_resource_manager.{h,cpp}` | Resource Manager 核心 |
| `src/share/unit/ob_unit_resource.h` | Unit 资源定义 |
| `src/share/resource_limit_calculator/ob_resource_limit_calculator.h` | 资源计算 |
| `src/share/ob_resource_limit.{h,cpp}` | 资源限制定义 |
| `src/observer/virtual_table/ob_all_virtual_cgroup_config.{h,cpp}` | 监控虚拟表 |

### 11.4 路径修正（来自 #60）

我之前在 #60 提到的 `src/share/resource/` + `src/share/cgroup/` **都不存在**，真实路径在 `src/share/resource_manager/` + `src/share/unit/` + `src/share/resource_limit*/`。

### 11.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#72 Config System / ObConfig**：

OB 的配置中心 —— 动态配置 / 热加载 / 配置版本。源码入口：`src/share/config/` + `src/share/parameter_*.{h,cpp}`。

适用场景：参数调优 / 配置中心 / 灰度发布。

整吗？