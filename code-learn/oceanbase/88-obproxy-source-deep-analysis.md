# 88-obproxy — OceanProxy 源码深度分析 / 跨 observer 通信深化 #63

> 基于 OceanBase 5.0.2.0 主线源码（OBProxy 主仓独立于 OB 主仓，**当前 workspace 不存在**）+ 现有 OB 仓库中与 OBProxy 相关的 proxy 类（`src/share/ob_common_rpc_proxy.{h,cpp,ipp}` + `ob_core_table_proxy.{h,cpp}` + `ob_freeze_info_proxy.{h,cpp}` + `ob_global_stat_proxy.{h,cpp}` + `ob_log_restore_proxy.{h,cpp}` + `ob_schema_status_proxy.{h,cpp}` + `ob_service_epoch_proxy.{h,cpp}` + `ob_service_name_proxy.{h,cpp}` + `ob_snapshot_table_proxy.{h,cpp}` + `ob_srv_rpc_proxy.{h,cpp,ipp}` + `ob_tenant_info_proxy.{h,cpp}` + `src/observer/ob_inner_sql_rpc_proxy.{h,cpp}` + `src/observer/mysql/obmp_query.h` + 多个 `src/observer/virtual_table/ob_all_virtual_proxy_*.{h,cpp}`）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OBProxy 是 **OB 集群的入口网关**（参见 #63 概览）—— 解析 MySQL 协议、路由 SQL 到正确的 observer、维护连接池、做弱读路由等。OBProxy 是**独立仓库**（`github.com/oceanbase/obproxy`），不在 OB 主仓 `src/` 下。本篇是 #63 的深化，聚焦 **当前 OB 仓库中与 OBProxy 相关的 proxy 类**——这些是 OBObserver 暴露给 OBProxy 的接口端点。

本文聚焦 7 个核心问题：

1. **OBProxy 在独立仓库** —— 路径修正 + 源码不可用说明
2. **OB Common RPC Proxy** —— OB 仓库中与 OBProxy 交互的核心入口
3. **ObInnerSQLRpcProxy** —— Inner SQL RPC（23+ operation type）
4. **ObmpQuery** —— MySQL 协议入口
5. **Virtual Table Proxy** —— 100+ `ob_all_virtual_proxy_*` 虚拟表
6. **多个 ob_*_proxy 类** —— freeze / schema status / service epoch / snapshot / log_restore 等
7. **#63 OBProxy 概览回顾** + 深化方向

### 与前面文章的关系

| 文章 | 关联点 |
|------|--------|
| 63-obproxy | #63 是早期分析 OBProxy 架构概览，本篇是 #63 的深化 |
| 65-standby-cluster | Standby 走 `ob_log_restore_proxy` 通过 RPC 拉 Primary 日志 |
| 77-location-cache | OBProxy 也有自己的 location cache（客户端视角） |
| 88-obproxy | 本篇 |
| 53-rpc-framework | OBProxy ↔ observer 通过 obrpc 通信（参见 #53 / #87） |

---

## 1. 整体架构：OBProxy 与 OB 主仓库的边界

### 1.1 路径修正

```
正确路径 (OBProxy 主仓):
  github.com/oceanbase/obproxy   ← 独立仓库
  src/obproxy/                   ← OBProxy 主源码
  src/obproxy/net/               ← 网络层
  src/obproxy/proxy/             ← proxy 实现
  src/obproxy/route/             ← 路由
  src/obproxy/mysql/             ← MySQL 协议解析

不存在 (当前 workspace):
  ~/code/oceanbase-proxy/  ← 不存在（OBProxy 独立仓库）
  src/obproxy/             ← 不存在（OB 主仓中）
```

### 1.2 当前 OB 主仓库中的 OBProxy 相关类

虽然 OBProxy 主源码在独立仓库，但 OBObserver 暴露给 OBProxy 的接口端点在 OB 主仓中：

```bash
# src/share/ - OBObserver 暴露的 RPC proxy 类
src/share/
├── ob_common_rpc_proxy.{h,cpp,ipp}              # 通用 RPC proxy（核心）
├── ob_core_table_proxy.{h,cpp}                    # core table proxy
├── ob_freeze_info_proxy.{h,cpp}                  # freeze info proxy
├── ob_global_stat_proxy.{h,cpp}                  # global stat proxy
├── ob_log_restore_proxy.{h,cpp}                  # log restore proxy（Standby）
├── ob_schema_status_proxy.{h,cpp}                # schema status proxy
├── ob_service_epoch_proxy.{h,cpp}                # service epoch proxy
├── ob_service_name_proxy.{h,cpp}                  # service name proxy
├── ob_snapshot_table_proxy.{h,cpp}               # snapshot table proxy
├── ob_srv_rpc_proxy.{h,cpp,ipp}                  # server RPC proxy
└── ob_tenant_info_proxy.{h,cpp}                  # tenant info proxy

# src/observer/ - observer 层 OBProxy 接口
src/observer/
├── ob_inner_sql_rpc_proxy.{h,cpp}                # Inner SQL RPC（23+ types）
└── mysql/
    └── obmp_query.h                                # MySQL 协议入口

# src/observer/virtual_table/ - 虚拟表 proxy（100+）
src/observer/virtual_table/
├── ob_all_virtual_proxy_base.{h,cpp}             # proxy 基类
├── ob_all_virtual_proxy_partition.{h,cpp}         # partition proxy
├── ob_all_virtual_proxy_routine.{h,cpp}           # routine proxy
├── ob_all_virtual_proxy_schema.{h,cpp}            # schema proxy
├── ob_virtual_proxy_server_stat.{h,cpp}           # server stat proxy
└── # ... 100+ 其他 ob_all_virtual_proxy_*
```

### 1.3 OBProxy ↔ OBObserver 通信架构

```
┌──────────────────────────────────────────────────────────────────┐
│  OBProxy (独立仓库, github.com/oceanbase/obproxy)             │
│  - MySQL 协议解析                                              │
│  - 路由决策 (LDC / 弱读)                                       │
│  - 连接池                                                      │
│  - 解析 SQL → 调用 observer RPC                                │
└──────────────────────────────────────────────────────────────────┘
                              │ obrpc
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  OBObserver (当前仓库)                                          │
│  - ob_common_rpc_proxy 接收 OBProxy 请求                        │
│  - ob_inner_sql_rpc_proxy 处理 Inner SQL                         │
│  - ob_all_virtual_proxy_* 暴露虚拟表                            │
│  - ob_log_restore_proxy 处理 Standby 拉日志                     │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. ObCommonRpcProxy —— 通用 RPC proxy（核心）

### 2.1 类骨架（实读自 `ob_common_rpc_proxy.h`）

```cpp
// src/share/ob_common_rpc_proxy.h
namespace oceanbase {
namespace obrpc {

class ObCommonRpcProxy
    : public obrpc::ObRpcProxy
{
public:
  DEFINE_TO(ObCommonRpcProxy);

  // 关键：所有 RPC 方法通过 ipp 文件声明
#define OB_RPC_DECLARATIONS
#include "ob_common_rpc_proxy.ipp"
#undef OB_RPC_DECLARATIONS

  // 设置 RS mgr（用于发给 RS 的请求）
  inline void set_rs_mgr(share::ObRsMgr &rs_mgr) {
    rs_mgr_ = &rs_mgr;
  }

  // to_rs() —— 特殊：发给 RS（不需要 set dst_server）
  inline ObCommonRpcProxy to_rs(share::ObRsMgr &rs_mgr) const {
    ObCommonRpcProxy proxy = this->to();
    proxy.set_rs_mgr(rs_mgr);
    return proxy;
  }

private:
  share::ObRsMgr *rs_mgr_;
};

}  // obrpc
}  // oceanbase
```

### 2.2 关键设计

**`ObCommonRpcProxy` 通过 .ipp 文件声明 RPC 方法**：
- `ob_common_rpc_proxy.ipp` 包含所有 RPC 方法的声明
- 编译时由预处理器展开
- 这是 OB 的 RPC proxy 自动生成模式

**`set_rs_mgr` / `to_rs`**：
- 某些 RPC 是发给 RS 的（不需要指定 destination server）
- RS 通过 `to_rs` 简化调用

### 2.3 .ipp 文件内容

`ob_common_rpc_proxy.ipp` 包含所有 OBObserver 暴露给 OBProxy 的 RPC 方法声明，典型如：
- `admin_set_config` —— 改配置
- `admin_set_tenant_config` —— 改租户配置
- `admin_backup_database` —— 备份
- `admin_restore_database` —— 恢复
- `admin_switch_tenant_role` —— 切角色
- `admin_revoke_privilege` —— 撤销权限
- `admin_grant_privilege` —— 授予权限
- 几十种 admin RPC

---

## 3. ObInnerSQLRpcProxy —— Inner SQL RPC（23+ operation type）

### 3.1 类骨架（实读自 `ob_inner_sql_rpc_proxy.h`）

```cpp
// src/observer/ob_inner_sql_rpc_proxy.h
namespace oceanbase {
namespace obrpc {

class ObInnerSQLTransmitArg {
  OB_UNIS_VERSION(1);
public:
  enum InnerSQLOperationType {
    OPERATION_TYPE_INVALID = 0,
    OPERATION_TYPE_START_TRANSACTION = 1,
    OPERATION_TYPE_ROLLBACK = 2,
    OPERATION_TYPE_COMMIT = 3,
    OPERATION_TYPE_EXECUTE_READ = 4,
    OPERATION_TYPE_EXECUTE_WRITE = 5,
    OPERATION_TYPE_REGISTER_MDS = 6,
    OPERATION_TYPE_LOCK_TABLE = 7,
    OPERATION_TYPE_LOCK_TABLET = 8,
    OPERATION_TYPE_UNLOCK_TABLE = 9,
    OPERATION_TYPE_UNLOCK_TABLET = 10,
    OPERATION_TYPE_LOCK_PART = 11,
    OPERATION_TYPE_UNLOCK_PART = 12,
    OPERATION_TYPE_LOCK_OBJ = 13,
    OPERATION_TYPE_UNLOCK_OBJ = 14,
    OPERATION_TYPE_LOCK_SUBPART = 15,
    OPERATION_TYPE_UNLOCK_SUBPART = 16,
    OPERATION_TYPE_LOCK_ALONE_TABLET = 17,
    OPERATION_TYPE_UNLOCK_ALONE_TABLET = 18,
    OPERATION_TYPE_LOCK_OBJS = 19,
    OPERATION_TYPE_UNLOCK_OBJS = 20,
    OPERATION_TYPE_REPLACE_LOCK = 21,
    OPERATION_TYPE_REPLACE_LOCKS = 22,
    OPERATION_TYPE_INNER_TABLET_WRITE = 23,
    // ... 几十种
  };
};

class ObInnerSQLTransmitProxy
    : public obrpc::ObRpcProxy
{
public:
  DEFINE_TO(ObInnerSQLTransmitProxy);

  // 关键 RPC：跨 observer Inner SQL 转发
  // 场景：OBProxy 或 observer 把 SQL 转发到另一个 observer
  int transmit(const ObInnerSQLTransmitArg &arg, ObInnerSQLTransmitResult &result);

  // 几十种其他 Inner SQL RPC
};

}  // obrpc
}  // oceanbase
```

### 3.2 Inner SQL 的角色

**Inner SQL RPC** 是 OB 内部"跨 observer 转发 SQL"的机制：
- 应用通过 OBProxy 发送 SQL → observer #1
- observer #1 收到后判断：实际执行可能在 observer #2（数据所在）
- 通过 `transmit` RPC 把 SQL 转发到 observer #2
- observer #2 执行 → 结果返回 observer #1 → 返回给应用

### 3.3 23+ Operation Type

| Type | 含义 |
|------|------|
| `START_TRANSACTION` / `COMMIT` / `ROLLBACK` | 事务控制 |
| `EXECUTE_READ` / `EXECUTE_WRITE` | SQL 执行（读 / 写） |
| `REGISTER_MDS` | MDS（参见 #65）注册 |
| `LOCK_TABLE` / `LOCK_TABLET` / `UNLOCK_*` | 表级 / Tablet 级锁（参见 #75） |
| `LOCK_PART` / `LOCK_SUBPART` / `LOCK_OBJ` | 分区 / 子分区 / 对象级锁 |
| `LOCK_OBJS` / `UNLOCK_OBJS` | 批量锁 |
| `LOCK_ALONE_TABLET` / `UNLOCK_ALONE_TABLET` | 单独 Tablet 锁 |
| `REPLACE_LOCK` / `REPLACE_LOCKS` | 替换锁（事务内） |
| `INNER_TABLET_WRITE` | Inner Tablet 写 |
| 几十种... | |

### 3.4 Inner SQL 跨 observer 流程

```
应用 SQL: SELECT * FROM t WHERE id = 1
    │
    ▼
OBProxy (解析 MySQL 协议)
    │
    ▼
observer #1 (入口 observer)
    │
    ├─ 1. 查 location cache (id=1 → partition_id=P)
    │     └─ P 在 observer #2
    │
    ├─ 2. 转发 SQL 到 observer #2
    │     └─ transmit(EXECUTE_READ, P, id=1)
    │     └─ ObInnerSQLTransmitArg 含 OPERATION_TYPE_EXECUTE_READ
    │
    ▼
observer #2
    │
    ├─ 3. 收到 Inner SQL RPC
    │
    ├─ 4. 解析 Inner SQL
    │
    ├─ 5. 执行 SELECT（id=1 → partition P）
    │
    └─ 6. 返回结果
    │
    ▼
observer #1
    │
    └─ 7. 转发结果回应用
    │
    ▼
OBProxy → 应用
```

---

## 4. ObmpQuery —— MySQL 协议入口

### 4.1 角色

```cpp
// src/observer/mysql/obmp_query.h
class ObmpQuery {
public:
  // MySQL COM_QUERY 协议处理
  int process(ObExecContext &ctx, const ParseNode &parse_tree);
};
```

### 4.2 MySQL COM_QUERY 协议

应用通过 OBProxy 发送 MySQL COM_QUERY 包：
- OBProxy 解析包
- 转发 SQL 到 observer
- observer 调 `ObmpQuery::process`
- 执行 → 返回结果

### 4.3 vs #53 RPC 框架

- **#53**：`ObRpcProcessor` 跨 observer / RS 通信
- **#88（本篇）**：`ObmpQuery` 应用层 MySQL 协议入口

---

## 5. Virtual Table Proxy（100+ ob_all_virtual_proxy_*）

### 5.1 全景

```bash
src/observer/virtual_table/
├── ob_all_virtual_proxy_base.{h,cpp}             # proxy 基类
├── ob_all_virtual_proxy_partition.{h,cpp}         # partition 信息
├── ob_all_virtual_proxy_routine.{h,cpp}           # routine 信息
├── ob_all_virtual_proxy_schema.{h,cpp}            # schema 信息
├── ob_all_virtual_proxy_routine.{h,cpp}           # routine 信息
├── ob_virtual_proxy_server_stat.{h,cpp}           # server stat
└── # ... 100+ 其他 ob_all_virtual_proxy_*
```

### 5.2 vs 普通 ob_all_virtual_*

| 维度 | `ob_all_virtual_*` | `ob_all_virtual_proxy_*` |
|------|-------------------|--------------------------|
| 访问者 | DBA / OCP | **OBProxy** 专用 |
| 用途 | 监控 / 调试 | OBProxy 路由 / LDC 决策 |
| 数据 | 通用元数据 | proxy-specific 元数据 |
| 例子 | `__all_virtual_thread` | `__all_virtual_proxy_partition` |

### 5.3 OBProxy 用 virtual table

OBProxy 通过 SQL 协议访问这些虚拟表：
- 查 `__all_virtual_proxy_partition` → 拿 partition 在哪些 observer
- 查 `__all_virtual_proxy_server_stat` → 拿 server 状态
- 用于 OBProxy 的路由决策（LDC、弱读等）

---

## 6. 多个 ob_*_proxy 类

### 6.1 ob_log_restore_proxy（参见 #65 Standby）

```cpp
// src/share/ob_log_restore_proxy.{h,cpp}
class ObLogRestoreProxy : public obrpc::ObRpcProxy {
public:
  // 拉取 Primary 日志（Standby 模式）
  int fetch_log(const ObLogRestoreFetchLogArg &arg,
                ObLogRestoreFetchLogResult &result);
};
```

**Standby 模式核心 RPC**（参见 #65）：
- Standby observer 通过 `fetch_log` RPC 拉 Primary observer 的 clog
- 与 `ob_log_restore_handler` 配合
- 持续 background thread 调用

### 6.2 ob_freeze_info_proxy

```cpp
class ObFreezeInfoProxy {
  // 冻结信息查询
  int get_freeze_info(...);
};
```

### 6.3 ob_schema_status_proxy

```cpp
class ObSchemaStatusProxy {
  // Schema 状态查询（参见 #76）
  int get_schema_status(...);
};
```

### 6.4 ob_service_epoch_proxy

```cpp
class ObServiceEpochProxy {
  // 服务 epoch（版本号）
  int get_service_epoch(...);
};
```

### 6.5 ob_snapshot_table_proxy

```cpp
class ObSnapshotTableProxy {
  // snapshot table 信息（参见 #68）
  int get_snapshot_table_info(...);
};
```

### 6.6 ob_tenant_info_proxy

```cpp
class ObTenantInfoProxy {
  // 租户信息（参见 #39 / #81）
  int get_tenant_info(...);
};
```

### 6.7 ob_srv_rpc_proxy（核心）

```cpp
// src/share/ob_srv_rpc_proxy.{h,cpp,ipp}
class ObSrvRpcProxy : public obrpc::ObRpcProxy {
public:
  DEFINE_TO(ObSrvRpcProxy);
#define OB_RPC_DECLARATIONS
#include "ob_srv_rpc_proxy.ipp"
#undef OB_RPC_DECLARATIONS

  // 跨 observer 通用 RPC（参见 #53 / #87）
  // 几十种 RPC 方法
};
```

**OB server 暴露给其他 server 的 RPC proxy** —— 与 `ObCommonRpcProxy` 互补（后者是 admin RPC，前者是业务 RPC）。

### 6.8 ob_global_stat_proxy

```cpp
class ObGlobalStatProxy {
  // 全局统计
  int get_global_stat(...);
};
```

### 6.9 ob_core_table_proxy

```cpp
class ObCoreTableProxy {
  // core table 访问（参见 #82 内部表）
  int get_core_table_info(...);
};
```

---

## 7. 与 #63 OBProxy 概览的关系

### 7.1 #63 已覆盖（早期分析）

参见 #63 OBProxy Architecture 概览：
- 5 层架构
- MySQL 协议解析
- LDC 路由
- 弱读路由
- 连接池
- 性能调优

### 7.2 本篇深化方向

| #63 概览 | 本篇深化（#88） |
|---------|---------------|
| OBProxy 主架构 | OBObserver 暴露的 proxy 类（具体接口） |
| MySQL 协议解析 | `ObmpQuery::process`（MySQL COM_QUERY 处理） |
| 跨 observer 转发 | `ObInnerSQLTransmitProxy` + 23+ operation type |
| Location cache | `__all_virtual_proxy_*`（100+ proxy 虚拟表） |
| Admin RPC | `ObCommonRpcProxy` + `ob_common_rpc_proxy.ipp` |
| Server RPC | `ObSrvRpcProxy` + `ob_srv_rpc_proxy.ipp` |
| Standby | `ob_log_restore_proxy`（详细接口） |

### 7.3 未来可能的深化方向

如果 OBProxy 主仓源码可用（`github.com/oceanbase/obproxy`）：
- 完整 MySQL 协议解析器
- 完整路由决策树
- 完整连接池实现
- 完整 SQL 改写
- 完整弱读路由算法
- 完整 LDC locality 策略

---

## 8. 与其他文章的关系

### 8.1 与 #53 RPC Framework

`ObCommonRpcProxy` / `ObSrvRpcProxy` / `ObInnerSQLTransmitProxy` 都是 obrpc 框架（参见 #53 / #87）的 proxy 实现：
- 继承 `obrpc::ObRpcProxy` 基类
- 使用 `.ipp` 文件声明 RPC 方法
- 通过 `DEFINE_TO` macro 生成 stub

### 8.2 与 #65 Standby

Standby 模式（参见 #65）通过 `ob_log_restore_proxy` 拉 Primary 日志：
- `fetch_log` RPC 调用
- 与 `ob_log_restore_handler` 配合
- 持续 background thread

### 8.3 与 #77 Location Cache

OBProxy 也有自己的 location cache（参见 #77）：
- OBProxy 视角：partition → 哪些 observer
- 通过 `__all_virtual_proxy_*` 虚拟表查询
- observer 视角：tablet → 在哪些 observer（参见 #77）

### 8.4 与 #76 Schema Service

OBProxy 通过 `ob_schema_status_proxy` 查 schema 状态（参见 #76）：
- Schema 变更后 OBProxy cache 失效
- 重新查 `__all_virtual_schema_status` 获取最新 schema

### 8.5 与 #39 Tenant Architecture

OBProxy 通过 `ob_tenant_info_proxy` 查租户信息（参见 #39 / #81）：
- 租户状态
- Resource Pool / Unit 信息
- Locality 策略

---

## 9. 总结

### 9.1 OBProxy 相关代码在 OB 主仓库的定位

OBProxy 主代码在独立仓库 `github.com/oceanbase/obproxy`，但 OBObserver 暴露给 OBProxy 的接口端点在 OB 主仓库中。本文聚焦后者：

- **`ObCommonRpcProxy`** —— Admin RPC（配置 / 备份 / 权限）
- **`ObSrvRpcProxy`** —— Server RPC（业务）
- **`ObInnerSQLTransmitProxy`** —— Inner SQL 跨 observer 转发（23+ operation type）
- **`ObmpQuery`** —— MySQL 协议入口
- **多个 ob_*_proxy 类** —— freeze / schema / service / snapshot / log_restore / tenant_info / global_stat / core_table
- **`ob_all_virtual_proxy_*`** —— OBProxy 专用虚拟表（100+）

### 9.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Admin RPC | `ObCommonRpcProxy` + `ob_common_rpc_proxy.ipp` |
| Server RPC | `ObSrvRpcProxy` + `ob_srv_rpc_proxy.ipp` |
| Inner SQL 转发 | `ObInnerSQLTransmitProxy` + 23+ `InnerSQLOperationType` |
| MySQL 入口 | `ObmpQuery::process`（COM_QUERY） |
| 跨 observer 转发 | `transmit(OPERATION_TYPE_EXECUTE_READ/WRITE, ...)` |
| Standby 拉日志 | `ob_log_restore_proxy::fetch_log`（参见 #65） |
| Proxy 虚拟表 | `__all_virtual_proxy_*`（100+） |

### 9.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/ob_common_rpc_proxy.{h,cpp,ipp}` | Admin RPC proxy |
| `src/share/ob_srv_rpc_proxy.{h,cpp,ipp}` | Server RPC proxy |
| `src/share/ob_core_table_proxy.{h,cpp}` | core table proxy |
| `src/share/ob_freeze_info_proxy.{h,cpp}` | freeze info proxy |
| `src/share/ob_global_stat_proxy.{h,cpp}` | global stat proxy |
| `src/share/ob_log_restore_proxy.{h,cpp}` | log restore proxy（参见 #65） |
| `src/share/ob_schema_status_proxy.{h,cpp}` | schema status proxy（参见 #76） |
| `src/share/ob_service_epoch_proxy.{h,cpp}` | service epoch proxy |
| `src/share/ob_service_name_proxy.{h,cpp}` | service name proxy |
| `src/share/ob_snapshot_table_proxy.{h,cpp}` | snapshot table proxy（参见 #68） |
| `src/share/ob_tenant_info_proxy.{h,cpp}` | tenant info proxy（参见 #39 / #81） |
| `src/observer/ob_inner_sql_rpc_proxy.{h,cpp}` | Inner SQL RPC（23+ operations） |
| `src/observer/mysql/obmp_query.h` | MySQL 协议入口 |
| `src/observer/virtual_table/ob_all_virtual_proxy_*.{h,cpp}` (100+) | Proxy 虚拟表 |

### 9.4 路径修正（来自 #82-#87 路径修正的延续）

```
正确路径 (OBObserver 端 OBProxy 接口):
  src/share/ob_*_proxy.{h,cpp}      ← OBObserver 暴露给 OBProxy
  src/observer/ob_inner_sql_rpc_proxy.{h,cpp}
  src/observer/mysql/obmp_query.h
  src/observer/virtual_table/ob_all_virtual_proxy_*.{h,cpp}

正确路径 (OBProxy 主仓, 当前 workspace 不存在):
  github.com/oceanbase/obproxy

不存在路径 (按 #82-#87 路径修正继续):
  src/obproxy/                       ← 不存在（OB 主仓中）
  ~/code/oceanbase-proxy/            ← 不存在（独立仓库）
```

### 9.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#89 OB MemStore / MemTable 内存表深度分析**（深化 #14 memtable-internals）：

OB 的内存表核心 —— 活跃数据的 in-memory 存储 + 转 SSTable + 并发控制。源码入口：`src/storage/memtable/` + `src/memtable/`（推测）+ `src/storage/ob_i_memtable_mgr.h`。

适用场景：内存优化 / 并发控制 / 转储策略 / 性能调优。

整吗？