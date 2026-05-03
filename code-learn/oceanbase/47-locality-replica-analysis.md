# 47 — Locality 与副本分布 — 副本策略、Locality 变更、分布管理

> 基于 OceanBase CE 主线源码
> 分析入口：`src/share/ob_locality_info.h` · `src/rootserver/ob_locality_util.h`
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

在分布式数据库中，"数据放在哪"是个根本性问题。Locality（本地性）就是 OceanBase 用来**描述和管理副本分布策略**的核心机制。

Locality 决定了每个分区（Partition）的副本在哪些 Zone 上、每个 Zone 上放什么类型的副本、每种副本放多少个。如果把 OceanBase 的副本管理看作一个三层的金字塔：

```
                        Locality 策略层
                   ┌──────────────────────┐
                   │  "F@z1,F@z2,R@z3"    │   ← 用户声明的策略
                   │  解析 → 标准化         │
                   └──────────┬───────────┘
                              │
                   ┌──────────▼───────────┐
                   │  Unit 放置层          │
                   │  ObUnitManager        │   ← 资源分配
                   │  Unit → OBServer      │
                   └──────────┬───────────┘
                              │
                   ┌──────────▼───────────┐
                   │  副本部署层            │
                   │  LocalityAlignment    │   ← 副本与 Locality 匹配
                   │  迁移/增删副本         │
                   └──────────────────────┘
```

- **文章 27（RootServer）** 分析了集群管控的总体架构
- **文章 37（位置缓存）** 分析了请求如何路由到正确副本
- **文章 19（分区迁移）** 分析了副本迁移机制
- **本文** 补上最上层：**副本分布策略的定义、解析、变更与对齐**

---

## 1. Locality 核心数据模型

### 1.1 综述

Locality 的数据模型分三层，从 SQL 字符串到底层结构体：

```
SQL 字符串      解析后结构体                    持久化
"F@z1,R@z2"  →  ObLocalityDistribution  →  __all_tenant 表
                 ├─ ZoneSetReplicaDist[]     locality 列
                 │   ├─ zone_set_
                 │   └─ all_replica_attr_array_[]
                 │       ├─ FULL_REPLICA → [{num, memstore_percent}]
                 │       ├─ LOGONLY_REPLICA
                 │       ├─ READONLY_REPLICA
                 │       └─ COLUMNSTORE_REPLICA
                 └─ RawLocalityIter (解析器)
```

### 1.2 ObLocalityDistribution — Locality 解析与分布

文件：`src/rootserver/ob_locality_util.h:56`

```cpp
class ObLocalityDistribution           // ob_locality_util.h:56
{
public:
  int parse_locality(                  // 入口：解析 Locality 字符串
      const common::ObString &input_string,
      const common::ObIArray<common::ObZone> &zone_list,
      const common::ObIArray<share::schema::ObZoneRegion> *zone_region_list = NULL);

  int output_normalized_locality(      // 输出标准化的 Locality 字符串
      char *buf, const int64_t buf_len, int64_t &pos);

  int get_zone_replica_attr_array(     // 获取每个 Zone 的副本属性
      common::ObIArray<share::ObZoneReplicaAttrSet> &zone_replica_num_array);
};
```

内部嵌套了两个关键类：

1. **`ZoneSetReplicaDist`**（第 83 行）— 描述一个 Zone 集合上的副本分布
2. **`RawLocalityIter`**（第 143 行）— 原始 Locality 字符串的迭代解析器

#### ZoneSetReplicaDist

```cpp
class ZoneSetReplicaDist              // ob_locality_util.h:83
{
  // zone_set_ 描述了目标 Zone（单 Zone 或 Zone 集合）
  common::ObArray<common::ObZone> zone_set_;
  // 每种副本类型对应一个属性数组
  ReplicaAttrArray all_replica_attr_array_[REPLICA_TYPE_MAX];
  // REPLICA_TYPE_MAX = 5: FULL, LOGONLY, READONLY, ENCRYPTION_LOGONLY, COLUMNSTORE
};
```

`ReplicaAttr` 结构（`share/ob_replica_info.h`）包含两个字段：

```cpp
struct ReplicaAttr {
  int64_t num_;               // 副本数量（可取值: 正整数 或 ALL_SERVER_CNT）
  int64_t memstore_percent_;  // Memstore 百分比（0~100，默认 100）
};
```

#### RawLocalityIter — 字符串解析器

文件：`src/rootserver/ob_locality_util.cpp:501`

`RawLocalityIter` 将 Locality 字符串拆分为多个 `ZoneSetReplicaDist`。典型的 Locality 字符串如：

```
F@z1, F{2}@z2, R@z3, R{ALL_SERVER,MEMSTORE_PERCENT:50}@z4
```

解析步骤（`get_next_zone_set_replica_dist`，第 536 行）：
1. 找到 `@` 分隔符
2. 左侧提取副本类型和属性：`get_replica_arrangements()`
3. 右侧提取 Zone 列表：`get_zone_set_dist()`

核心解析入口 `get_next_replica_arrangement`（第 677 行）逐 token 识别：

```
FULL        → "FULL" 或 "F"
LOGONLY     → "LOGONLY" 或 "L"
READONLY    → "READONLY" 或 "R"
COLUMNSTORE → "COLUMNSTORE" 或 "C"
```

花括号内支持两种属性（`get_replica_attribute_recursively`，第 763 行）：
- **副本数量**：正整数或 `ALL_SERVER`
- **Memstore 百分比**：`MEMSTORE_PERCENT:50`

### 1.3 ObLocalityInfo — 运行时 Locality 信息

文件：`src/share/ob_locality_info.h:48`

如果说 `ObLocalityDistribution` 是**策略定义**的解析结果，`ObLocalityInfo` 就是**运行时状态**的快照——每个 Observer 节点都持有自己的 `ObLocalityInfo` 来理解集群拓扑。

```cpp
struct ObLocalityInfo                    // ob_locality_info.h:48
{
  int64_t version_;                      // 版本号
  common::ObRegion local_region_;        // 本机所在 Region
  common::ObZone local_zone_;            // 本机所在 Zone
  common::ObIDC local_idc_;              // 本机所在 IDC
  ObZoneType local_zone_type_;           // 本机 Zone 类型
  ObZoneStatus::Status local_zone_status_;

  ObLocalityRegionArray locality_region_array_;  // 所有 Region
  ObLocalityZoneArray locality_zone_array_;      // 所有租户的优先级信息
};
```

核心字段解释：
- **`locality_region_array_`**：全局的 Region → Zone 映射关系；每个 Region 包含一组 Zone
- **`locality_zone_array_`**：租户级别的 Region 优先级，用于 Leader 选举时的 Region 偏好

`ObLocalityInfo` 的合法性检查（`ob_locality_info.cpp:160`）：

```cpp
bool ObLocalityInfo::is_valid()
{
  return !local_zone_.is_empty()
         && !local_region_.is_empty()
         && ObZoneType::ZONE_TYPE_INVALID != local_zone_type_;
}
```

#### ObLocalityTableOperator — Locality 表操作

文件：`src/share/ob_locality_table_operator.h:19`

```cpp
class ObLocalityTableOperator       // ob_locality_table_operator.h:19
{
public:
  int load_region(
      const common::ObAddr &addr,
      const bool &is_self_cluster,
      common::ObISQLClient &sql_client,
      ObLocalityInfo &locality_info,
      ObServerLocalityCache &server_locality_cache);
};
```

`load_region()`（`ob_locality_table_operator.cpp`）执行一条跨表 SQL 查询：

```sql
SELECT svr_ip, svr_port, a.zone, info, value, b.name, a.status,
       a.start_service_time, a.stop_time
FROM __all_server a
LEFT JOIN __all_zone b ON a.zone = b.zone
WHERE (b.name = 'region' or b.name = 'idc' or b.name = 'status'
       or b.name = 'zone_type')
  AND a.zone != ''
ORDER BY svr_ip, svr_port, b.name
```

这条查询返回每个服务器的 4 条记录（idc、region、status、zone_type），`load_region()` 为每个服务器构造一个 `ObServerLocality` 对象，同时构建全局的 `locality_region_array_`（Region → Zone 映射）。

### 1.4 ObLocalityPriority — 优先级计算

文件：`src/share/ob_locality_priority.h:13`

Locality 优先级用于 Leader 均衡和容灾场景，决定哪个 Region/Zone 的 Leader 更优先。

```cpp
class ObLocalityPriority                  // ob_locality_priority.h:13
{
  // 解析 primary_zone 字符串，得到租户的 Region 优先级列表
  static int get_primary_region_prioriry(
      const char *primary_zone,
      const ObIArray<ObLocalityRegion> &locality_region_array,
      ObIArray<ObLocalityRegion> &tenant_region_array);

  // 获取本 Region 的优先级（越小越优先）
  static int get_region_priority(
      const ObLocalityInfo &locality_info,
      const ObIArray<ObLocalityRegion> &tenant_locality_region,
      uint64_t &region_priority);

  // 获取本 Zone 的优先级（区内相同优先级）
  static int get_zone_priority(
      const ObLocalityInfo &locality_info,
      const ObIArray<ObLocalityRegion> &tenant_locality_region,
      uint64_t &zone_priority);
};
```

优先级规则（`ob_locality_priority.cpp`）：
- Primary Zone 字符串用 `;` 分隔 Region 组，`;` 同组用 `,` 分隔 Zone
- Region 优先级 = 分组索引 × `MAX_ZONE_NUM`
- Zone 优先级 = Region 优先级（Zone 在组内）或 Region 优先级 + `MAX_ZONE_NUM - 1`（Zone 不在组内）

---

## 2. 副本类型

### 2.1 类型定义

文件：`deps/oblib/src/lib/ob_define.h:2273`

OceanBase 使用**位掩码**来编码副本类型，每个副本类型由 4 个维度组合而成：

```
比特位结构:
|---- 2 bits ----|---- 2 bits ---|--- 4 bits ---|--- 2 bits ---|--- 2 bits ---|
|--column-store-|-- encryption--|---  clog  ---|-- SSStore ---|--- MemStore --|
MSB                                                                        LSB
```

各维度的定义（`ob_define.h:2248`）：

```cpp
const int64_t WITH_MEMSTORE      = 0;                    // 有 MemStore
const int64_t WITHOUT_MEMSTORE   = 1;                    // 无 MemStore
const int64_t WITH_SSSTORE       = 0 << SSSTORE_BITS_SHIFT;  // 有 SSTable
const int64_t WITHOUT_SSSTORE    = 1 << SSSTORE_BITS_SHIFT;  // 无 SSTable
const int64_t SYNC_CLOG          = 0 << CLOG_BITS_SHIFT;     // 同步日志（Paxos 成员）
const int64_t ASYNC_CLOG         = 1 << CLOG_BITS_SHIFT;     // 异步日志（非 Paxos 成员）
```

实际的副本类型枚举值（`ob_define.h:2273`）：

| 副本类型 | 枚举值 | 位掩码值 | MemStore | SSStore | 日志 | 说明 |
|---------|--------|---------|----------|---------|------|------|
| FULL | `REPLICA_TYPE_FULL` | 0 | ✔ | ✔ | 同步 | 全功能副本 |
| BACKUP | `REPLICA_TYPE_BACKUP` | 1 | ✘ | ✔ | 同步 | 备份副本（已弃用） |
| LOGONLY | `REPLICA_TYPE_LOGONLY` | 5 | ✘ | ✘ | 同步 | 日志副本 |
| READONLY | `REPLICA_TYPE_READONLY` | 16 | ✔ | ✔ | 异步 | 只读副本 |
| MEMONLY | `REPLICA_TYPE_MEMONLY` | 20 | ✔ | ✘ | 异步 | 纯内存副本 |
| ARBITRATION | `REPLICA_TYPE_ARBITRATION` | 21 | ✘ | ✘ | 异步 | 仲裁副本 |
| ENCRYPTION_LOGONLY | `REPLICA_TYPE_ENCRYPTION_LOGONLY` | 261 | ✘ | ✘ | 同步+加密 | 加密日志副本 |
| COLUMNSTORE | `REPLICA_TYPE_COLUMNSTORE` | 1040 | ✔ | ✔ | 异步 | 列存副本 |

### 2.2 核心分类

`ObReplicaTypeCheck`（`ob_define.h:2328`）提供了重要的分类函数：

```cpp
class ObReplicaTypeCheck
{
  // 当前支持的副本类型
  static bool is_replica_type_valid(const int32_t replica_type);

  // Paxos 成员副本（参与选举和日志同步）
  static bool is_paxos_replica(const int32_t replica_type);
  // 非 Paxos 成员副本
  static bool is_non_paxos_replica(const int32_t replica_type);

  // 可选举副本（只有 Paxos 成员可被选为 Leader）
  static bool is_can_elected_replica(const int32_t replica_type);

  // 可写副本（只有 FULL 可写）
  static bool is_writable_replica(const int32_t replica_type);

  // 每种类型的判定函数
  static bool is_full_replica(const int32_t replica_type);
  static bool is_readonly_replica(const int32_t replica_type);
  static bool is_log_replica(const int32_t replica_type);  // LOGONLY + ENCRYPTION_LOGONLY
};
```

### 2.3 四种主要副本的设计意图

```
                     ┌───────────────────────────┐
                     │       Paxos 成员？          │
                     │     (参与投票 + 日志同步)    │
                     └──────────┬────────────────┘
                                │
          ┌─────────────────────┼─────────────────────┐
          ▼                     ▼                     ▼
   ┌───────────┐         ┌───────────┐         ┌───────────┐
   │   FULL    │         │  LOGONLY  │         │  READONLY │
   │ 参与投票  │         │ 参与投票  │         │ 不参与投票│
   │ 有 SSStore│         │ 无 SSStore│         │ 有 SSStore│
   │ 有 MemStore│         │ 无 MemStore│        │ 有 MemStore│
   │ == 主力副本│         │ == 日志中继│         │ == 只读副本│
   └───────────┘         └───────────┘         └───────────┘
                                                    │
                                                    ▼
                                              ┌───────────┐
                                              │COLUMNSTORE│
                                              │ 列存引擎  │
                                              │ 只读不投票│
                                              └───────────┘

                   ┌───────────────────────────┐
                   │      ARBITRATION           │
                   │ 不参加日志复制但有投票权    │
                   │ 用于网络分区容灾            │
                   └───────────────────────────┘
```

**FULL（全功能副本）**：标准 Paxos 成员。参与日志同步和投票，包含完整的 SSStore 和 MemStore。可被选举为 Leader。每个分区至少需要多数派 FULL 副本才能正常工作。

**LOGONLY（日志副本）**：Paxos 成员，参与日志同步和投票，但**不存储数据**（无 SSStore、无 MemStore）。它的作用是在**网络较慢或跨 Region 部署场景**中加速日志提交——TODO: 我只需要同步日志到远程节点即可完成 Paxos 提交，数据在后台异步拉取。自 4.2.5.7 起支持。

**READONLY（只读副本）**：非 Paxos 成员，异步跟随日志，但拥有完整的 SSStore 和 MemStore。提供**读扩展能力**——可以在更多 Zone 上部署只读副本来分散读压力，而不影响写入的 Paxos 组大小。

**ARBITRATION（仲裁副本）**：特殊副本，不参与日志复制但拥有投票权。在 2F1A（2 个 FULL + 1 个仲裁）部署模式下，仲裁副本可以在网络分区时自动判定多数派，保证高可用同时降低资源消耗。

---

## 3. 存储层的 Locality 管理

### 3.1 ObLocalityManager

文件：`src/storage/ob_locality_manager.h:30`

每个 OBServer 节点都有一个 `ObLocalityManager` 实例，负责维护本节点的 Locality 信息。它实现了多个关键接口：

```cpp
class ObLocalityManager : public share::ObILocalityManager,
                          public share::ObIServerAuth  // ob_locality_manager.h:30
{
  // Locality 信息查询
  int get_locality_info(share::ObLocalityInfo &locality_info);
  int get_local_region(common::ObRegion &region) const;
  int get_local_zone_type(common::ObZoneType &zone_type);

  // 服务器位置查询
  int get_server_zone(const common::ObAddr &server, common::ObZone &zone) const;
  int get_server_region(const common::ObAddr &server, common::ObRegion &region) const;
  int get_server_idc(const common::ObAddr &server, common::ObIDC &idc) const;

  // 合法性检查（用于 SSL 鉴权等）
  int is_server_legitimate(const common::ObAddr& addr, bool& is_valid);

  // Zone 只读判断
  virtual int is_local_zone_read_only(bool &is_readonly);
  virtual int is_local_server(const common::ObAddr &server, bool &is_local);
};
```

**定时刷新机制**：

`ObLocalityManager` 通过两个任务维护 Locality 信息的时效性：

1. **`ReloadLocalityTask`**（第 60 行）— 定时任务，每 10 秒（`REFRESH_LOCALITY_INTERVAL = 10 * 1000 * 1000` 微秒）从 `__all_server` 和 `__all_zone` 表重新加载 Locality 信息
2. **`ObRefreshLocalityTask`**（第 70 行）— 去重队列任务，用于响应外部刷新请求

内部结构（`ob_locality_manager.h:107`）：

```cpp
private:
  common::SpinRWLock rwlock_;                        // 读写锁保护 locality_info_
  common::ObAddr self_;                              // 本机地址
  common::ObMySQLProxy *sql_proxy_;                  // SQL 连接
  share::ObLocalityInfo locality_info_;              // 缓存的 Locality 信息
  share::ObServerLocalityCache server_locality_cache_; // 服务器位置缓存
  share::ObLocalityTableOperator locality_operator_;  // 表操作器
  ObDedupQueue refresh_locality_task_queue_;          // 刷新任务去重队列
  ReloadLocalityTask reload_locality_task_;           // 定时刷新任务
```

### 3.2 ObServerLocalityCache

文件：`src/share/ob_server_locality_cache.h:83`

每个 Zone 上有多台 OBServer，LocalityManager 需要知道每台服务器的位置信息（所属 Zone、Region、IDC、ZoneType）。`ObServerLocalityCache` 提供了一个基于 `ObLinearHashMap` 的缓存。

```cpp
class ObServerLocalityCache               // ob_server_locality_cache.h:83
{
  int get_server_zone_type(const common::ObAddr &server, ObZoneType &zone_type) const;
  int get_server_region(const common::ObAddr &server, ObRegion &region) const;
  int get_server_idc(const common::ObAddr &server, ObIDC &idc) const;
  int set_server_locality_array(          // 批量更新缓存
      const ObIArray<ObServerLocality> &server_locality_array,
      bool has_readonly_zone);
};
```

### 3.3 ObLocalityAdapter — 日志模块的 Locality 适配器

文件：`src/logservice/ob_locality_adapter.h:20`

日志模块（PALF）需要知道每台服务器的 Region 信息来优化跨 Region 的日志复制路径。`ObLocalityAdapter` 实现了 `palf::PalfLocalityInfoCb` 回调接口，将 `ObLocalityManager` 暴露给日志模块。

```cpp
class ObLocalityAdapter : public palf::PalfLocalityInfoCb  // ob_locality_adapter.h:20
{
public:
  int get_server_region(const common::ObAddr &server, common::ObRegion &region) const override final;
private:
  storage::ObLocalityManager *locality_manager_;
};
```

---

## 4. Locality 变更流程

### 4.1 总体流程

Locality 变更通过 SQL 命令触发：

```sql
ALTER SYSTEM ALTER TENANT tenant_name SET LOCALITY = 'F@z1,F@z2,R@z3';
```

完整的变更流程如下：

```
用户 SQL: ALTER SYSTEM ALTER TENANT ... LOCALITY = '...'
    │
    ├→ 1. ObTenantDDLService::set_new_tenant_options()
    │      └→ check_alter_tenant_locality_type()
    │         区分: ROLLBACK_LOCALITY / TO_NEW_LOCALITY / INVALID
    │
    ├→ 2. try_modify_tenant_locality()
    │      ├─ 解析新旧 Locality → ObLocalityDistribution
    │      ├─ 计算差异: check_alter_locality()
    │      ├─ 生成 AlterPaxosLocalityTask 列表
    │      └─ 设置 previous_locality (备份旧策略)
    │
    ├→ 3. RootServer 接管 → 调度 Unit 迁移 / 副本增删
    │
    ├→ 4. ObAlterLocalityFinishChecker::check()  (定时轮询)
    │      ├─ 对每个租户检查所有 LS 的副本是否对齐新 Locality
    │      ├─ 通过 ObDRWorker::check_tenant_locality_match()
    │      ├─ 对齐完成 → RPC commit_alter_tenant_locality
    │      └─ 未完成 → 等待下一轮
    │
    └→ 5. commit_alter_tenant_locality()
           └─ 清除 previous_locality (旧策略)
              Locality 变更正式完成
```

### 4.2 变更类型判定

文件：`src/rootserver/ob_tenant_ddl_service.cpp:2556`

`check_alter_tenant_locality_type()` 区分三种情况：

```cpp
enum AlterLocalityType {
  ALTER_LOCALITY_INVALID,    // 不允许变更（正在执行其他变更）
  ROLLBACK_LOCALITY,        // 回滚到上一个 Locality
  TO_NEW_LOCALITY,          // 切换到全新 Locality
};
```

如果租户的 `previous_locality` 非空（表明有正在进行的 Locality 变更），则只能执行 `ROLLBACK_LOCALITY`；只有 `previous_locality` 为空时才能执行 `TO_NEW_LOCALITY`。

### 4.3 变更的安全约束

文件：`src/rootserver/ob_tenant_ddl_service.cpp`（约 2648 行附近，注释块有详细说明）

Locality 变更遵循严格的安全规则：

```
规则 1：每次变更只能做三类操作之一
  ├── 增加 Paxos 副本
  ├── 减少 Paxos 副本
  └── Paxos 类型转换 (F↔L)

规则 2：多数派安全
  ├── 增加 Paxos 时：旧 Paxos 数量 >= 多数派(新 Paxos 数量)
  └── 减少 Paxos 时：新 Paxos 数量 >= 多数派(旧 Paxos 数量)

规则 3：类型转换限制
  ├── L 不可转换为其他类型，其他类型不可转换为 L
  └── 一次变更最多一个 Paxos 类型转换

规则 4：单 Zone 限制
  └── 从 3.2.1 起，一个 Zone 只能部署一个 Paxos 副本

示例：
  ✔ F@z1,F@z2,F@z3 → F@z1,L@z2,F@z4   (z2 类型转换 + z3 移除 + z4 添加: 规则 1 违反)
  ✔ F@z1,F@z2,R@z3 → F@z1,F@z2,F@z3,F@z4 (添加两个 F: 规则 2.1 违反)
  ✔ F@z1 → F@z1,F@z2   (规则 1 的例外: 1→2 允许)
  ✔ F@z1,F@z2,F@z3     → F@z1,R@z2     (规则 2.2: 新 Paxos=1 < 旧多数派=2)
```

### 4.4 ObAlterLocalityFinishChecker — 变更完成检查

文件：`src/rootserver/ob_alter_locality_finish_checker.h:52`

```cpp
class ObAlterLocalityFinishChecker : public share::ObCheckStopProvider
                                     // ob_alter_locality_finish_checker.h:52
{
  int check();   // 主入口，由 ObRootServiceUtilChecker 定时调用
};
```

`check()` 方法（`ob_alter_locality_finish_checker.cpp:62`）的核心逻辑：

```cpp
int ObAlterLocalityFinishChecker::check()
{
  // STEP 0: 获取所有租户 Schema
  // STEP 1: 对每个租户:
  //   a) 检查 previous_locality 是否为空
  //   b) 通过 ObDRWorker::check_tenant_locality_match() 检查副本是否对齐
  //   c) 对齐完成 → 发送 RPC commit_alter_tenant_locality
  //   d) 未对齐 → 等待下一轮检查
}
```

**`ObDRWorker::check_tenant_locality_match()`**（`ob_disaster_recovery_worker.cpp:2180`）是核心的副本对齐检查函数：

```
check_tenant_locality_match(tenant_id)
  │
  ├→ 获取租户的所有 LS 状态 (__all_ls_status)
  │
  ├→ 对每个 LS:
  │   ├─ 获取 LS 的副本信息 (LS Meta Table)
  │   ├─ 构建 DRLSInfo
  │   ├─ LocalityAlignment::build()
  │   │   ├─ compare_replica_stat_with_locality()
  │   │   └─ 生成 Locality Alignment Task 列表
  │   └─ 如果 task_array 为空 → 副本已对齐
  │
  └→ check_unit_list_match_locality()
      确认 Unit 分布也与 Locality 一致
```

**`LocalityAlignment`**（`ob_disaster_recovery_worker.h:742`）使用哈希表（`LocalityMap`）将目标 Locality 的副本描述与实际副本分布进行匹配。如果存在差异，生成一系列调整任务：

```cpp
enum LATaskType {
  ADD_REPLICA,           // 需要添加副本
  REMOVE_REPLICA,        // 需要移除多余副本
  TYPE_TRANSFORM,        // 需要类型转换
  MODIFY_PAXOS_REPLICA_NUMBER,  // 需要修改 Paxos 副本数量
};
```

### 4.5 变更完成确认

当 `ObAlterLocalityFinishChecker` 确认所有 LS 的副本与新的 Locality 对齐后，通过 RPC 调用 `commit_alter_tenant_locality()`（`ob_tenant_ddl_service.cpp:5790`）：

```cpp
int ObTenantDDLService::commit_alter_tenant_locality(
    const rootserver::ObCommitAlterTenantLocalityArg &arg)
{
  // 1. 验证 tenant_id
  // 2. 确保 locality 和 previous_locality 都不为空
  // 3. 开启事务
  // 4. 将 previous_locality 设为空字符串（清除旧策略）
  // 5. 提交 Schema 变更
}
```

完成后，租户的 `previous_locality` 被清空，Locality 变更加入历史记录。

---

## 5. 副本分布示意图

### 5.1 三副本 FULL 分布（标准部署）

```
Locality: "F@hz1,F@hz2,F@hz3"

                    ┌────────────────────────────────────┐
                    │           Region: HANGZHOU          │
                    │                                     │
                    │  ┌─────┐   ┌─────┐   ┌─────┐      │
                    │  │ hz1 │   │ hz2 │   │ hz3 │      │
                    │  │     │   │     │   │     │      │
                    │  │ F   │   │ F   │   │ F   │      │
                    │  │     │   │     │   │     │      │
                    │  │Leader│   │Follower│ │Follower│  │
                    │  └─────┘   └─────┘   └─────┘      │
                    └────────────────────────────────────┘
  Paxos 组大小: 3       多数派: 2      写延迟: 1 RTT
```

### 5.2 跨 Region + 只读副本

```
Locality: "F@bj1,F@bj2,R@sh1,R@sz1"

         Region: BEIJING              Region: SHANGHAI       Region: SHENZHEN
    ┌─────────────────────┐      ┌──────────────────┐    ┌──────────────────┐
    │   ┌──────┐ ┌──────┐ │      │   ┌──────┐       │    │   ┌──────┐       │
    │   │ bj1  │ │ bj2  │ │      │   │ sh1  │       │    │   │ sz1  │       │
    │   │      │ │      │ │      │   │      │       │    │   │      │       │
    │   │  F   │ │  F   │ │      │   │  R   │       │    │   │  R   │       │
    │   │Leader│ │Follower│      │   │(只读) │       │    │   │(只读) │       │
    │   └──────┘ └──────┘ │      │   └──────┘       │    │   └──────┘       │
    └─────────────────────┘      └──────────────────┘    └──────────────────┘
  Paxos组大小: 2  多数派: 2  写延迟: 1 RTT    读就近: SH/SZ → READONLY
```

### 5.3 混合副本（FULL + LOGONLY + READONLY）

```
Locality: "F@hz1,L@hz2,R@sz1"

           ┌─────────────────────────── Region: HZ ────────────────────┐
           │                                                         │
           │  ┌────────────────┐      ┌────────────────┐            │
           │  │ hz1 (FULL)    │      │ hz2 (LOGONLY) │            │
           │  │ ┌──┐ ┌──────┐ │      │ ┌──┐            │            │
           │  │ │DB│ │MemS  │ │      │ │DB│(无数据)     │            │
           │  │ └──┘ └──────┘ │      │ └──┘            │            │
           │  │ 参与 Paxos    │      │ 参与 Paxos      │            │
           │  └────────────────┘      └────────────────┘            │
           │                         LogOnly 加速跨 Region 提交     │
           └────────────────────────────────────────────────────────┘

  Region: SZ ───┐
           ┌────▼────┐
           │ sz1 (R) │
           │ ┌──┐    │
           │ │DB│    │  ← 只读查询
           │ └──┘    │
           └─────────┘

  Paxos 组大小: 2     多数派: 2   写路径: hz1(主), hz2(日志)
  读路径: sz1 就近提供只读查询
```

### 5.4 仲裁副本 2F1A

```
Locality: "F@hz1,F@hz2" + 仲裁服务

           ┌───────────────────────────────────┐
           │  Region: HANGZHOU                 │
           │                                   │
           │  ┌──────┐       ┌──────┐          │
           │  │ hz1  │       │ hz2  │          │
           │  │  F   │←─────→│  F   │          │
           │  │Leader│       │Follower│        │
           │  └──────┘       └──────┘          │
           └───────────────────────────────────┘
                        │
              ┌─────────┴──────────┐
              │  仲裁服务节点        │
              │  (投票/不存数据)     │
              └────────────────────┘

  正常时: 2 票即可提交 (2 > 1)
  分区时: 仲裁节点 + 未分区方 = 多数派 (2 > 1)
  节省: 相比 3F 节省 1 份存储
```

---

## 6. 与前面文章的关联

### 6.1 文章 19（分区迁移）

Locality 变更的核心执行者是**分区迁移**。当 `try_modify_tenant_locality()` 计算出差异后（增加/减少/转换副本），RootServer 会创建 Unit 迁移或副本增删任务，这些任务最终由迁移子系统（文章 19）执行。

```
Locality 变更 → ObLocalityDistribution 计算差异
    ↓
AlterPaxosLocalityTask (增/删/转 Paxos 副本)
    ↓
ObUnitManager 调度 Unit 迁移 / 副本操作
    ↓
分区迁移引擎 (文章 19) 执行实际数据移动
    ↓
ObAlterLocalityFinishChecker 轮询等待完成
```

### 6.2 文章 27（RootServer）

ObLocalityDistribution 在 RootServer 中用于：
- **DDL 服务**（`ObTenantDDLService`）：解析 Locality 字符串，校验变更
- **Unit Manager**（`ObUnitManager`）：Locality 决定了 Unit 的放置策略
- **灾难恢复工作线程**（`ObDRWorker`）：检查副本分布是否对齐
- **负载均衡器**（`ObRootBalancer`）：根据 Locality 调整副本分布

### 6.3 文章 37（位置缓存）

Locality 是位置路由的**上游输入**。位置缓存（`ObTabletLSService` + `ObLSLocationService`）从 `ObLocalityManager` 获取副本分布信息，确定每个 LS 的 Leader 和副本列表，最终指导 SQL 执行引擎将请求路由到正确节点。

```
Locality 策略 → ObLocalityManager → LocalityInfo
    ↓
LS 调度器 → LS Meta Table → 位置缓存 (文章 37)
    ↓
SQL 执行 → ObDASTabletMapper → DAS RPC
```

### 6.4 文章 38（PALF 成员变更）

Paxos 成员变更（PALF 的 Member Change）与 Locality 变更紧密耦合。当 Locality 要求增加或减少一个 FULL/LOGONLY 副本时，这对应了 PALF 的成员变更操作（add member / remove member）。

---

## 7. 设计决策

### 7.1 为什么区分四种副本类型？

| 类型 | 存储开销 | 参与投票 | 提供读服务 | 适用场景 |
|------|---------|---------|-----------|---------|
| FULL | 高 | ✔ | ✔ | 标准部署 |
| LOGONLY | 低 | ✔ | ✘ | 跨 Region 加速提交 |
| READONLY | 高 | ✘ | ✔ | 读扩展、副本查询 |
| ARBITRATION | 极低 | ✔ | ✘ | 节省资源的容灾 |

**核心思想**：将 Paxos 投票权和数据存储解耦。FULL 同时承担投票和数据服务，LOGONLY 只需投票无需存储，READONLY 只需数据无需投票，ARBITRATION 只需投票占用极少的资源。

### 7.2 Zone 级 vs 分区级 Locality

OceanBase **只有 Zone 级 Locality**，没有分区级 Locality。这意味着一个 Zone 内的所有分区副本布局是一致的。这个设计选择：

- **优点**：大大简化了调度和迁移的逻辑；Zone 是故障域最小单位，管理清晰
- **缺点**：无法为不同分区定制不同的副本分布（少数业务有此需求，但性价比低）

### 7.3 变更为什么需要两步提交（previous/current）？

```
变更前: locality = "F@hz1"  previous_locality = ""
变更中: locality = "F@hz1,F@hz2"  previous_locality = "F@hz1"
变更完成: locality = "F@hz1,F@hz2"  previous_locality = ""
```

**设计意图**：
1. **可回滚**：如果变更失败或用户不满意，可以用 `FORCE` 选项回滚到 `previous_locality`
2. **幂等性**：RootServer 崩溃重启后，可以从 Schema 中恢复变更状态，继续等待对齐
3. **原子性**：变更分为"提交新策略"和"清除旧策略"两步，中间状态可恢复

### 7.4 Locality 变更的安全性

Locality 变更的安全性保证是多层的：

```
安全层级 1: 语法检查 (ObLocalityDistribution::parse_locality)
  └─ Zone 名称合法性、副本类型合法性、重复 Zone 检查

安全层级 2: 逻辑检查 (check_alter_locality)
  └─ 多数派安全、类型转换限制、一次只允许一类操作

安全层级 3: 执行期检查 (ObAlterLocalityFinishChecker)
  └─ LocalityAlignment 逐 LS 检查副本对齐

安全层级 4: 迁移容错 (分区迁移引擎)
  └─ 迁移失败回滚、RSJob 持久化
```

---

## 8. 源码索引

### 核心数据模型

| 文件 | 行号 | 符号 | 作用 |
|------|------|------|------|
| `src/share/ob_locality_info.h` | 19 | `ObLocalityZone` | 租户级 Region 优先级 |
| `src/share/ob_locality_info.h` | 31 | `ObLocalityRegion` | Region → Zone 映射 |
| `src/share/ob_locality_info.h` | 48 | `ObLocalityInfo` | 运行时 Locality 信息（版本 + 位置 + Region/Zone 数组） |
| `src/share/ob_locality_table_operator.h` | 19 | `ObLocalityTableOperator` | 从 `__all_server` / `__all_zone` 加载 Locality 信息 |
| `src/share/ob_locality_priority.h` | 13 | `ObLocalityPriority` | 计算 Region / Zone 优先级 |
| `src/share/ob_server_locality_cache.h` | 25 | `ObServerLocality` | 单台服务器的位置信息 |
| `src/share/ob_server_locality_cache.h` | 83 | `ObServerLocalityCache` | 服务器位置缓存 |

### 副本类型

| 文件 | 行号 | 符号 | 作用 |
|------|------|------|------|
| `deps/oblib/src/lib/ob_define.h` | 2248 | 位掩码定义 | WITH_MEMSTORE / WITH_SSSTORE / SYNC_CLOG 等 |
| `deps/oblib/src/lib/ob_define.h` | 2273 | `ObReplicaType` 枚举 | FULL(0) / LOGONLY(5) / READONLY(16) / ARBITRATION(21) |
| `deps/oblib/src/lib/ob_define.h` | 2328 | `ObReplicaTypeCheck` | 副本类型分类函数 |

### Locality 解析与分布

| 文件 | 行号 | 符号 | 作用 |
|------|------|------|------|
| `src/rootserver/ob_locality_util.h` | 56 | `ObLocalityDistribution` | Locality 解析与分布存储 |
| `src/rootserver/ob_locality_util.h` | 83 | `ZoneSetReplicaDist` | Zone 集合的副本分布 |
| `src/rootserver/ob_locality_util.h` | 143 | `RawLocalityIter` | Locality 字符串迭代解析器 |
| `src/rootserver/ob_locality_util.h` | 225 | `get_replica_arrangements` | 解析 @ 前的副本安排 |
| `src/rootserver/ob_locality_util.h` | 228 | `get_replica_type` | 副本类型识别 |
| `src/rootserver/ob_locality_util.h` | 229 | `get_replica_attribute` | 副本属性（数量 + memstore%） |
| `src/rootserver/ob_locality_util.h` | 293 | `get_zone_set_dist` | 解析 @ 后的 Zone 列表 |
| `src/rootserver/ob_locality_util.cpp` | 1545 | `parse_for_empty_locality` | 空 Locality 的默认规则 |

### 存储层 Locality 管理

| 文件 | 行号 | 符号 | 作用 |
|------|------|------|------|
| `src/storage/ob_locality_manager.h` | 30 | `ObLocalityManager` | 存储层 Locality 管理器 |
| `src/storage/ob_locality_manager.h` | 43 | `ReloadLocalityTask` | 定时刷新任务（10s） |
| `src/storage/ob_locality_manager.h` | 55 | `ObRefreshLocalityTask` | 去重刷新任务 |
| `src/logservice/ob_locality_adapter.h` | 20 | `ObLocalityAdapter` | 日志模块的 Locality 适配器 |

### Locality 变更

| 文件 | 行号 | 符号 | 作用 |
|------|------|------|------|
| `src/rootserver/ob_tenant_ddl_service.cpp` | 2519 | `alter_locality` 方法 | Locality 变更主入口 |
| `src/rootserver/ob_tenant_ddl_service.cpp` | 2765 | `check_alter_tenant_locality_type` | 变更类型判定 |
| `src/rootserver/ob_tenant_ddl_service.cpp` | 2685 | `try_modify_tenant_locality` | 修改 Locality（差异计算 + 任务生成） |
| `src/rootserver/ob_tenant_ddl_service.cpp` | 5790 | `commit_alter_tenant_locality` | 变更完成确认 |
| `src/rootserver/ob_alter_locality_finish_checker.h` | 52 | `ObAlterLocalityFinishChecker` | 变更完成检查器 |
| `src/rootserver/ob_disaster_recovery_worker.cpp` | 2180 | `check_tenant_locality_match` | 副本对齐检查 |
| `src/rootserver/ob_disaster_recovery_worker.h` | 742 | `LocalityAlignment` | Locality 对齐引擎 |

---

> 全文基于 OceanBase CE 主线源码，使用 doom-lsp 进行符号级分析。
