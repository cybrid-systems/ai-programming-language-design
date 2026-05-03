# 37-location-routing — OceanBase 位置缓存与请求路由深度分析

> 基于 OceanBase CE 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪

---

## 0. 概述

在分布式数据库中，**数据放在哪**和**请求发到哪**是两个根本问题。

OceanBase 将数据划分为 Tablet（数据分片），Tablet 归属于 LogStream（日志流），LogStream 的副本分布在多个 OBServer 节点上。当一条 SQL 请求到达时，执行引擎必须回答三个问题：

1. **Tablet → LogStream**：这个 Tablet 属于哪个 LS？
2. **LogStream → Leader**：这个 LS 的 Leader 在哪台机器上？
3. **Leader → RPC**：如何将 DAS 任务发送到正确的节点？

位置缓存（Location Cache）就是回答这些问题的子系统。它由三层复合结构组成：

```
┌────────────────────────────────────────────────────────┐
│                 ObLocationService                       │
│  (统一入口，对外暴露 get() / nonblock_get() / renew()) │
└──────────┬──────────────────────┬──────────────────────┘
           │                      │
           ▼                      ▼
┌──────────────────┐   ┌──────────────────────┐
│ ObTabletLSService│   │ ObLSLocationService   │
│ Tablet→LS 映射   │   │ LS→Leader/副本列表    │
│ (ob_tablet_ls_   │   │ (ob_ls_location_      │
│  service.cpp)    │   │  service.cpp)         │
└────────┬─────────┘   └────────┬──────────────┘
         │                      │
         ▼                      ▼
┌──────────────────┐   ┌──────────────────────┐
│ ObTabletLSMap    │   │ ObLSLocationMap       │
│ 64K Bucket       │   │ 256 Bucket           │
│ 哈希链表         │   │ 哈希链表             │
└──────────────────┘   └──────────────────────┘
```

### 请求路由的完整路径

```
SQL: SELECT * FROM t WHERE id = 1
  │
  ├→ 1. SQL 解析 → 确定表名、分区键值
  │
  ├→ 2. ObDASTabletMapper: 分区键 → tablet_id
  │     (ob_das_location_router.h)
  │
  ├→ 3. ObTabletLSService::get(): tablet_id → ls_id
  │     ├── 查 ObTabletLSMap 缓存 → 命中 → 返回
  │     └── 未命中 → ObTabletToLSOperator 查询 __all_tablet_to_ls
  │                  → 更新 ObTabletLSMap → 返回
  │
  ├→ 4. ObLSLocationService::get_leader(): ls_id → leader_addr
  │     ├── 查 ObLSLocationMap 缓存 → 命中 → 返回
  │     └── 未命中 → ObLSTableOperator 查询 __all_ls_meta_table
  │                  → 更新 ObLSLocationMap → 返回
  │
  ├→ 5. ObDASLocationRouter: 创建 DAS 任务
  │     (nonblock_get_candi_tablet_locations)
  │
  └→ 6. DAS RPC → 发送到目标 OBServer
```

---

## 1. 位置服务架构

### 1.1 ObLocationService — 统一入口

`ObLocationService`（`ob_location_service.h:37`）是位置缓存对外的统一接口。它组合了三个子服务：

```cpp
// ob_location_service.h:258-261
private:
  ObLSLocationService ls_location_service_;    // LS 位置（副本列表 + Leader）
  ObTabletLSService tablet_ls_service_;         // Tablet → LS 映射
  ObVTableLocationService vtable_location_service_; // 虚拟表位置（性能视图）
```

**设计意图**：将三种定位逻辑收束到一个入口，SQL 层无需关心底层走哪种路径。

**初始化顺序**（`ob_location_service.cpp:350-368`）：

```cpp
int ObLocationService::init(...)
{
  // 1. 初始化 LS 位置服务（依赖 LSTableOperator + RsMgr + RPC Proxy）
  ls_location_service_.init(ls_pt, schema_service, rs_mgr, srv_rpc_proxy);
  // 2. 初始化 Tablet→LS 映射（依赖 MySQLProxy + RPC Proxy）
  tablet_ls_service_.init(schema_service, sql_proxy, srv_rpc_proxy);
  // 3. 初始化虚拟表位置（依赖 RsMgr）
  vtable_location_service_.init(rs_mgr);
}
```

### 1.2 两种查询模式

每个 `get()` 方法都有对应的同步和异步变体：

| 方法 | 语义 | 缓存未命中时的行为 |
|------|------|------------------|
| `get()` | 同步阻塞 | 调用 Inner SQL 查询系统表，阻塞等待 |
| `nonblock_get()` | 非阻塞 | 仅查缓存，未命中立即返回错误码 |
| `nonblock_renew()` | 异步刷新 | 提交异步任务到队列，不阻塞当前线程 |

`expire_renew_time` 参数控制缓存行为的三个档位（`ob_location_service.h:45-49`）：

```cpp
// @param [in] expire_renew_time: 用户能容忍的最旧缓存刷新时间
//   0          → 不刷新，仅查缓存
//   INT64_MAX  → 强制同步刷新
//   其他值     → 如果缓存的 renew_time <= expire_renew_time，则刷新
```

### 1.3 错误码体系

位置查询的专用错误码（`ob_location_struct.h:17-24`）：

```cpp
static inline bool is_location_service_renew_error(const int err)
{
  return err == OB_LOCATION_NOT_EXIST
      || err == OB_LS_LOCATION_NOT_EXIST
      || err == OB_LS_LOCATION_LEADER_NOT_EXIST
      || err == OB_MAPPING_BETWEEN_TABLET_AND_LS_NOT_EXIST;
}
```

这组错误码是"可重试的"——在 `get_leader_with_retry_until_timeout` 中，遇到这类错误会持续重试直到超时。

---

## 2. 两层缓存详解

### 2.1 第一层：Tablet → LS 映射

#### ObTabletLSCache（`ob_location_struct.h:296-314`）

缓存条目，记录了 tablet_id → ls_id 的映射：

```cpp
class ObTabletLSCache : public common::ObLink
{
  ObTabletLSKey cache_key_;   // (tenant_id, tablet_id)
  ObLSID ls_id_;              // 目标 LogStream ID
  int64_t renew_time_;        // 最近一次从系统表刷新的时间戳
  int64_t transfer_seq_;      // 传输序列号（检测 Tablet 迁移）
};
```

#### ObTabletLSMap（`ob_tablet_ls_map.h`）

存储结构：64K（1<<16）个哈希桶，1K 个锁槽，链表法解决冲突。

```cpp
// ob_tablet_ls_map.h:38-51
class ObTabletLSMap
{
  static const int64_t BUCKETS_CNT = 1 << 16;   // 64K
  static const int64_t LOCK_SLOT_CNT = 1 << 10; // 1K
  ObTabletLSCache **ls_buckets_;
  common::ObQSyncLock *buckets_lock_;
};
```

**锁设计**：1K 个 `ObQSyncLock` 均匀覆盖 64K 个桶，支持并发读和排他写。`init()` 中每个锁槽初始化一次（`ob_tablet_ls_map.cpp:42-50`）：

```cpp
buckets_lock_[i]->init(mem_attr);  // ObLatchIds::OB_TABLET_LS_MAP_BUCKETS_LOCK
```

`ObQSyncLock` 是 OceanBase 的**读写锁变体**：
- 读读不互斥（多个 `get()` 可并发）
- 读写互斥（更新时阻塞读，但粒度细——只锁一个槽，不锁全表）
- 支持 `QSyncLockReadGuard` / `QSyncLockWriteGuard`

#### 查询路径

`ObTabletLSService::get()`（`ob_tablet_ls_service.cpp:76-110`）：

```
get(tenant_id, tablet_id, expire_renew_time)
  │
  ├─ tablet_id.belong_to_sys_ls(tenant_id) ?
  │   └── 是 → 直接返回 SYS_LS（系统 LS，硬编码）
  │
  ├─ get_from_cache_() → ObTabletLSMap::get()
  │   ├── 命中且 renew_time > expire_renew_time → 返回（is_cache_hit=true）
  │   └── 未命中或过期 → 走刷新路径
  │
  └─ renew_cache_() → batch_renew_tablet_ls_cache()
      └── 查询 __all_tablet_to_ls 系统表 → 更新缓存 → 返回
```

#### 系统表的 fallback

`batch_renew_tablet_ls_cache()`（`ob_tablet_ls_service.cpp:474`）首先尝试从缓存中过滤掉不过期的条目，对确实需要刷新的 tablet 才执行 Inner SQL：

```cpp
// ob_tablet_ls_service.cpp:500-514
// 1. 遍历 tablet_list，筛选出需要刷新的 tablet
FOREACH_X(tablet_id, tablet_list, OB_SUCC(ret)) {
  // 跳过已被 sys ls 处理的
  // 跳过 expire_renew_time != INT64_MAX 且缓存未过期的
  // 其余加入 need_renew_tablets
}
// 2. 对 need_renew_tablets 执行 bulk SQL 查询
```

这避免了在热点场景下每个 tablet 都触发 SQL 查询。

### 2.2 第二层：LS → Leader 及副本列表

#### ObLSLocation（`ob_location_struct.h:160-203`）

```cpp
class ObLSLocation : public common::ObLink
{
  ObLSLocationCacheKey cache_key_;     // (cluster_id, tenant_id, ls_id)
  int64_t renew_time_;                 // 最近一次刷新的时间戳
  int64_t last_access_ts_;             // 最近一次访问的时间戳
  ObLSReplicaLocations replica_locations_; // 副本列表（Leader + Followers）
};
```

每个副本的信息 `ObLSReplicaLocation`（`ob_location_struct.h:29-72`）：

```cpp
class ObLSReplicaLocation
{
  common::ObAddr server_;        // 节点地址
  common::ObRole role_;          // LEADER / FOLLOWER
  int64_t sql_port_;             // SQL 端口
  common::ObReplicaType replica_type_;  // 副本类型（FULL/READONLY/LOGONLY）
  int64_t proposal_id_;          // Paxos proposal ID（仅 Leader 有效）
  ObLSRestoreStatus restore_status_;
  // 关键方法：
  bool is_strong_leader() const { return common::is_strong_leader(role_); }
};
```

#### ObLSLocationMap（`ob_ls_location_map.h`）

存储结构：256（1<<8）个哈希桶，每个桶一个锁。

```cpp
class ObLSLocationMap
{
  static const int64_t BUCKETS_CNT = 1 << 8;  // 256
  ObLSLocation **ls_buckets_;
  common::ObQSyncLock *buckets_lock_;
};
```

相比 ObTabletLSMap 的 64K 桶，这里只有 256 个桶——因为 **LS 的数量远少于 Tablet 的数量**。一个租户的 LS 数量通常是个位数到百位级别，而 Tablet 可以到百万级别。

#### update() 的逻辑（`ob_ls_location_map.cpp:110-157`）

`ObLSLocationMap::update()` 有一个关键约束：`from_rpc` 参数决定了 Leader 信息的合并方向：

```cpp
// from_rpc = true:  用 RPC 检测到的 Leader（信任度高）覆盖缓存
// from_rpc = false: 保留缓存中的 Leader（SQL 查回的副本信息可能滞后）
int ObLSLocationMap::update(const bool from_rpc, ...) {
  if (curr->get_cache_key() == key) {
    if (from_rpc) {
      // RPC 来源：将 RPC 获得的 Leader merge 到缓存条目
      curr->merge_leader_from(ls_location);
    } else {
      // SQL 来源：将缓存中的 Leader merge 回 SQL 查到的 location
      ls_location.merge_leader_from(*curr);
      curr->deep_copy(ls_location);
    }
  } else {
    // 插入新条目
  }
}
```

**设计意图**：RPC 刷新的是 Leader 信息，不覆盖完整副本列表；SQL 刷新的是完整副本列表，但保留已确认的 Leader。

#### 查询路径

`ObLSLocationService::get_leader()`（`ob_ls_location_service.cpp:302-330`）：

```
get_leader(cluster_id, tenant_id, ls_id, force_renew)
  │
  └─ get(cluster_id, tenant_id, ls_id, expire_renew_time, ...)
      │
      ├─ get_from_cache_() → ObLSLocationMap::get()
      │   ├── 命中且 renew_time > expire_renew_time → 返回
      │   └── 未命中或过期 → renew_location_()
      │
      └─ renew_location_() → batch_renew_ls_locations()
          └── ObLSTableOperator::get_by_ls() 查询 __all_ls_meta_table
              → fill_location_() 填充 ObLSLocation
              → update_cache_() 写入 ObLSLocationMap
```

### 2.3 两层缓存的设计原因

为什么需要两层（Tablet→LS + LS→Leader），而不是用 tablet_id 直接查到 Leader 地址？

**原因 1：映射变化频率不同**

| 映射 | 变化频率 | 变化原因 |
|------|---------|---------|
| Tablet → LS | 低（小时/天级） | Schema 变更、分区迁移、负载均衡 |
| LS → Leader | 高（秒/分级） | Leader 切换、选举、宕机恢复 |

将高频变化（LS Leader）和低频变化（Tablet→LS 隶属关系）解耦，避免 Tablet 缓存在 Leader 切换时大面积失效。

**原因 2：缓存复用**

- LS Leader 查询是多对一的：同属一个 LS 的所有 Tablet 共享同一个 LS 位置缓存
- 如果 tablet_id → leader_addr 直接缓存，每个 Tablet 都要独立刷新 Leader，批量查询时需要多次查表

**原因 3：批量操作的效率**

`batch_renew_ls_locations()` 可以一次 SQL 查回一个 tenant 所有 LS 的位置，然后批量更新缓存。如果需要逐 tablet 查 leader，网络开销大得多。

---

## 3. 缓存刷新机制

位置缓存的核心矛盾：**缓存越新，查询越快；但刷新太频繁，系统表压力大。** OceanBase 通过多级刷新机制来处理这个矛盾。

### 3.1 刷新触发器一览

```
┌──────────────────────────────────────────────────┐
│                 缓存刷新触发                       │
├────────────────┬─────────────────────────────────┤
│ 触发方式        │ 说明                            │
├────────────────┼─────────────────────────────────┤
│ 同步刷新        │ get() 时缓存未命中或过期，       │
│ (get中的fallback)│ 阻塞等待 Inner SQL 返回          │
├────────────────┼─────────────────────────────────┤
│ 异步刷新        │ nonblock_renew() → 提交任务到    │
│ (非阻塞)       │ UniqTaskQueue，后台线程处理       │
├────────────────┼─────────────────────────────────┤
│ 定时刷新        │ ObLSLocationTimerTask 每 5 秒    │
│ (TimerTask)    │ 自动刷新所有 LS 位置             │
├────────────────┼─────────────────────────────────┤
│ RPC Leader 刷新 │ ObLSLocationByRpcTimerTask       │
│                │ 每 1 秒通过 RPC 检测 Leader       │
├────────────────┼─────────────────────────────────┤
│ 广播刷新        │ Tablet 迁移完成后，源端广播       │
│ (Broadcast)    │ 新位置到所有 OBServer            │
└────────────────┴─────────────────────────────────┘
```

### 3.2 同步刷新（get 的 fallback 路径）

这是最常用的刷新路径。当 SQL 层调用 `get()` 发现缓存过期时，触发同步刷新：

```
ObTabletLSService::get()
  └── cache missed or expired
      └── renew_cache_()
          └── batch_renew_tablet_ls_cache()
              └── ObTabletToLSOperator 查询 __all_tablet_to_ls

ObLSLocationService::get()
  └── cache missed or expired
      └── renew_location_()
          └── batch_renew_ls_locations()
              └── ObLSTableOperator 查询 __all_ls_meta_table
```

刷新超时由 `location_cache_refresh_sql_timeout` GCONF 控制（`ob_tablet_ls_service.cpp:455`）：

```cpp
int ObTabletLSService::set_timeout_ctx_(common::ObTimeoutCtx &ctx)
{
  const int64_t default_timeout = GCONF.location_cache_refresh_sql_timeout;
  ObShareUtil::set_default_timeout_ctx(ctx, default_timeout);
}
```

### 3.3 异步刷新（UniqTaskQueue）

当调用 `nonblock_renew()` 时，仅提交一个 `ObTabletLSUpdateTask` 或 `ObLSLocationUpdateTask` 到后台队列，不阻塞当前线程。

**ObTabletLSUpdateTask**（`ob_location_update_task.h:81-108`）：
- 按 tenant_id 分 group（`get_group_id()`）
- 需要 `is_valid()` 检查
- `compare_without_version()` 保证去重——同一个 tablet 在队列中不会重复

**队列分层**（`ob_ls_location_service.h:57-80`）：

```cpp
class ObLSLocationUpdateQueueSet {
  ObLSLocUpdateQueue sys_tenant_queue_;    // 系统租户：高优先级，1 个线程
  ObLSLocUpdateQueue meta_tenant_queue_;   // 元租户：中优先级，1 个线程
  ObLSLocUpdateQueue user_tenant_queue_;   // 用户租户：可配置线程数
  // 线程数由 GCONF.location_refresh_thread_count 控制
};
```

优先级分层确保系统租户的 LS 位置不被用户租户的刷新任务淹没。

### 3.4 定时刷新（TimerTask）

**ObLSLocationTimerTask**（`ob_location_update_task.h:122-126`）：
- 每 5 秒执行一次
- 调用 `renew_all_ls_locations()` → 遍历所有租户 → 调用 `renew_location_for_tenant()` → 从 `__all_ls_meta_table` 全量刷新
- 需要等待 `sys_tenant_schema_ready`（`ob_ls_location_service.cpp:682-690`）

```cpp
// ob_ls_location_service.cpp:682
int ObLSLocationService::renew_all_ls_locations()
{
  // 1. 检查 sys tenant schema 是否就绪
  // 2. 遍历所有租户
  // 3. 每个租户调用 renew_location_for_tenant()
  // 4. 尝试清理已删除租户的过期缓存
}
```

**ObLSLocationByRpcTimerTask**（`ob_location_update_task.h:129-133`）：
- 每 1 秒执行一次
- 调用 `renew_all_ls_locations_by_rpc()` → 向集群所有节点发送 RPC → 收集 LS Leader 信息
- 比 SQL 刷新更快、更轻量

```cpp
// ob_ls_location_service.cpp:735
int ObLSLocationService::renew_all_ls_locations_by_rpc()
{
  // 1. construct_rpc_dests_(): 收集 RS 列表 + 所有活跃节点
  // 2. detect_ls_leaders_(): 通过 ObGetLeaderLocationsProxy 向目标节点发送 RPC
  // 3. 对返回的 Leader 信息，调用 inner_cache_.update(from_rpc=true, ...)
}
```

**定时刷新与 Leader 检测**是两个不同的策略，前者保证缓存随系统表更新，后者快速感知 Leader 切换。

**ObClearTabletLSCacheTimerTask**（`ob_location_update_task.h:148-152`）：
- 每 6 小时执行一次
- 清理已删除租户的过期缓存条目

### 3.5 广播刷新（Tablet 迁移场景）

**ObTabletLocationBroadcastTask**（`ob_location_update_task.h:155-191`）：当 Tablet 发生迁移时，系统需要通知所有节点更新缓存。

两个角色：

1. **ObTabletLocationSender**（`ob_tablet_location_broadcast.h:105-130`）：
   - 发送端：向所有节点 RPC 广播新的位置信息
   - 限流控制：`TabletLocationRateLimit` 按频率控制
   - 统计跟踪：`TabletLocationStatistics` 记录成功/失败次数

2. **ObTabletLocationUpdater**（`ob_tablet_location_broadcast.h:133-154`）：
   - 接收端：收到广播后将位置更新写入 `ObTabletLSMap`
   - 每个节点一个

```cpp
// ob_tablet_location_broadcast.h:156-162
RPC_F(obrpc::OB_TABLET_LOCATION_BROADCAST,
      obrpc::ObTabletLocationSendArg,
      obrpc::ObTabletLocationSendResult,
      ObTabletLocationSendProxy);
```

广播的触发点（`ob_location_service.h:152-153`）：

```cpp
int submit_tablet_broadcast_task(const ObTabletLocationBroadcastTask &task);
int submit_tablet_update_task(const ObTabletLocationBroadcastTask &task);
```

### 3.6 自动刷新服务（ObTabletLocationRefreshService）

`ObTabletLocationRefreshService`（`ob_tablet_location_refresh_service.h:93-128`）是一个常驻后台线程，用于在大规模 `transfer` 操作后自动刷新缓存。

继承自 `ObRsReentrantThread`，设计文档位于 `rootservice/di76sdhof1h97har#p34dp`。

核心循环 `run3()`：

```cpp
// ob_tablet_location_refresh_service.h:106
virtual void run3() override;
  // 1. 检查停止标志
  // 2. 刷新缓存（refresh_cache_）
  //     ├── 遍历所有租户
  //     ├── try_reload_tablet_cache_(): 从系统表重载 tablet→LS 映射
  //     └── fetch_inc_task_infos_and_update_(): 处理增量迁移任务
  // 3. idle_(): 空闲等待（默认 10 分钟，快速模式 1 分钟）
```

---

## 4. 缓存过期策略

### 4.1 时间戳比较

每个缓存条目记录 `renew_time_`（`ob_ls_location_service.cpp:274-280`）：

```cpp
if (OB_CACHE_NOT_HIT == ret
    || location.get_renew_time() <= expire_renew_time) {
  // 缓存过期或未命中 → 刷新
  renew_location_(cluster_id, tenant_id, ls_id, location);
} else {
  is_cache_hit = true;  // 缓存有效
}
```

`expire_renew_time` 由用户传入。典型值：
- `0`：永远不会过期，仅查缓存（弱一致性）
- `INT64_MAX`：强制刷新
- 其他值：缓存版本旧于这个时间就刷新

### 4.2 死缓存清理

`ObLSLocationMap` 支持检测"死缓存"——长时间未被访问的 LS 位置条目（`ob_ls_location_map.cpp:183-200`）：

```cpp
int ObLSLocationMap::check_and_generate_dead_cache(ObLSLocationArray &arr)
{
  // 遍历所有桶，找到 last_access_ts_ 超过 10 分钟的条目
  // 放入 arr 返回后，由调用方决定是否删除
}

int ObLSLocationMap::del(const ObLSLocationCacheKey &key, const int64_t safe_delete_time)
{
  // 如果当前时间 - renew_time <= safe_delete_time，拒绝删除（OB_NEED_WAIT）
  // 这是防止刚检测到的 Leader 信息被误删
}
```

清理触发频率：`CLEAR_CACHE_INTERVAL = 60 * 1000 * 1000L = 1 分钟`（`ob_ls_location_service.h:104`）。

### 4.3 Tablet 迁移的版本控制

Tablet 迁移时，`ObTabletLSCache` 中的 `transfer_seq_` 字段用于检测陈旧缓存：

迁移流程：
```
1. 源端开启迁移 → Task ID 分配
2. 目的端准备完成
3. 数据同步结束 → 广播新位置
4. 各节点更新 ObTabletLSMap
5. transfer_seq_ 递增 → 旧缓存自然过期
```

---

## 5. 缓存未命中与 Leader 重试

### 5.1 基本重试

`get_leader_with_retry_until_timeout()`（`ob_ls_location_service.cpp:316-395`）是 Leader 获取的重试逻辑：

```cpp
int ObLSLocationService::get_leader_with_retry_until_timeout(...)
{
  do {
    // 尝试 nonblock_get_leader（仅查缓存）
    if (is_location_service_renew_error(ret)) {
      // 可重试的错误 → 提交异步刷新
      nonblock_renew(cluster_id, tenant_id, ls_id);
      // 检查超时 → 未超时则 sleep(retry_interval) 后重试
      ob_usleep(retry_interval); // 默认 100ms
    }
  } while (is_location_service_renew_error(ret));
}
```

**超时来源**：
1. 显式传入的 `abs_retry_timeout`
2. `ObTimeoutCtx` 或 `THIS_WORKER` 的剩余超时时间
3. 默认值：`location_cache_refresh_sql_timeout`（`ob_ls_location_service.cpp:330`）

### 5.2 DAS Location Router 的重试

`ObDASLocationRouter`（`ob_das_location_router.h:376-460`）在 DAS 执行层维护重试计数器：

```cpp
// ob_das_location_router.h:452-454
class ObDASLocationRouter {
  int last_errno_;              // 最近一次错误
  int cur_errno_;               // 当前错误
  int64_t history_retry_cnt_;   // 历史重试次数
  int64_t cur_retry_cnt_;       // 当前重试轮次计数
  
  void save_cur_exec_status(int err_no);  // 保存当前 DAS 执行状态
  void force_refresh_location_cache(bool is_nonblock, int err_no);
  void refresh_location_cache_by_errno(bool is_nonblock, int err_no);
  int block_renew_tablet_location(const ObTabletID &tablet_id, ObLSLocation &ls_loc);
};
```

DAS 路由的关键方法 `nonblock_get_candi_tablet_locations()`（`ob_das_location_router.h:379`）整合了两层缓存查询：先查 Tablet→LS 映射，再查 LS→Leader。

### 5.3 错误驱动的缓存刷新

`refresh_location_cache_by_errno()` 根据错误码决定刷新策略：

```cpp
// ob_location_service.cpp:401-416
int ObLocationService::batch_renew_tablet_locations(...)
{
  // 根据 error_code 生成 RenewType：
  //   DEFAULT_RENEW_BOTH = 0          → 刷新两层缓存
  //   ONLY_RENEW_TABLET_LS_MAPPING = 1 → 只刷新 Tablet→LS
  //   ONLY_RENEW_LS_LOCATION = 2      → 只刷新 LS→Leader
  RenewType renew_type = gen_renew_type_(error_code);
}
```

这种**错误驱动的增量刷新**避免大面积缓存全量刷新。

---

## 6. DAS 路由集成

`ObDASLocationRouter`（`ob_das_location_router.h:370-460`）是 SQL 执行层与位置缓存之间的桥梁。

### 6.1 核心方法

```
nonblock_get_candi_tablet_locations(loc_meta, tablet_ids, partition_ids, ...)
  │
  ├→ 对每个 (tablet_id, partition_id)
  │   │
  │   ├→ nonblock_get_candi_tablet_location()
  │   │   │
  │   │   ├→ nonblock_get(loc_meta, tablet_id, ls_location)
  │   │   │   ├── 普通表: ObLocationService::nonblock_get() → tablet_id → ls_id
  │   │   │   │           ObLocationService::nonblock_get_leader() → ls_id → leader_addr
  │   │   │   └── 虚拟表: get_vt_ls_location() → 从 VirtualSvrPair 获取
  │   │   │
  │   │   └→ 构造 ObCandiTabletLoc (包含 tablet_id, server_addr, ls_id)
  │   │
  │   └→ 返回候选位置列表
  │
  └→ 执行器根据候选位置分发 DAS 任务
```

### 6.2 DAS 查询的另一条路径：nonblock_get_readable_replica

对于弱一致性读（weak_read），DAS 可以路由到 Followers：

```cpp
// ob_das_location_router.h:439-442
int nonblock_get_readable_replica(
    const uint64_t tenant_id,
    const ObTabletID &tablet_id,
    ObDASTabletLoc &tablet_loc,
    const bool is_weak_read,
    const ObRoutePolicyType route_policy);
```

这允许在 Leader 宕机时从 Follower 读取，而不必经 Leader 转发。

### 6.3 DAS 的虚拟表位置处理

对于 `__all_virtual_*` 等性能视图，位置信息不存储在系统表中，而是通过 `VirtualSvrPair` 管理：

```cpp
// ob_das_location_router.h:48-66
class VirtualSvrPair {
  uint64_t table_id_;
  AddrArray all_server_;  // 所有存活节点

  int get_server_by_tablet_id(const ObTabletID &tablet_id, ObAddr &addr) const;
  // 虚拟表的所有 tablet 分布在所有 server 上
};
```

---

## 7. 关键数据流图

```
SQL 查询到达
    │
    ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. ObDASTabletMapper::get_tablet_and_object_id()             │
│    分区键 → ObTabletID (根据分区函数计算)                     │
└────────────────────────────────┬─────────────────────────────┘
                                 │ tablet_id
                                 ▼
┌──────────────────────────────────────────────────────────────┐
│ 2. ObDASLocationRouter::nonblock_get_candi_tablet_locations() │
│    ┌──────────────────────────────────┐                      │
│    │ 2a. nonblock_get(loc_meta,       │                      │
│    │        tablet_id, ls_location)    │                      │
│    │    ┌────────────────────┐        │                      │
│    │    │ ObLocationService::│        │                      │
│    │    │ nonblock_get()     │        │                      │
│    │    │ → ObTabletLSService│        │                      │
│    │    │   :: nonblock_get()│        │                      │
│    │    │   → ObTabletLSMap  │        │                      │
│    │    │   → ls_id         │        │                      │
│    │    └────────┬───────────┘        │                      │
│    │             │  ls_id             │                      │
│    │             ▼                    │                      │
│    │    ┌────────────────────┐        │                      │
│    │    │ ObLocationService::│        │                      │
│    │    │ nonblock_get_leader│        │                      │
│    │    │ ()                 │        │                      │
│    │    │ → ObLSLocation     │        │                      │
│    │    │   Service::        │        │                      │
│    │    │   nonblock_get_    │        │                      │
│    │    │   leader()         │        │                      │
│    │    │ → ObLSLocationMap  │        │                      │
│    │    │ → ObAddr(leader)   │        │                      │
│    │    └────────┬───────────┘        │                      │
│    └─────────────┼────────────────────┘                      │
│                  │ leader_addr + ls_id                       │
│                  ▼                                            │
│    ObCandiTabletLoc { tablet_id, ls_id, server_addr }         │
└────────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
┌──────────────────────────────────────────────────────────────┐
│ 3. ObDASCtx 收集所有 ObCandiTabletLoc                       │
│    按 server_addr 分组                                        │
│    构造 DAS RPC 请求                                          │
└────────────────────────────────┬─────────────────────────────┘
                                 │
                                 ▼
┌──────────────────────────────────────────────────────────────┐
│ 4. DAS RPC 发送到目标 OBServer                               │
│    目标 OBServer 执行 DML/Scan                               │
│    ┌────────────────┐  ┌────────────────┐                   │
│    │ ObDMLService   │  │ ObTableScan    │                   │
│    │ (INSERT/UPDATE │  │ (SELECT)       │                   │
│    │  /DELETE)      │  │                │                   │
│    └────────────────┘  └────────────────┘                   │
└──────────────────────────────────────────────────────────────┘
```

### 缓存未命中 → 刷新路径

```
nonblock_get() 缓存未命中 (OB_CACHE_NOT_HIT)
    │
    ▼ (在 DAS 重试层)
force_refresh_location_cache()
    │
    ├→ ObLocationService::renew_tablet_location() (同步: block_renew)
    │   │
    │   ├→ ObTabletLSService::batch_renew_tablet_ls_cache()
    │   │   └── ObTabletToLSOperator (Inner SQL: __all_tablet_to_ls)
    │   │
    │   ├→ ObLSLocationService::batch_renew_ls_locations()
    │   │   └── ObLSTableOperator (Inner SQL: __all_ls_meta_table)
    │   │
    │   └→ 缓存写回 ObTabletLSMap + ObLSLocationMap
    │
    └→ 重试 nonblock_get()
```

---

## 8. 设计决策总结

### 8.1 为什么两层缓存是必要的？

**备选方案**：Tablet → Leader 的直连缓存。

**OceanBase 的选择**：两层分解（Tablet → LS → Leader）。

**理由**：
- **变化频率解耦**：Leader 切换不影响 Tablet→LS 映射
- **批量查询效率**：一次 SQL 可批量刷新整个 tenant 的 LS 位置，覆盖数百万个 Tablet
- **缓存体积控制**：LS 数量远少于 Tablet，LS 缓存更易维护

### 8.2 为什么 ObLSLocationMap 只有 256 个桶？

而 ObTabletLSMap 有 64K 个桶。

因为 **Tablet 数量和 LS 数量差四个数量级**。一个 OBServer 上的 Tablet 数量可达百万级，而 LS 数量通常不过百。256 个桶搭配链表，冲突可控且内存占用小。

### 8.3 为什么需要 RPC 和 SQL 两套刷新机制？

| 刷新方式 | 数据来源 | 频率 | 延迟 | 覆盖范围 |
|---------|---------|------|------|---------|
| SQL 刷新 | `__all_ls_meta_table` | 5 秒 | 较高 | 全部副本信息 |
| RPC 刷新 | 直接问其他 OBServer | 1 秒 | 低 | 仅 Leader 信息 |

**SQL 刷新**返回完整的副本列表（Leader + Followers），但系统表查询耗时。
**RPC 刷新**更轻量，只检测 Leader，适合快速响应切换。

### 8.4 为什么 get_leader 使用"重试-直到超时"模式？

对于 `get_leader_with_retry_until_timeout()`（`ob_ls_location_service.cpp:316`），在 Leader 刚切换后，缓存尚未更新，同步重试是最可靠的 Fallback：

```cpp
do {
  nonblock_get_leader(...)  // 查缓存
  if (无Leader或缓存未命中) {
    nonblock_renew(...)     // 提交异步刷新
    ob_usleep(retry_interval) // 默认 100ms
  }
} while (未超时 && 错误可重试);
```

选择"重试直到超时"而不是"直接返回错误"的原因：
- OceanBase 的 Paxos 选举通常能在秒级完成，短时间重试大概率能命中
- 用户请求的超时时间通常数秒，重试窗口足够长
- 提前返回"LS 不存在"给用户会让应用层编写复杂的重试逻辑（每个应用都要写一遍）

### 8.5 为什么使用 UniqTaskQueue 而不是线程池？

`ObUniqTaskQueue` 保证相同 key 的任务不会被重复入队：

```cpp
// ob_tablet_ls_service.cpp:342
async_queue_.add(task);
// 如果 task (tenant_id, tablet_id) 已存在，返回 OB_EAGAIN
// 调用方将 OB_EAGAIN 视为成功（已有任务在排队）
```

这对位置刷新特别重要：当大量请求同时发现同一个 tablet 的缓存过期时，**只需要一个刷新任务**在队列中，所有请求等这个任务完成就好，不需要每个请求都发起 SQL 查询。

### 8.6 Stale Read 与位置缓存的交互

弱一致性读（Stale Read / Weak Read）可以接受稍旧的数据，因此：

- **非阻塞优先**：Stale Read 调用 `nonblock_get_readable_replica()`，只查缓存，不触发刷新
- **可路由到 Follower**：弱读不需要读 Leader，只要有合法的副本列表就可以
- **Leader 不可用的容忍度更高**：强读如果没有 Leader 会触发重试；弱读可以优雅降级到 Follower

```cpp
// ob_das_location_router.h:439
int nonblock_get_readable_replica(
    const uint64_t tenant_id,
    const ObTabletID &tablet_id,
    ObDASTabletLoc &tablet_loc,
    const bool is_weak_read,          // ← 弱读标志
    const ObRoutePolicyType route_policy);
```

---

## 9. 源码文件索引

### 9.1 位置服务主入口

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/share/location_cache/ob_location_service.h` | `class ObLocationService` | 37 |
| `src/share/location_cache/ob_location_service.h` | `get()` (LS 位置) | 51 |
| `src/share/location_cache/ob_location_service.h` | `get_leader()` | 71 |
| `src/share/location_cache/ob_location_service.h` | `get()` (Tablet→LS) | 108 |
| `src/share/location_cache/ob_location_service.h` | `batch_renew_tablet_locations()` | 137 |
| `src/share/location_cache/ob_location_service.h` | `gen_renew_type_()` | 247 |
| `src/share/location_cache/ob_location_service.cpp` | `init()` | 350 |

### 9.2 LS 位置服务

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/share/location_cache/ob_ls_location_service.h` | `class ObLSLocationService` | 86 |
| `src/share/location_cache/ob_ls_location_service.h` | `ObLSLocationUpdateQueueSet` | 57 |
| `src/share/location_cache/ob_ls_location_service.h` | `get()` | 97 |
| `src/share/location_cache/ob_ls_location_service.h` | `get_leader()` | 113 |
| `src/share/location_cache/ob_ls_location_service.h` | `get_leader_with_retry_until_timeout()` | 123 |
| `src/share/location_cache/ob_ls_location_service.h` | `renew_all_ls_locations()` | 148 |
| `src/share/location_cache/ob_ls_location_service.h` | `renew_all_ls_locations_by_rpc()` | 150 |
| `src/share/location_cache/ob_ls_location_service.h` | 定时器间隔常量 | 102-105 |
| `src/share/location_cache/ob_ls_location_service.cpp` | `get()` 缓存命中判断 | 272 |
| `src/share/location_cache/ob_ls_location_service.cpp` | `get_leader_with_retry_until_timeout()` 重试循环 | 316 |
| `src/share/location_cache/ob_ls_location_service.cpp` | `renew_location_()` | 999 |
| `src/share/location_cache/ob_ls_location_service.cpp` | `fill_location_()` | 1027 |
| `src/share/location_cache/ob_ls_location_service.cpp` | `update_cache_()` | 1075 |
| `src/share/location_cache/ob_ls_location_service.cpp` | `batch_update_caches_()` | 926 |
| `src/share/location_cache/ob_ls_location_service.cpp` | `renew_all_ls_locations()` | 664 |
| `src/share/location_cache/ob_ls_location_service.cpp` | `renew_all_ls_locations_by_rpc()` | 735 |
| `src/share/location_cache/ob_ls_location_service.cpp` | `detect_ls_leaders_()` | 833 |
| `src/share/location_cache/ob_ls_location_service.cpp` | `check_and_clear_dead_cache()` | 598 |

### 9.3 Tablet → LS 映射

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/share/location_cache/ob_tablet_ls_service.h` | `class ObTabletLSService` | 48 |
| `src/share/location_cache/ob_tablet_ls_service.h` | `get()` | 63 |
| `src/share/location_cache/ob_tablet_ls_service.h` | `batch_renew_tablet_ls_cache()` | 97 |
| `src/share/location_cache/ob_tablet_ls_service.cpp` | `get()` 缓存命中判断 | 76 |
| `src/share/location_cache/ob_tablet_ls_service.cpp` | `renew_cache_()` | 375 |
| `src/share/location_cache/ob_tablet_ls_service.cpp` | `batch_renew_tablet_ls_cache()` | 474 |
| `src/share/location_cache/ob_tablet_ls_service.cpp` | `get_from_cache_()` | 334 |
| `src/share/location_cache/ob_tablet_ls_service.cpp` | `set_timeout_ctx_()` | 455 |

### 9.4 缓存存储层

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/share/location_cache/ob_ls_location_map.h` | `class ObLSLocationMap` | 63 |
| `src/share/location_cache/ob_ls_location_map.h` | BUCKETS_CNT = 256 | 78 |
| `src/share/location_cache/ob_ls_location_map.cpp` | `update()` (from_rpc 逻辑) | 110 |
| `src/share/location_cache/ob_ls_location_map.cpp` | `get()` | 159 |
| `src/share/location_cache/ob_ls_location_map.cpp` | `del()` | 192 |
| `src/share/location_cache/ob_ls_location_map.cpp` | `check_and_generate_dead_cache()` | 228 |
| `src/share/location_cache/ob_tablet_ls_map.h` | `class ObTabletLSMap` | 37 |
| `src/share/location_cache/ob_tablet_ls_map.h` | BUCKETS_CNT = 64K, LOCK_SLOT_CNT = 1K | 56-57 |
| `src/share/location_cache/ob_tablet_ls_map.h` | `for_each_and_delete_if()` | 73 |
| `src/share/location_cache/ob_tablet_ls_map.cpp` | `init()` | 29 |
| `src/share/location_cache/ob_tablet_ls_map.cpp` | `update()` | 101 |

### 9.5 位置数据结构

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/share/location_cache/ob_location_struct.h` | `ObLSReplicaLocation` | 29 |
| `src/share/location_cache/ob_location_struct.h` | `ObLSLocationCacheKey` | 75 |
| `src/share/location_cache/ob_location_struct.h` | `ObLSLeaderLocation` | 104 |
| `src/share/location_cache/ob_location_struct.h` | `ObLSLocation` | 113 |
| `src/share/location_cache/ob_location_struct.h` | `ObTabletLSKey` | 199 |
| `src/share/location_cache/ob_location_struct.h` | `ObTabletLSCache` | 218 |
| `src/share/location_cache/ob_location_struct.h` | `is_location_service_renew_error()` | 17 |
| `src/share/location_cache/ob_location_struct.h` | `ObLSExistState` | 241 |

### 9.6 刷新任务定义

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/share/location_cache/ob_location_update_task.h` | `ObLSLocationUpdateTask` | 30 |
| `src/share/location_cache/ob_location_update_task.h` | `ObTabletLSUpdateTask` | 81 |
| `src/share/location_cache/ob_location_update_task.h` | `ObLSLocationTimerTask` | 122 |
| `src/share/location_cache/ob_location_update_task.h` | `ObLSLocationByRpcTimerTask` | 129 |
| `src/share/location_cache/ob_location_update_task.h` | `ObTabletLocationBroadcastTask` | 155 |
| `src/share/location_cache/ob_location_update_task.h` | `ObClearTabletLSCacheTimerTask` | 148 |

### 9.7 广播机制

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/share/location_cache/ob_tablet_location_broadcast.h` | `ObTabletLocationSender` | 105 |
| `src/share/location_cache/ob_tablet_location_broadcast.h` | `ObTabletLocationUpdater` | 133 |
| `src/share/location_cache/ob_tablet_location_broadcast.h` | `TabletLocationRateLimit` | 70 |
| `src/share/location_cache/ob_tablet_location_broadcast.h` | `TabletLocationStatistics` | 44 |

### 9.8 自动刷新服务

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/share/location_cache/ob_tablet_location_refresh_service.h` | `ObTabletLocationRefreshService` | 93 |
| `src/share/location_cache/ob_tablet_location_refresh_service.h` | `ObTabletLocationRefreshMgr` | 37 |
| `src/share/location_cache/ob_tablet_location_refresh_service.h` | `ObTabletLocationRefreshServiceIdling` | 82 |

### 9.9 DAS 路由

| 文件 | 关键符号 | 行号 |
|------|---------|------|
| `src/sql/das/ob_das_location_router.h` | `ObDASLocationRouter` | 370 |
| `src/sql/das/ob_das_location_router.h` | `nonblock_get_candi_tablet_locations()` | 379 |
| `src/sql/das/ob_das_location_router.h` | `get_leader()` | 391 |
| `src/sql/das/ob_das_location_router.h` | `nonblock_get_readable_replica()` | 439 |
| `src/sql/das/ob_das_location_router.h` | `force_refresh_location_cache()` | 399 |
| `src/sql/das/ob_das_location_router.h` | `ObDASTabletMapper` | 157 |
| `src/sql/das/ob_das_location_router.h` | `VirtualSvrPair` | 48 |
| `src/sql/das/ob_das_location_router.h` | `DASRelatedTabletMap` | 70 |

---

## 10. 总结

OceanBase 的位置缓存系统是一个**两层、多级刷新、错误驱动**的分布式缓存子系统。

- **两层缓存**解耦了 Tablet→LS 的低频变化和 LS→Leader 的高频变化
- **多级刷新**提供了定时、按需、异步、广播四个维度的缓存更新
- **错误驱动刷新**避免了不必要的缓存失效
- **重试-直到超时**模式保证了分布式环境下 Leader 切换的平滑过渡

这个系统的设计理念贯穿 OceanBase 的分布式核心：**减少跨节点依赖，容忍中间状态，在正确性和可用性之间取平衡**。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-03 | 代码仓库：OceanBase CE | 主要分析路径：src/share/location_cache/（19 个文件）, src/sql/das/ob_das_location_router.h*
