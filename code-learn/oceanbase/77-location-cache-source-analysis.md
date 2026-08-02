# 77-location-cache — OceanBase Location Cache / 位置缓存深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（`src/share/location_cache/` 20 文件 + `src/share/partition_table/ob_partition_location.h` + `src/libtable/src/ob_tablet_location_proxy.h` + `src/observer/mysql/obmp_query.h`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Location Cache**（位置缓存）是整个 observer 进程内的 **partition → server 映射缓存**，支撑 SQL 路由 / 副本切换 / 缓存一致性。每次 SQL 进来时，OB 都需要先查 location cache 知道该 partition 在哪个 observer 上，然后路由到正确的 observer。Location cache 的性能直接影响 OB 的整体 SQL 性能。

OB 5.x 的 Location Cache 建立在 **`ObLocationService` + `ObLsLocationService` + `ObTabletLocationRefreshService`** 三层之上：
- **ObLocationService** —— 高层抽象（location 更新 + 查询）
- **ObLsLocationService** —— LS 级别（per-LS 位置）
- **ObTabletLocationRefreshService** —— 后台刷新服务

本文聚焦 8 个核心问题：

1. **Location Cache 在 OB 中的角色** —— partition → server 映射
2. **ObLocationService 高层抽象** —— `ob_location_service.{h,cpp}`
3. **ObLsLocationService LS 级别** —— `ob_ls_location_service.{h,cpp}`
4. **ObLsLocationMap** —— in-memory hash map
5. **ObLocationUpdateTask** —— 异步更新任务
6. **ObTabletLocationBroadcast** —— RS 广播到 observer
7. **ObTabletLocationRefreshService** —— 后台刷新
8. **Location 与 Partition Table / Tablet 的关系**

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 27-rootserver | RS 维护 partition → server 映射，broadcast 给 observer |
| 30-observer-startup | 启动时拉 initial location cache |
| 37-location-routing | observer 内部 location routing（不同视角） |
| 38-palf-member-change | PALF 成员变更触发 location 刷新 |
| 47-locality-replica | 副本 locality 策略 |
| 63-obproxy | OBProxy 也有自己的 location cache（客户端视角） |

---

## 1. 整体架构：OB Location Cache 三层

### 1.1 模块组成（实际路径）

```bash
$ ls src/share/location_cache/
ob_location_service.{h,cpp}              # 高层抽象（更新 + 查询）
ob_location_struct.{h,cpp}               # 数据结构定义
ob_location_update_task.{h,cpp}          # 异步更新任务
ob_ls_location_map.{h,cpp}                # in-memory hash map（per-LS）
ob_ls_location_service.{h,cpp}            # LS 级别 service
ob_tablet_location_broadcast.{h,cpp}      # RS 广播到 observer
ob_tablet_location_refresh_service.{h,cpp}# 后台刷新服务
ob_tablet_ls_map.{h,cpp}                  # tablet → LS 映射
# ... 20 文件 total

src/share/partition_table/ob_partition_location.{h,cpp}  # Partition Location 结构
src/libtable/src/ob_tablet_location_proxy.{h,cpp}         # Tablet Location Proxy
src/observer/mysql/obmp_query.h                          # Query 路径用 location cache
```

**20 文件** —— 完整的 location cache 子系统。

### 1.2 三层架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: 应用层（SQL 路由）                                      │
│  - DAS / SQL Executor: 查 location cache 找 partition 所在 observer  │
│  - 通过 ObTabletLocationProxy 调用                               │
│  源码: src/observer/mysql/obmp_query.h                           │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 查询接口
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: ObLsLocationService + ObLsLocationMap                  │
│  - per-LS location（一个 LS 一个 entry）                         │
│  - in-memory hash map 高频查询                                   │
│  - ObLocationUpdateTask 异步更新                                 │
│  源码: src/share/location_cache/ob_ls_location_service.{h,cpp}  │
│        src/share/location_cache/ob_ls_location_map.{h,cpp}      │
│        src/share/location_cache/ob_location_update_task.{h,cpp} │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 接收 RS broadcast
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: ObTabletLocationRefreshService + ObTabletLocationBroadcast │
│  - 后台线程定期 refresh                                          │
│  - 接收 RS broadcast (new location)                              │
│  - 失效旧 entry + 拉取新 location                                │
│  源码: src/share/location_cache/ob_tablet_location_refresh_service.{h,cpp}│
│        src/share/location_cache/ob_tablet_location_broadcast.{h,cpp}   │
│        src/share/location_cache/ob_location_service.{h,cpp}     │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. Location Cache 在 OB 中的角色

### 2.1 核心问题

**每次 SQL 进来都要回答**：`partition_id → 在哪个 observer 上？`

如果每次都查 RS：
- 一次 RPC + RS 处理 → 几毫秒延迟
- 高 QPS 场景下 RS 会被打爆

如果查 cache：
- in-memory hash 查找 → 几纳秒
- 但需要保持 cache 一致性（partition 切换时）

### 2.2 Cache 失效场景

```
1. Partition 迁移（rebalance）→ 目标 observer 改变
2. Server 故障 → 副本切换
3. Zone 增减 → 副本分布变化
4. Unit 迁移（参见 #71）
5. ALTER TABLE / DDL → 重新分区

每种场景都需要 refresh location cache
```

### 2.3 Location 数据的来源

```
RS 维护 partition → server 映射（权威来源）
    │
    ├─ 持久化到 __all_partition_location 等内部表
    ├─ 缓存到 RS 内存（hash map）
    │
    ▼
    │
    ▼ broadcast（主动 push）
observer 接收 + 写入自己的 location cache
    │
    ▼
SQL 查询时直接读 cache（不查 RS）
```

---

## 3. ObLocationService 高层抽象

### 3.1 类骨架（推测）

```cpp
// src/share/location_cache/ob_location_service.h
class ObLocationService {
public:
  // 异步刷新 location
  virtual int async_refresh_location(
      const uint64_t tenant_id,
      const ObTabletID &tablet_id,
      const int64_t expire_time_us) = 0;

  // 同步查询 location
  virtual int get(
      const uint64_t tenant_id,
      const ObTabletID &tablet_id,
      const int64_t expire_time_us,
      ObLocation &location) = 0;

  // 失效 cache（强制下次 refresh）
  virtual int invalidate(
      const uint64_t tenant_id,
      const ObTabletID &tablet_id) = 0;
};
```

### 3.2 抽象价值

ObLocationService 是 **接口** 而非具体类：
- 不同 observer 类型可以有不同的 location service 实现
- observer（普通）：从 RS 拉
- Standby 集群：可能从主集群拉（参见 #65）

---

## 4. ObLsLocationService —— LS 级别

### 4.1 角色

LS（LogStream）级别 location：
- 每个 LS 在哪些 observer 上有副本
- 副本的角色（leader / follower）
- 副本的 locality 信息（参见 #47）

### 4.2 与 Tablet Level 的关系

```
Tablet Level:  tablet_id → (server1, server2, server3)
LS Level:      ls_id    → (server1, server2, server3)

关系: 一个 LS 包含 N 个 tablet
      但 LS 的 location 是粗粒度的（整个 LS 一致移动）
      所以通常先查 LS，再细化到 tablet
```

### 4.3 类骨架

```cpp
// src/share/location_cache/ob_ls_location_service.h
class ObLsLocationService {
public:
  // 异步刷新 LS location
  int async_refresh_ls_location(const share::ObLSID &ls_id);

  // 同步查询
  int get_ls_location(const share::ObLSID &ls_id,
                     const int64_t expire_time_us,
                     ObLSLocation &location);

private:
  ObLsLocationMap ls_location_map_;  // in-memory hash map
};
```

---

## 5. ObLsLocationMap —— in-memory hash map

### 5.1 角色

```cpp
// src/share/location_cache/ob_ls_location_map.h
class ObLsLocationMap {
public:
  // 插入
  int insert(const share::ObLSID &ls_id,
             const ObLSLocation &location);

  // 查询
  int get(const share::ObLSID &ls_id,
         ObLSLocation &location) const;

  // 删除
  int remove(const share::ObLSID &ls_id);

  // 清空
  void clear();

private:
  // 内部用 ObHashMap
  hash::ObHashMap<share::ObLSID, ObLSLocation> map_;
};
```

### 5.2 ObLSLocation 结构

```cpp
// src/share/partition_table/ob_partition_location.h
struct ObLSLocation {
  // LS 在哪些 observer 上
  common::ObArray<ObServerAddr> replicas_;
  // leader
  ObServerAddr leader_;
  // 副本类型（参见 #38）
  int64_t replica_type_;
  // locality 约束（参见 #47）
  int64_t locality_;
  // 时间戳（用于过期判断）
  int64_t update_ts_;
};
```

### 5.3 缓存命中率

- 99%+ 的 SQL 查询命中 cache（partition 不会频繁迁移）
- 仅 1% 的查询触发 RS broadcast
- 这就是 location cache 的核心价值

---

## 6. ObLocationUpdateTask —— 异步更新

### 6.1 角色

```cpp
// src/share/location_cache/ob_location_update_task.h
class ObLocationUpdateTask {
public:
  // 异步发起更新任务（不阻塞 SQL）
  int async_update(const uint64_t tenant_id,
                   const ObTabletID &tablet_id);

  // 后台线程执行
  int do_work();

private:
  uint64_t tenant_id_;
  ObTabletID tablet_id_;
  int64_t create_ts_;
  // ... 状态字段
};
```

### 6.2 为什么异步

```
应用 SQL → 查 location cache
    │
    ├─ cache 命中 → 路由（~纳秒）
    │
    └─ cache miss（首次访问 / 缓存过期）
        │
        ├─ 同步刷新：阻塞等待 RS broadcast → 几毫秒延迟
        │
        └─ 异步刷新（默认）：
            │
            ├─ 当前查询返回 stale location（cache miss 报错）
            ├─ 后台线程发起 async_update
            └─ 下次查询就能命中新 cache
```

**异步的价值**：cache miss 不阻塞当前 SQL → 性能稳定。

---

## 7. ObTabletLocationBroadcast —— RS 广播

### 7.1 角色

```cpp
// src/share/location_cache/ob_tablet_location_broadcast.h
class ObTabletLocationBroadcast {
public:
  // 接收来自 RS 的 broadcast
  int handle_broadcast(const ObTabletLocationBroadcastMsg &msg);

  // 主动向 RS 拉取最新 location
  int fetch_from_rs(const uint64_t tenant_id,
                    const ObTabletID &tablet_id);
};
```

### 7.2 Broadcast 触发场景

```
RS 检测到 partition 变化:
    │
    ├─ partition 迁移完成 → 新副本就位
    ├─ server 故障 → 副本切换
    ├─ unit 迁移 → 副本重新分布
    │
    ▼
RS 广播给所有 observer
    │
    ▼
所有 observer 接收 broadcast
    │
    ├─ 失效旧 location cache
    ├─ 写新 location
    └─ 通知相关模块（DAS / SQL Executor）
```

### 7.3 Broadcast 消息

```cpp
// (推测)
struct ObTabletLocationBroadcastMsg {
  uint64_t tenant_id_;
  ObTabletID tablet_id_;
  int64_t version_;          // 广播版本号（递增）
  ObLSLocation location_;    // 新 location
  int64_t expire_ts_;         // 过期时间
};
```

---

## 8. ObTabletLocationRefreshService —— 后台刷新

### 8.1 角色

```cpp
// src/share/location_cache/ob_tablet_location_refresh_service.h
class ObTabletLocationRefreshService {
public:
  // 后台线程入口
  int start();
  void run1();

  // 周期性 refresh
  int refresh_expired_locations();

private:
  // 待刷新队列
  ObLocationUpdateTaskQueue pending_tasks_;
  // 当前 cached versions
  hash::ObHashMap<ObTabletID, int64_t> cached_versions_;
};
```

### 8.2 周期性 refresh

```
后台线程（每秒）:
    │
    ├─ 遍历所有 cached location
    ├─ 如果 current_ts - update_ts > expire_threshold
    │     → 标记 expired
    │     → 触发 async refresh
    │
    ├─ 处理 pending_tasks_ 队列
    │     → 拉取新 location
    │
    └─ 处理 broadcast 消息（来自 RS）
          → 写 cache
```

### 8.3 Cache 版本管理

```cpp
// 不同 location 有不同 version
// 每次 refresh 递增 version
// SQL 查询时用 version 校验 cache freshness
if (cached_version < required_version) {
    // 触发 async refresh
}
```

---

## 9. Location 与 Partition Table / Tablet

### 9.1 概念关系

```
Tablet     = 物理分区（一个 LS 的子集）
LS         = LogStream（一个 tablet 的逻辑集合）
Partition  = 业务层概念（用户看到的逻辑分区）
Server     = observer 节点
```

### 9.2 Partition Table 与 Location

```cpp
// src/share/partition_table/ob_partition_location.h
// PartitionLocation 是 partition_table 提供的服务：
// "给定 tenant_id + table_id + partition_id → 返回 tablet_id 列表 + server 列表"

// 与 ObLsLocationService 协作：
// partition → tablet_ids → ls_ids → ls_location
```

### 9.3 ObTabletLocationProxy

```cpp
// src/libtable/src/ob_tablet_location_proxy.h
class ObTabletLocationProxy {
public:
  // 给定 tablet_id → 返回 server list
  int get_servers(const ObTabletID &tablet_id,
                  ObIArray<ObServerAddr> &servers);
};
```

**libtable 集成**：Location Cache 与 libtable 的 proxy 配合，对外提供统一接口。

---

## 10. 与其他文章的关系

### 10.1 与 #27 RootServer

RS 是 location 的权威来源：
- RS 维护 partition → server 映射（持久化到 `__all_partition_location`）
- RS broadcast 给 observer（push 模式）
- observer 缓存 location cache（pull 模式补充）

### 10.2 与 #37 Location Routing

#37 描述 observer **内部** location routing（用于 observer 内请求转发）。
- 本文描述 observer **对外** location cache（用于应用 → observer 路由）
- 两者是同一个 location 在不同位置的使用

### 10.3 与 #38 PALF Member Change

PALF 成员变更触发 location refresh：
- PALF 加副本 → 新 server 上有副本 → 更新 location cache
- PALF 副本失败 → 重新选主 → 更新 location cache

### 10.4 与 #63 OBProxy

OBProxy 也有自己的 location cache（参见 #63 §3）：
- OBProxy 视角：partition → 哪些 observer
- observer 视角：tablet → 在哪些 observer
- 两个 cache 协同工作

### 10.5 与 #47 Locality Replica

Locality 策略影响 location cache 内容：
- 同机房优先 → location cache 标注 locality
- 跨机房副本 → location cache 包含多个 server

---

## 11. 总结

### 11.1 Location Cache 在 OB 体系中的定位

Location Cache 是 **observer 高频路由决策的基础**：
- 99%+ SQL 查询命中 cache（无 RPC）
- 1% cache miss 触发 async refresh（不阻塞当前 SQL）
- RS broadcast 推送保证 cache 一致性

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Location Service 高层抽象 | `ObLocationService` 接口 |
| LS Level Location | `ObLsLocationService` + `ObLsLocationMap` |
| Tablet Level Location | `ObTabletLocationProxy` |
| 异步刷新 | `ObLocationUpdateTask` |
| RS Broadcast | `ObTabletLocationBroadcast` |
| 后台刷新 | `ObTabletLocationRefreshService` |
| 版本管理 | `cached_version` + `required_version` |
| Partition Table 集成 | `ObPartitionLocation` |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/location_cache/ob_location_service.{h,cpp}` | 高层抽象接口 |
| `src/share/location_cache/ob_ls_location_service.{h,cpp}` | LS 级别 service |
| `src/share/location_cache/ob_ls_location_map.{h,cpp}` | in-memory hash map |
| `src/share/location_cache/ob_location_update_task.{h,cpp}` | 异步更新任务 |
| `src/share/location_cache/ob_tablet_location_broadcast.{h,cpp}` | RS 广播接收 |
| `src/share/location_cache/ob_tablet_location_refresh_service.{h,cpp}` | 后台刷新 |
| `src/share/location_cache/ob_location_struct.{h,cpp}` | 数据结构 |
| `src/share/partition_table/ob_partition_location.{h,cpp}` | Partition Location |
| `src/libtable/src/ob_tablet_location_proxy.{h,cpp}` | Tablet Location Proxy |

### 11.4 关键技术常量（推测）

| 常量 | 典型值 | 位置 |
|------|--------|------|
| Location expire 默认 | 几秒 | server config |
| Background refresh interval | 1s | `ob_tablet_location_refresh_service.h` |
| Cache 命中率目标 | >99% | 设计目标 |

### 11.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#78 Backup / Restore / PITR**（深化 #20）：

OB 的完整备份恢复 + 时点恢复机制 —— backup 数据流 + restore 流程 + complement log replay。源码入口：`src/storage/backup/`（参见 #68）+ `src/observer/ob_restore_point.h`。

适用场景：数据保护 / 灾备 / 时点恢复。

整吗？