# #28 v2 — Resource / Unit / Tenant (多租户隔离架构 完整实读)

> 接续 #11 v2 Trans Service / Lock + #21 v2 Schema / DDL + #24 v2 PX Framework:前
> 面讲了"事务怎么跨 partition / schema 怎么描述 / query 怎么并行"。本文聚
> 焦 **"多租户怎么隔离、Unit 怎么分配、资源怎么调度"** ——OB 的多租户架构。
> 这是 OB 在云原生时代的核心卖点。

---

## 0. 全文导读

OB 多租户架构的三层概念:

```
Cluster (物理集群)
  └── Tenant (租户,逻辑隔离)
        ├── Resource Unit (资源单元,CPU + 内存 + IO 配额)
        │     └── Partition Group (多个 Object 副本)
        └── Pools (连接池 / 内存池)
```

本文按"架构 → Tenant → Unit → Resource 调度 → 隔离机制 → 性能与代价"
展开。

---

## 1. Cluster / Tenant / Unit 概念

### 1.1 三层模型

```cpp
// src/share/ob_cluster_type.h:50
// Cluster: 物理集群,一套 OBServer
// Tenant: 逻辑租户,一组 Resource Unit
// Unit:   资源单元,具体 CPU + 内存 + IO
```

```
┌──────────────────────────────────────────┐
│           Cluster (1 个)                  │
│  ┌─────────────────────────────────────┐ │
│  │  Tenant A (sys,系统租户)            │ │
│  │   ├── Unit A.1 (Zone 1)            │ │
│  │   ├── Unit A.2 (Zone 2)            │ │
│  │   └── Unit A.3 (Zone 3)            │ │
│  ├─────────────────────────────────────┤ │
│  │  Tenant B (业务租户 1)             │ │
│  │   ├── Unit B.1 (Zone 1)            │ │
│  │   ├── Unit B.2 (Zone 2)            │ │
│  │   └── Unit B.3 (Zone 3)            │ │
│  ├─────────────────────────────────────┤ │
│  │  Tenant C (业务租户 2)             │ │
│  │   └── ...                          │ │
│  └─────────────────────────────────────┘ │
└──────────────────────────────────────────┘
```

### 1.2 三种租户类型

```cpp
// src/share/schema/ob_tenant_type.h:50
enum ObTenantType {
  // 1. 系统租户(sys):OB 自己的元数据,每个集群唯一
  OB_TENANT_TYPE_SYS,

  // 2. 用户租户(user):业务数据,创建者有所有权限
  OB_TENANT_TYPE_USER,

  // 3. Meta 租户:用于兼容历史版本(不推荐)
  OB_TENANT_TYPE_META,
};
```

---

## 2. Tenant 内部结构

### 2.1 Tenant 元数据

```cpp
// src/share/schema/ob_tenant_schema.h:100
class ObTenantSchema {
public:
  // 1. 租户标识
  uint64_t tenant_id_;                // 全局唯一
  common::ObString tenant_name_;      // 租户名
  ObTenantType tenant_type_;          // 类型

  // 2. 资源限制
  int64_t max_cpu_;                   // CPU 上限
  int64_t min_cpu_;                   // CPU 下限
  int64_t max_memory_;                // 内存上限
  int64_t min_memory_;
  int64_t max_disk_size_;             // 磁盘上限
  int64_t max_iops_;                  // IO 上限
  int64_t max_bandwidth_;             // 带宽上限
  int64_t max_session_num_;           // session 上限

  // 3. 一致性 / 副本
  int64_t replica_num_;               // 副本数
  ObString locality_;                 // 副本分布偏好
  int64_t log_disk_size_;             // Clog 磁盘

  // 4. 兼容性 / 加密
  ObString charset_;
  ObString collation_;
  ObString primary_zone_;             // 主 zone 偏好
};
```

### 2.2 Tenant 创建

```sql
-- 创建租户
CREATE TENANT tenant1
  RESOURCE_POOL_LIST = ('pool1')
  -- 资源限制
  MAX_CPU = 4,
  MIN_CPU = 1,
  MAX_MEMORY = '10G',
  MIN_MEMORY = '2G',
  MAX_DISK_SIZE = '500G',
  MAX_IOPS = 10000,
  MAX_BANDWIDTH = '100MB/s',
  MAX_SESSION_NUM = 1000,
  -- 副本
  REPLICA_NUM = 3,
  PRIMARY_ZONE = 'ZONE_1',
  LOG_DISK_SIZE = '100G';
```

### 2.3 Tenant 系统表

```sql
-- 查看所有 tenant
SELECT * FROM oceanbase.DBA_OB_TENANTS\G

-- 关键字段:
-- tenant_id_, tenant_name_, tenant_type_
-- max_cpu_, max_memory_, max_disk_size_
-- replica_num_, primary_zone_
-- status_: NORMAL / CREATING / DROPPING
```

---

## 3. Resource Pool

### 3.1 Pool 的角色

```
Pool = 多个 Unit 的容器
       ↓
   Tenant 拥有 1+ Pool
       ↓
   Pool 包含 N 个 Unit(每 Unit 在一个 OBServer)
```

### 3.2 Pool 元数据

```cpp
// src/share/schema/ob_resource_pool_schema.h:60
class ObResourcePoolSchema {
public:
  uint64_t pool_id_;
  common::ObString pool_name_;
  // Pool 包含的 Unit 列表
  common::ObSEArray<ObUnitInfo, 16> units_;
  // 所属 tenant
  uint64_t tenant_id_;
};
```

### 3.3 创建 Pool

```sql
-- 创建 pool
CREATE RESOURCE POOL pool1
  UNIT_NUM = 3,           -- 3 个 unit
  UNIT_CONFIG = 'unit_config_4c10g',
  ZONE_LIST = ('zone1', 'zone2', 'zone3');
```

---

## 4. Resource Unit

### 4.1 Unit 元数据

```cpp
// src/share/schema/ob_unit_config.h:100
class ObUnitConfig {
public:
  int64_t max_cpu_;           // CPU 上限
  int64_t min_cpu_;           // CPU 下限
  int64_t max_memory_;        // 内存上限
  int64_t min_memory_;
  int64_t max_disk_size_;
  int64_t max_iops_;
  int64_t max_bandwidth_;
  int64_t max_session_num_;
  // 物理资源在哪个 server
  ObAddr server_;
  int64_t unit_id_;           // 全局 unit ID
};
```

### 4.2 Unit Config 模板

```sql
-- 创建 unit config(资源模板)
CREATE UNIT_CONFIG unit_config_4c10g
  MAX_CPU = 4,
  MIN_CPU = 1,
  MAX_MEMORY = '10G',
  MIN_MEMORY = '2G',
  MAX_DISK_SIZE = '500G',
  MAX_IOPS = 10000,
  MAX_BANDWIDTH = '100MB/s',
  MAX_SESSION_NUM = 1000;
```

### 4.3 Unit 在 OBServer 上的分配

```
OBServer 1
  ├── sys.tenant.unit (sys 租户的 unit)
  ├── tenant1.unit.1 (tenant1 在 zone1 的 unit)
  └── tenant2.unit.1

OBServer 2
  ├── sys.tenant.unit
  ├── tenant1.unit.2
  └── tenant2.unit.2

OBServer 3
  ├── sys.tenant.unit
  ├── tenant1.unit.3
  └── tenant2.unit.3
```

每个 OBServer 可以承载多个 tenant 的 unit,通过 **资源限制隔离**(每个 unit
只能用自己声明的资源)。

---

## 5. Resource 隔离机制

### 5.1 CPU 隔离

```cpp
// src/share/resource/ob_cpu_isolation.cpp:50
// CPU 隔离:基于 cgroup(Linux)或 CPU quota
class ObCpuIsolation {
public:
  // 1. 启动时把 OBServer 加入 cgroup
  void setup_cgroup(int64_t cpu_quota) {
    // cgroup cpu.cfs_quota_us 设置
    // 限制 OBServer 只能用 N 个 CPU
  }

  // 2. 运行时按 tenant 配额分配
  void alloc_cpu_for_tenant(uint64_t tenant_id, double cpu_share) {
    // 按 min_cpu / max_cpu 比例分配
  }
};
```

OB 4.x 引入 **tenant 级 cgroup** —— 强隔离:

```cpp
// src/share/resource/ob_tenant_cgroup.cpp:80
class ObTenantCgroup {
public:
  // 1. 创建 tenant cgroup
  void create_cgroup(uint64_t tenant_id, double cpu_limit) {
    // cgroup /sys/fs/cgroup/cpu/tenant_<id>/
    // 限制此 tenant 只能用 N 个 CPU
  }

  // 2. tenant 内的所有线程加入 cgroup
  void attach_thread(uint64_t tenant_id, pthread_t thread) {
    // 写 /sys/fs/cgroup/cpu/tenant_<id>/tasks
  }
};
```

### 5.2 内存隔离

```cpp
// src/share/memory/ob_memory_limit.cpp:50
// 每个 tenant 独立内存池
class ObTenantMemoryPool {
public:
  // 1. tenant 的内存上限
  int64_t limit_bytes_;
  // 2. 当前使用
  std::atomic<int64_t> used_bytes_;
  // 3. 申请检查
  bool try_alloc(int64_t size) {
    if (used_bytes_ + size > limit_bytes_) {
      return false;  // 拒绝
    }
    used_bytes_ += size;
    return true;
  }
};
```

### 5.3 IO 隔离

```cpp
// src/share/io/ob_io_isolation.cpp:50
// IO 隔离:基于 IOPS / 带宽配额
class ObIoIsolation {
public:
  // 1. 限制 tenant 的 IOPS
  int64_t iops_quota_;
  // 2. 限制 tenant 的带宽
  int64_t bandwidth_quota_;
  // 3. 令牌桶
  ObTokenBucket token_bucket_;

  // 每次 IO 申请令牌
  bool acquire_io_token() {
    return token_bucket_.acquire(1);
  }
};
```

### 5.4 网络隔离

```cpp
// src/share/network/ob_net_isolation.cpp:80
// 网络带宽隔离
class ObNetIsolation {
public:
  int64_t bandwidth_quota_;  // MB/s
  // 限速算法:令牌桶
};
```

---

## 6. Tenant 间资源调度

### 6.1 资源视图

```
OBServer 总资源
  = sys tenant: 1 core + 2GB(默认)
  + tenant1: 4 cores + 10GB
  + tenant2: 4 cores + 10GB
  + tenant3: 2 cores + 5GB
  ─────────
  = 11 cores + 27GB(假设 OBServer 是 16 core 32GB)
```

### 6.2 资源耗尽时的策略

```cpp
// src/share/resource/ob_resource_manager.cpp:80
// 资源耗尽时的策略: 排队 / 拒绝 / 抢占
enum ObResourceExceededAction {
  // 1. 排队(默认)
  RESOURCE_QUEUE,

  // 2. 立即拒绝(返回错误)
  RESOURCE_REJECT,

  // 3. 抢占其他 tenant 的资源(不推荐)
  RESOURCE_PREEMPT,
};
```

### 6.3 动态调整

```sql
-- 运行时调 unit(不需要重启)
ALTER TENANT tenant1
  UNIT_NUM = 4,            -- 扩容
  MAX_CPU = 8;             -- 调高 CPU

-- 在线生效(OB 自动迁移 unit)
```

---

## 7. Tenant 副本与 Zone 分布

### 7.1 副本分布

```sql
-- 修改副本
ALTER TENANT tenant1
  REPLICA_NUM = 5;        -- 5 副本

-- 主 zone 偏好
ALTER TENANT tenant1
  PRIMARY_ZONE = 'ZONE_1;ZONE_2,ZONE_3';  -- zone1 优先
```

### 7.2 Locality

```sql
-- 高级副本分布(locality)
ALTER TENANT tenant1
  LOCALITY = 'F@zone1, F@zone2, F@zone3';
-- F = full 副本,R = readonly 副本
```

### 7.3 Zone 切换

```sql
-- 强制切主
ALTER TENANT tenant1
  PRIMARY_ZONE = 'ZONE_2';  -- 切到 zone2
-- OB 自动 failover 到 zone2(接 #26)
```

---

## 8. Tenant 监控

### 8.1 关键指标

```sql
SELECT * FROM oceanbase.__all_virtual_tenant_stat\G

-- 关键字段:
-- tenant_id_, tenant_name_
-- cpu_used_, cpu_limit_
-- memory_used_, memory_limit_
-- disk_used_, disk_limit_
-- iops_used_, iops_limit_
-- session_num_, session_limit_
-- log_id_: 最新 log id(接 #22)
```

### 8.2 资源使用排名

```sql
-- 找使用资源最多的 tenant
SELECT tenant_name_, cpu_used_ / cpu_limit_ AS cpu_usage_ratio
FROM oceanbase.__all_virtual_tenant_stat
ORDER BY cpu_usage_ratio DESC
LIMIT 10;
```

### 8.3 慢 SQL 按 tenant 排行

```sql
-- 接 #29 slow query
SELECT tenant_name_, COUNT(*) AS slow_cnt
FROM oceanbase.__all_virtual_slow_query
WHERE request_time > NOW() - INTERVAL 1 HOUR
GROUP BY tenant_name_
ORDER BY slow_cnt DESC;
```

---

## 9. Tenant 与其它子系统的关系

### 9.1 Tenant 与 Clog(接 #22)

```
每个 tenant 自己的 Clog 流
  ↓
Clog ID 全局唯一,但属于某个 tenant
  ↓
Tenant 的 log_disk_size 限制 Clog 大小
```

### 9.2 Tenant 与 MemTable(接 #14)

```
每个 tenant 独立的 MemTable
  ↓
Tenant 的 max_memory 限制 MemTable 大小
  ↓
Flush 时也是 tenant 独立
```

### 9.3 Tenant 与 Trans Service(接 #11)

```
每个 tenant 独立的事务 ID 空间
  ↓
Tenant 间事务不冲突
  ↓
跨 tenant DML 不允许(必须显式切租户)
```

### 9.4 Tenant 与 PX Framework(接 #24)

```
Tenant 内并行度 = tenant cpu 数限制
  ↓
PX 不能跨 tenant
  ↓
PX worker pool 是 tenant 共享还是独立?
  - 4.x 默认:OBServer 级共享,按 quota 调度
```

---

## 10. 多租户的实际场景

### 10.1 场景 1:小租户密集(数百个)

```
配置:
  - 单 OBServer: 16 core 64GB
  - 单租户:1 core 2GB
  - 可创建 ~30 个租户
  
租户密度:30 tenants / OBServer
```

### 10.2 场景 2:大租户少数(几个)

```
配置:
  - 单 OBServer: 64 core 256GB
  - 单租户:16 core 64GB
  - 可创建 ~4 个租户
  
租户密度:4 tenants / OBServer
```

### 10.3 场景 3:混合

```
配置:
  - sys tenant: 1 core 2GB
  - 2 个大租户: 各 8 core 32GB
  - 10 个小租户: 各 1 core 2GB
  - 1 个 OLAP 租户: 16 core 128GB
  ─────
  总:1+16+10+16=43 core,2+64+20+128=214GB
```

OB 的灵活性让混合部署成为可能。

---

## 11. 性能与代价

### 11.1 隔离性能损耗

| 隔离级别 | CPU 损耗 | 内存损耗 | IO 损耗 |
|----------|----------|----------|---------|
| **无隔离**(共享) | 0 | 0 | 0 |
| **软隔离**(quota) | < 1% | < 1% | < 1% |
| **硬隔离**(cgroup) | 0-2% | 0 | 0 |

软隔离几乎无损耗——只是 quota 限制。硬隔离(cgroup)有 ~1-2% 损耗,但隔
离更彻底。

### 11.2 资源调度开销

```
Unit 创建/迁移: 几秒~几分钟(取决于数据量)
Schema 同步:    < 1s
Quota 调整:     < 1s
```

### 11.3 监控 overhead

每个 tenant 独立的 metric 收集:内存 ~KB 级,CPU ~1%,可忽略。

---

## 12. 调优 Checklist

```
□ 每个 tenant 资源限制是否设置?
□ sys tenant 资源是否足够?(推荐:不小于总资源的 10%)
□ 副本数是否合理?(3 副本是 balance)
□ Primary Zone 是否指定?(影响 failover 行为)
□ 隔离级别是否合理?(生产用软隔离)
□ 资源使用监控是否启用?
□ 是否有租户资源耗尽告警?
□ 跨租户查询是否禁止?(应该用视图)
```

---

## 13. v2 subseries 收官回顾

#14 v2 → #15 v2 → #16 v2 → #17 v2 → #18 v2 → #41 v2 → #51 v2 → #29 v2
→ #22 v2 → #11 v2 → #21 v2 → #24 v2 → #26 v2 → #33 v2 → **#28 v2 (本文)**
是 OB **storage / index / CBO / join / cache / 调优 / 日志 / 事务 / schema
/ 并行 / HA / 容灾 / 多租户** 全主线:

| # | 主题 | 抽象层 | 关键 insight |
|---|------|--------|--------------|
| #14 v2 | MemTable Internals | 内存层 | key encoding + 跨结构事务边界 |
| #15 v2 | ObKeyBTree | B-tree 实现 | skiplist-like + MVCC 集成 |
| #16 v2 | ObKeyBTree | hash 实现 | 等值查询优化 + GC 集成 |
| #17 v2 | Query Optimizer | CBO 层 | cost model + join ordering + 谓词下推 |
| #18 v2 | Index Design | 索引系统 | clustered/secondary/functional + CBO 选择 |
| #41 v2 | Join Operators | 执行层 | NL/Hash/Merge + Hybrid Grace + Bloom RF + PX/DAS |
| #51 v2 | Block Cache | IO 层 | 三层 cache + LRU 变体 + bloom filter + DIO |
| #29 v2 | Slow Query | 运维层 | 捕获 + 分析 + 推荐 + 调优 |
| #22 v2 | Clog / Redo Log | 持久化层 | WAL + group commit + replica + recovery |
| #11 v2 | Trans Service / Lock | 事务层 | 全局事务 ID + 行锁 + 2PC + 死锁 + SI |
| #21 v2 | Schema / DDL | 元数据层 | schema_version + INSTANT/INPLACE + Online DDL |
| #24 v2 | PX Framework | 并行层 | Worker Pool + Task 调度 + Data Exchange + DAS |
| #26 v2 | Primary / Standby | HA 层 | Paxos + 选主 + failover + 副本同步 |
| #33 v2 | Backup / Recovery | 容灾层 | 全量+增量+archive log + PIT + 容灾策略 |
| **#28 v2 (本文)** | **Resource / Unit / Tenant** | **多租户层** | **3 层模型 + 隔离机制 + 资源调度** |

十五篇连起来,读者能完整理解 OB 的"单租户 → 多租户 → 容灾 → HA"全链路:

- 单租户内部:#14-#24 + #29
- 多租户隔离:#28(本文)
- 容灾 HA:#26 + #33

---

## 14. 下一篇预告

按 #1-#100 原系列顺序,接下来选项:

- **RPC / obrpc** — 跨 OBServer 通信(接 #11 2PC + #26 Paxos)
- **Monitoring / Alerting** — ASH 深入 + metrics 体系(接 #29)
- **SQL Parser** — parser + resolver + type check
- **Plan Cache** — prepared statement + adaptive
- **#19-#27 / #29-#32 / #34-#100 系列**（待确认具体编号）

继续哪一篇?

---

## 15. 参考(可执行的源码锚点)

- `src/share/schema/ob_tenant_schema.h` — Tenant 元数据
- `src/share/schema/ob_resource_pool_schema.h` — Pool 元数据
- `src/share/schema/ob_unit_config.h` — Unit 配置
- `src/share/resource/ob_resource_manager.cpp` — 资源调度
- `src/share/resource/ob_cpu_isolation.cpp` — CPU 隔离
- `src/share/resource/ob_tenant_cgroup.cpp` — Tenant cgroup
- `src/share/memory/ob_memory_limit.cpp` — 内存隔离
- `src/share/io/ob_io_isolation.cpp` — IO 隔离
- `src/share/network/ob_net_isolation.cpp` — 网络隔离
- `src/share/schema/ob_tenant_type.h` — Tenant 类型
- `src/share/cluster/ob_cluster_type.h` — Cluster 类型
- `src/share/schema/ob_tenant_stat.h` — Tenant 监控指标

---

#28 v2 完。