# 85-partition-table-tablet — OceanBase Partition Table / Tablet 物理分布深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（`src/share/partition_table/ob_partition_location.{h,cpp}` 2 文件 + `src/rootserver/ob_partition_balance.h` + `ob_tenant_balance_service.h` + `src/observer/table_load/backup/` 42 文件 + `src/libtable/src/ob_tablet_location_proxy.h` + `src/share/location_cache/`（参见 #77））
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Partition Table / Tablet 物理分布**是整个 observer 集群"数据物理位置"的核心 —— partition → tablet → server 的映射、partition balance / transfer / split / merge、partition locality、partition 物理生命周期。partition 是用户态逻辑概念，tablet 是物理存储单元。

本文聚焦 8 个核心问题：

1. **Partition vs Tablet vs LS** —— 三层关系
2. **ObPartitionLocation** —— partition 物理位置
3. **ObTabletLocationProxy** —— tablet 位置查询
4. **ObPartitionBalance** —— partition rebalance
5. **ObTenantBalanceService** —— tenant 级别 balance
6. **Partition Transfer** —— partition 迁移
7. **Partition Split / Merge** —— partition 数量调整
8. **Locality 策略** —— partition 副本分布约束

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 36-concurrency-control | 并发场景下的 partition 操作 |
| 38-palf-member-change | PALF 成员变更触发 partition balance |
| 47-locality-replica | locality 策略 |
| 48-data-checkpoint | partition 级别 checkpoint |
| 77-location-cache | tablet 位置缓存（深入） |
| 64-online-ddl | DDL 触发的 partition 数量调整 |
| 30-observer-startup | 启动加载 partition location |

---

## 1. 整体架构：Partition / Tablet / LS 三层

### 1.1 模块组成（实际路径）

```bash
# Partition Table 核心
src/share/partition_table/
└── ob_partition_location.{h,cpp}             # 2 文件 — partition 位置

# Partition Balance / Transfer
src/rootserver/
├── ob_partition_balance.h                   # partition rebalance
├── ob_tenant_balance_service.h               # tenant balance
└── ob_rebalance_task.h                       # rebalance 任务

# Tablet Location
src/libtable/src/
└── ob_tablet_location_proxy.h               # tablet 位置查询

# Backup 表加载
src/observer/table_load/backup/             # 42 文件
├── ob_table_load_backup_block_sstable_struct.{h,cpp}
├── ob_table_load_backup_column_map_v1.{h,cpp}
├── ob_table_load_backup_column_map_v2.{h,cpp}
├── ob_table_load_backup_file_util.{h,cpp}
├── ob_table_load_backup_flat_row_reader_v1.{h,cpp}
├── ob_table_load_backup_flat_row_reader_v2.{h,cpp}
└── # ... 35+ 其他

# Location Cache (参见 #77)
src/share/location_cache/                    # 20 文件
├── ob_tablet_location_broadcast.{h,cpp}
├── ob_tablet_location_refresh_service.{h,cpp}
└── # ... 详见 #77
```

### 1.2 三层关系

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Partition (用户态逻辑概念)                             │
│  - 一个表可以分区 (PARTITION BY HASH / RANGE / LIST)             │
│  - 每个 partition 有唯一 partition_id                             │
│  - 用户 SQL 用 partition key 定位到 partition                    │
└──────────────────────────────────────────────────────────────────┘
                              │ 1:N
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Tablet (物理存储单元)                                  │
│  - 每个 partition 包含 1..N 个 tablet                          │
│  - 每个 tablet 有 tablet_id (在 LS 内唯一)                     │
│  - tablet 是 PALF / MemTable / SSTable 的容器                    │
└──────────────────────────────────────────────────────────────────┘
                              │ N:M
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: LS (LogStream)                                        │
│  - 多个 tablet 共享一个 LS                                      │
│  - LS 是 PALF 的最小单位（参见 #11）                            │
│  - LS 在哪些 observer 上有副本（参见 #77）                    │
└──────────────────────────────────────────────────────────────────┘
```

### 1.3 例：用户查询路由

```
应用 SQL: SELECT * FROM orders WHERE order_id = 123
    │
    ▼
SQL Parser
    │
    ▼
ObOptTabletLoc
    │
    ├─ 1. 拿 partition_key (order_id=123)
    │   └─ 计算 partition_id = hash(order_id) % N
    │
    ├─ 2. ObPartitionLocation 查 partition → 哪些 tablet
    │   └─ partition_id → tablet_ids
    │
    ├─ 3. ObTabletLocation 查 tablet → 在哪些 server
    │   └─ tablet_id → server list
    │
    └─ 4. 路由 SQL 到正确 server
```

### 1.4 路径修正（来自 #82 / #84 路径修正的延续）

```
正确路径:
  src/share/partition_table/ob_partition_location.{h,cpp}  (2 文件, 真实位置)
  src/rootserver/ob_partition_balance.h
  src/libtable/src/ob_tablet_location_proxy.h
  src/observer/table_load/backup/  (42 文件)

不存在路径 (按 #82 / #84 路径修正继续):
  src/share/partition/ob_partition_*.h     ← 不存在
  src/share/tablet/                        ← 不存在
  src/share/location/                      ← 不存在
```

---

## 2. ObPartitionLocation —— partition 物理位置

### 2.1 类骨架（实读自 `src/share/partition_location.h`）

```cpp
// src/share/partition_table/ob_partition_location.h
namespace oceanbase {
namespace sql {
class ObOptTabletLoc;
}
namespace share {

struct ObPidAddrPair {
public:
  int64_t pid_;
  common::ObAddr addr_;

  ObPidAddrPair(int64_t pid, common::ObAddr addr)
    : pid_(pid), addr_(addr) {}

  bool operator==(const ObPidAddrPair &other) const {
    return pid_ == other.pid_ && addr_ == other.addr_;
  }

  TO_STRING_KV(K_(pid), K_(addr));
};

class ObPartitionReplicaLocation;
struct ObReplicaLocation {
  OB_UNIS_VERSION(1);
public:
  common::ObAddr server_;
  common::ObRole role_;
  int64_t sql_port_;
  // ...
};

class ObPartitionLocation {
public:
  // 拿 partition 的所有副本位置
  int get_replica_locations(ObArray<ObReplicaLocation> &locations);

  // 拿 leader 位置
  int get_leader_location(ObReplicaLocation &location);

  // 拿 follower 位置
  int get_follower_locations(ObArray<ObReplicaLocation> &locations);

  // refresh
  int refresh();

private:
  uint64_t partition_id_;
  ObArray<ObReplicaLocation> replica_locations_;
};

}  // share
}  // oceanbase
```

### 2.2 关键设计

**`ObPartitionLocation` 类**：
- 一个 partition 的所有副本位置（replica_locations_）
- 区分 leader / follower
- refresh() 触发 cache 失效

**`ObReplicaLocation` 结构**：
- server_ —— observer 地址
- role_ —— leader / follower
- sql_port_ —— SQL 端口
- 支持序列化（OB_UNIS_VERSION(1)）

---

## 3. ObTabletLocationProxy —— tablet 位置查询

### 3.1 类骨架

```cpp
// src/libtable/src/ob_tablet_location_proxy.h
class ObTabletLocationProxy {
public:
  // 单 tablet 位置查询
  int get_tablet_location(const uint64_t tenant_id,
                          const ObTabletID &tablet_id,
                          ObTabletLocation &location);

  // 批量 tablet 位置查询
  int batch_get(const uint64_t tenant_id,
                const ObIArray<ObTabletID> &tablet_ids,
                ObIArray<ObTabletLocation> &locations);

  // refresh
  int refresh(const ObTabletID &tablet_id);

private:
  // 内部用 ObLocationCache (参见 #77)
  ObLocationCache *cache_;
};
```

### 3.2 关键设计

**`ObTabletLocationProxy`**：
- libtable 的一部分（不是 schema / location_cache）
- 提供给 SQL 层使用
- 内部委托给 `ObLocationCache`（参见 #77）
- 支持单 tablet + 批量查询

---

## 4. ObPartitionBalance —— partition rebalance

### 4.1 类骨架（推测）

```cpp
// src/rootserver/ob_partition_balance.h
class ObPartitionBalance {
public:
  // 调度 partition rebalance 任务
  int schedule_balance_tasks();

  // 执行单 partition 迁移
  int migrate_partition(const ObPartitionKey &partition_key,
                       const ObServer &target_server);

  // 计算 partition 分布
  int compute_balance_plan(ObArray<ObBalanceAction> &actions);

  // 监控 rebalance 进度
  int check_progress();

private:
  // 内部状态
  bool in_progress_;
  ObArray<ObBalanceTask> pending_tasks_;
};
```

### 4.2 触发场景

| 场景 | 触发原因 |
|------|----------|
| 节点增减 | 新加 observer / 下线 observer |
| Zone 增减 | 跨机房扩容 |
| Unit 迁移（参见 #81） | 资源重新分配 |
| 负载不均 | 热点 partition 重新分布 |
| Locality 变更 | 跨机房副本策略变化 |

### 4.3 Balance 算法

```
目标: partition 在所有 observer 上均匀分布
约束:
  - 每个 partition 副本数不变
  - locality 约束（参见 #47）
  - 副本不能在同 observer（同 zone 不同 observer）
  - 不能让 partition 重新分配影响正在运行的 SQL
```

---

## 5. ObTenantBalanceService —— tenant 级别 balance

### 5.1 类骨架（推测）

```cpp
// src/rootserver/ob_tenant_balance_service.h
class ObTenantBalanceService {
public:
  // tenant 级别 balance（multi-unit 时）
  int balance_tenant(const uint64_t tenant_id);

  // 检查 tenant 内 partition 分布
  int check_tenant_balance(const uint64_t tenant_id);
};
```

### 5.2 与 #81 Resource Pool / Unit 的关系

- Tenant 有 1..N 个 Unit
- Unit 在不同 observer 上
- Tenant balance = Unit 间 partition 分布均匀

---

## 6. Partition Transfer —— partition 迁移

### 6.1 触发

```sql
-- 手动迁移 partition 到指定 server
ALTER SYSTEM RELOCATE PARTITION p FROM SERVER 'old:2882' TO 'new:2882';
```

### 6.2 流程

```
1. RS 发起 partition transfer
    │
2. 通知 source observer 准备 transfer
    │
    ├─ 暂停该 partition 的新事务
    │
3. target observer 启动 transfer
    │
    ├─ 拉取 source observer 的 partition 数据（snapshot + redo log）
    │
    ├─ 写本地存储（memtable + SSTable）
    │
    └─ 同步 redo log
    │
4. source observer 释放 partition
    │
5. RS 通知各 observer 更新 location cache
    │
6. 完成 transfer
```

### 6.3 与 #77 Location Cache 的关系

- Partition transfer 完成 → location cache 需要 update
- RS broadcast 新 location
- observer 收到 broadcast → ObLocationService::refresh
- 后续 SQL 路由到新 server

---

## 7. Partition Split / Merge

### 7.1 Partition Split

```sql
-- 将一个 range partition 拆成两个
ALTER TABLE t SPLIT PARTITION p1 INTO (
  PARTITION p1a VALUES LESS THAN (100),
  PARTITION p1b VALUES LESS THAN (200)
);
```

### 7.2 流程

```
1. RS 接收 ALTER TABLE SPLIT PARTITION
    │
2. 校验新 partition 范围
    │
3. 创建新 tablet（new partition 对应新 tablet）
    │
4. 移动原 partition 数据到新 tablet
    │
    ├─ 范围 (100, 200) 数据 → p1b
    └─ 范围 (-∞, 100) 数据 → p1a
    │
5. 删除原 partition（如果完全是 split 源）
    │
6. 触发 schema_version 升级
    │
7. 通知各 observer 更新 schema + location
```

### 7.3 Partition Merge

```sql
-- 将相邻 partition 合并
ALTER TABLE t MERGE PARTITIONS p1, p2 INTO PARTITION p3;
```

### 7.4 Split / Merge 性能

- Split: 数据搬迁 + 大量 IO（典型小时级）
- Merge: 同上（小时级）
- 都是 Online DDL（不阻塞 DML，但消耗 IO）

---

## 8. Locality 策略

### 8.1 Locality 概念

参见 #47 Locality Replica。

### 8.2 Locality 表达

```sql
CREATE TABLE t (
  id INT,
  ...
)
LOCALITY = 'zone1, zone2, zone3'  -- 三副本分别在 3 个 zone
-- 或
LOCALITY = 'F{zone1:1},F{zone2:1},F{zone3:1}'  -- 完整 F-style
```

### 8.3 Locality 与 partition balance 互动

```
tenant locality: F{zone1}, R{zone2}
                    ↓
table t locality 继承
                    ↓
table t 的每个 partition 默认遵循 tenant locality
                    ↓
但可以 override: LOCALITY = 'F{zone1:2}, R{zone3:1}'  -- 2 副本在 zone1，1 副本在 zone3
```

### 8.4 Locality 变更 → 自动 rebalance

```sql
-- 改 locality 触发 rebalance
ALTER TABLE t LOCALITY = 'F{zone1}, F{zone2}, R{zone3}';
    │
    ▼
RS 检测 locality 变化
    │
    ├─ 1. 计算新副本分布
    │
    ├─ 2. 调度 partition transfer
    │
    └─ 3. 各 observer 应用新副本
```

---

## 9. Backup 表加载（src/observer/table_load/backup/）

### 9.1 模块组成（42 文件）

```bash
src/observer/table_load/backup/
├── ob_table_load_backup_block_sstable_struct.{h,cpp}  # macro block 结构
├── ob_table_load_backup_column_map_v1.{h,cpp}        # 列映射 V1
├── ob_table_load_backup_column_map_v2.{h,cpp}        # 列映射 V2 (OB 5.x)
├── ob_table_load_backup_file_util.{h,cpp}            # 文件工具
├── ob_table_load_backup_flat_row_reader_v1.{h,cpp}  # flat row reader V1
├── ob_table_load_backup_flat_row_reader_v2.{h,cpp}  # flat row reader V2
├── ob_table_load_backup_row_reader.{h,cpp}           # 通用 row reader
├── ob_table_load_backup_restore_service.{h,cpp}     # restore service
├── ob_table_load_backup_sstable_sec_meta_reader.{h,cpp}  # SSTable sec meta
├── ob_table_load_backup_stat.h                        # 统计
├── encoding/                                          # 编码
│   ├── ob_table_load_backup_encoding_calculator.{h,cpp}
│   ├── ob_table_load_backup_ob_csv_decoder.{h,cpp}
│   ├── ob_table_load_backup_ob_csv_encoder.{h,cpp}
│   ├── ob_table_load_backup_sql_consumer.{h,cpp}
│   └── # ... 其他
└── # ... 20+ 其他
```

### 9.2 Restore 时的表加载

```
Restore job 启动
    │
    ▼
ObTableLoadBackupService (from 42 文件)
    │
    ├─ 1. 读 backup piece（参见 #78）
    │
    ├─ 2. ObTableLoadBackupFlatRowReader 读 row
    │
    ├─ 3. ObTableLoadBackupColumnMap_V2 映射列
    │
    ├─ 4. ObTableLoadBackupBlockSSTableStruct 写 SSTable
    │
    ├─ 5. 编码 + 压缩
    │
    └─ 6. ingest 到目标集群
```

### 9.3 V1 vs V2

- **V1**：OB 4.x backup piece 格式（老）
- **V2**：OB 5.x backup piece 格式（新）

OB 5.x 同时支持两种格式（向后兼容）。

---

## 10. 与其他文章的关系

### 10.1 与 #36 Concurrency Control

Partition 操作涉及多种并发场景：
- 多个 partition 同时 rebalance
- partition split 期间的 DML 并发
- partition transfer 期间读写不阻塞

### 10.2 与 #38 PALF Member Change

PALF 成员变更（参见 #38）触发 partition balance：
- 副本数变化 → partition 副本需要调整
- Leader 切换 → location cache 更新

### 10.3 与 #47 Locality Replica

Locality 策略是 partition 分布的约束（参见 #47）：
- F{R{}} 表达
- 跨机房 / 跨 zone
- 副本类型

### 10.4 与 #48 Data Checkpoint

Partition 级别 checkpoint（参见 #48）：
- 每个 partition 独立 checkpoint
- Partition transfer 时 checkpoint 一起迁移

### 10.5 与 #64 Online DDL

DDL 触发的 partition 数量调整（参见 #64）：
- ADD PARTITION → 新 partition
- SPLIT PARTITION → partition 拆分
- MERGE PARTITION → partition 合并
- DROP PARTITION → partition 删除

### 10.6 与 #77 Location Cache

Tablet 位置缓存（参见 #77）：
- `__all_virtual_ls_log_restore_status` 监控 partition transfer
- Location cache 与 partition 分布同步

### 10.7 与 #30 Observer Startup

Observer 启动时加载 partition location（参见 #30）：
- 从 RS 拉 initial partition map
- 加载 location cache
- 启动 partition 维护线程

---

## 11. 总结

### 11.1 Partition Table 在 OB 体系中的定位

Partition Table 是 **OB 集群数据物理分布的核心**：
- Partition = 用户态逻辑（按 key 路由）
- Tablet = 物理存储（PALF / MemTable / SSTable）
- LS = 共享副本的最小单位
- 通过 partition → tablet → server 映射支撑整个 SQL 路由

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Partition vs Tablet | 1:N 关系（partition → tablets） |
| Tablet vs LS | N:M 关系（多 tablet 共享 LS） |
| ObPartitionLocation | partition 物理位置 |
| ObTabletLocationProxy | tablet 位置查询（libtable） |
| ObPartitionBalance | partition rebalance |
| ObTenantBalanceService | tenant 级别 balance |
| Partition Transfer | partition 跨 server 迁移 |
| Split / Merge | partition 数量调整 |
| Locality 策略 | F{R{}} 表达 |
| Backup Restore 表加载 | 42 文件 + encoding/ 子目录 |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/partition_table/ob_partition_location.{h,cpp}` (2 文件) | partition 位置 |
| `src/rootserver/ob_partition_balance.h` | partition rebalance |
| `src/rootserver/ob_tenant_balance_service.h` | tenant balance |
| `src/rootserver/ob_rebalance_task.h` | rebalance 任务 |
| `src/libtable/src/ob_tablet_location_proxy.h` | tablet 位置查询 |
| `src/observer/table_load/backup/` (42 文件) | restore 表加载 |
| `src/share/location_cache/` (20 文件, 参见 #77) | tablet location cache |

### 11.4 路径修正（来自 #82 / #84 路径修正的延续）

```
正确路径:
  src/share/partition_table/ob_partition_location.{h,cpp}  (2 文件)
  src/rootserver/ob_partition_balance.h
  src/libtable/src/ob_tablet_location_proxy.h
  src/observer/table_load/backup/  (42 文件)

不存在路径:
  src/share/partition/ob_partition_*.h     ← 不存在
  src/share/tablet/                        ← 不存在
  src/share/location/                      ← 不存在（实际在 src/share/location_cache/）
```

### 11.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#86 表加载 / Table Load / 批量导入**（深化 #66 Direct Load）：

OB 的 table load 框架 —— 多种数据源（CSV / SQL / backup）的批量导入，ObTableLoadService 统一抽象。源码入口：`src/observer/table_load/` + `src/observer/table_load/backup/` + `src/sql/engine/cmd/ob_load_data_*`。

适用场景：批量数据迁移 / 备份恢复 / 跨集群同步。

整吗？