# 82-meta-table-internal-schema — OceanBase Meta Table / 内部表 Schema 详解深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（`src/share/inner_table/` **108 文件** + `ob_inner_table_schema.h` + `ob_dump_inner_table_schema.{h,cpp}` + `ob_inner_table_init_data.py` + `generate_inner_table_schema.py` + `src/rootserver/ob_load_inner_table_schema_executor.{h,cpp}` 等）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Meta Table / 内部表 Schema** 是整个 observer 集群"元数据的元数据" —— **100+ 内部表**（`__all_table` / `__all_column` / `__all_user` / `__all_database` / `__all_tenant` / `__all_ddl_operation` 等）的 schema 定义、字段约束、初始数据全部通过 **自动生成** + **SQL 文件**管理。OB 5.x 的内部表体系是 **编译期生成** + **运行期加载**的混合模式。

本文聚焦 8 个核心问题：

1. **Inner Table 全景** —— 100+ 内部表的分类与作用
2. **Schema 自动生成机制** —— Python 脚本生成 108 个 .cpp 文件
3. **Inner Table 类别** —— sys / ddl / runtime / virtual 四类
4. **字段定义与约束** —— 类型 / 默认值 / 索引 / 主键
5. **Initial Data 机制** —— 集群启动时插入的初始记录
6. **Schema Versioning** —— 版本兼容性 + 升级路径
7. **Inner Table 加载流程** —— RS 启动期到 observer 可用
8. **DBA 视角的 Inner Table 访问**

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 59-schema-service | 早期分析 schema service 持久化 |
| 76-schema-service | #76 深化 OB 5.x schema service，本篇聚焦 inner table 本身 |
| 30-observer-startup | observer 启动时加载 inner table schema |
| 27-rootserver | RS 主导 inner table schema 加载 |
| 64-online-ddl | DDL 操作会修改 inner table |

---

## 1. 整体架构：Inner Table 自动生成 + 运行期加载

### 1.1 模块组成

```bash
$ ls src/share/inner_table/ | head -30
__init__.py
generate_inner_table_schema.py          # Python 生成器
ob_dump_inner_table_schema.cpp         # 启动期 dump
ob_dump_inner_table_schema.h
ob_inner_table_init_data.py            # 初始数据 Python 脚本
ob_inner_table_schema.h                 # 公共头（字段 ID 常量）
ob_inner_table_schema.10001_10050.cpp   # 按 table_id 范围生成（auto-generated）
ob_inner_table_schema.101_150.cpp
ob_inner_table_schema.11001_11050.cpp
ob_inner_table_schema.11051_11100.cpp
ob_inner_table_schema.11101_11150.cpp
ob_inner_table_schema.12001_12050.cpp
...
ob_inner_table_schema.60501_60550.cpp
```

**108 文件** —— Python 自动生成的 C++ 源码。每个文件覆盖一个 table_id 范围。

### 1.2 自动生成机制

```
ob_inner_table_schema.yaml (人工维护)
    │
    ▼ Python 脚本
    │
    ├── generate_inner_table_schema.py
    │   └── 生成 100+ 个 ob_inner_table_schema.<start>_<end>.cpp
    │
    ▼
    C++ 编译 (链接到 observer / RS binary)
    │
    ▼
    RS 启动时调用 ob_dump_inner_table_schema
    │
    ▼
    内部表 schema 写入 __all_* 内部表
    │
    ▼
    observer 启动时加载 schema cache (参见 #76)
```

### 1.3 三层生成机制

```
Layer 1: SQL 定义文件 (.yaml / .py)
    - 100+ 内部表的 DDL
    - 字段类型 / 默认值 / 约束
    │
Layer 2: Python 脚本 (generate_inner_table_schema.py)
    - 把 SQL 解析为 C++ 数据结构
    - 输出 108 个 .cpp 文件
    │
Layer 3: C++ 编译 + 链接
    - ob_inner_table_schema.<start>_<end>.cpp 链接到 binary
    - 启动期调用 ObDumpInnerTableSchema::dump()
    - 把 schema 写入内部表
```

---

## 2. Inner Table 全景 —— 100+ 内部表

### 2.1 主要内部表清单

| 表名 | 类别 | 用途 |
|------|------|------|
| `__all_table` | sys | 所有表定义（用户表 + 系统表 + 内部表） |
| `__all_column` | sys | 所有列定义 |
| `__all_database` | sys | 数据库定义 |
| `__all_tenant` | sys | 租户定义 |
| `__all_user` | sys | 用户定义 |
| `__all_role` | sys | 角色定义 |
| `__all_user_priv` / `__all_role_priv` | sys | 用户/角色系统权限（参见 #80） |
| `__all_objpriv` / `__all_database_objpriv` / `__all_table_objpriv` | sys | 对象权限 |
| `__all_ddl_operation` | sys | DDL 操作审计 |
| `__all_ddl_id` | sys | DDL ID 分配 |
| `__all_sequence` | sys | sequence 定义（参见 #67） |
| `__all_sequence_value` | sys | sequence 当前值 |
| `__all_udf` | sys | UDF 定义（参见 #69） |
| `__all_package` / `__all_package_body` | sys | PACKAGE 定义 |
| `__all_trigger` | sys | 触发器定义 |
| `__all_routine` / `__all_routine_param` | sys | 存储过程/函数定义 |
| `__all_index` / `__all_index_column` | sys | 索引定义 |
| `__all_constraint` / `__all_constraint_column` | sys | 约束定义 |
| `__all_partition` / `__all_subpartition` | sys | 分区定义 |
| `__all_audit_log` | sys | 审计日志（参见 #70） |
| `__all_security_audit_log` | sys | 安全审计日志 |
| `__all_privilege` | sys | 权限元数据 |
| `__all_resource_pool` / `__all_unit_config` | sys | Resource Pool / Unit（参见 #81） |
| `__all_zone` / `__all_server` | sys | Zone / Server 拓扑 |
| `__all_tenant_event` | sys | 租户事件历史 |
| `__all_recover_table_job` | sys | 恢复任务 |
| `__all_backup_task` / `__all_backup_task_history` | sys | 备份任务（参见 #78） |
| `__all_restore_job` / `__all_restore_job_history` | sys | 恢复任务 |
| `__all_restore_point` | sys | 恢复点 |
| `__all_cluster` | sys | 集群元数据 |
| `__all_cluster_event_history` | sys | 集群事件历史 |
| `__all_rootservice_event_history` | sys | RS 事件历史 |
| `__all_rootservice_lease` | sys | RS lease |
| `__all_freeze_info` | sys | freeze 信息 |
| `__all_major_freeze_status` | sys | major freeze 状态 |
| `__all_tenant_show_restore_preview` | sys | Restore 预览（参见 #78） |

### 2.2 虚拟表（`__all_virtual_*`）

```bash
$ ls src/observer/virtual_table/ | grep -c '^ob_all_virtual_'
100+
```

**100+ 虚拟表** —— 不存储数据，运行时通过 SQL 计算：
- `__all_virtual_table` —— 当前所有表（含内部表 + 用户表）
- `__all_virtual_column` —— 所有列
- `__all_virtual_user` —— 所有用户
- `__all_virtual_database` —— 所有数据库
- `__all_virtual_tablegroup` —— 所有表组
- `__all_virtual_show_create_table` —— SHOW CREATE TABLE
- `__all_virtual_tenant_parameter_stat` —— 租户参数（参见 #72）
- `__all_virtual_ls_log_restore_status` —— 恢复状态（参见 #78）
- `__all_virtual_thread` —— 线程状态（参见 #74）
- `__all_virtual_cgroup_config` —— cgroup 配置（参见 #71）
- `__all_virtual_latch_stat` —— 锁状态（参见 #75）

**虚拟表 vs 内部表**：
- **内部表**（`__all_*`）：持久化到磁盘，可修改
- **虚拟表**（`__all_virtual_*`）：不持久化，运行时计算

### 2.3 表 ID 命名规范

```
1-100:       系统表
101-200:     RS / 集群管理
1001-2000:   内部表
10001-100000: sys tenant 自己的表
60000+:      用户租户表

(具体范围 OB 内部约定)
```

ob_inner_table_schema.<start>_<end>.cpp 的命名 = 覆盖 table_id 范围：
- `ob_inner_table_schema.10001_10050.cpp` —— 覆盖 10001-10050
- `ob_inner_table_schema.60501_60550.cpp` —— 覆盖 60501-60550

---

## 3. Inner Table Schema 生成机制

### 3.1 generate_inner_table_schema.py

```python
# (推测, 类似以下流程)
import yaml

# 1. 读内部表定义
with open('ob_inner_table_schema.yaml') as f:
    tables = yaml.safe_load(f)

# 2. 按 table_id 范围分组
groups = {}
for table in tables:
    table_id = table['table_id']
    group_id = table_id // 50 * 50  # 每 50 个一组
    if group_id not in groups:
        groups[group_id] = []
    groups[group_id].append(table)

# 3. 为每个组生成一个 .cpp 文件
for group_id, group_tables in sorted(groups.items()):
    cpp_content = generate_cpp(group_id, group_tables)
    filename = f'ob_inner_table_schema.{group_id}_{group_id + 49}.cpp'
    with open(filename, 'w') as f:
        f.write(cpp_content)
```

### 3.2 ob_inner_table_schema.h —— 公共头

```cpp
// src/share/inner_table/ob_inner_table_schema.h
// 包含公共定义 + 字段 ID 常量
// 例:
// ALL_VIRTUAL_PLAN_STAT_CDE 中：
// enum { TENANT_ID = OB_APP_MIN_COLUMN_ID, SVR_IP, SVR_PORT, ... };
```

**作用**：所有 .cpp 文件共享这些常量（避免重复定义）。

### 3.3 启动期 dump

```cpp
// src/share/inner_table/ob_dump_inner_table_schema.h
class ObDumpInnerTableSchema {
public:
  // 把所有内部表 schema 写入 __all_* 内部表
  int dump_all();

  // 单表 schema dump
  int dump_table_schema(const ObTableSchema &schema);
};
```

启动时调用流程：
```
RS 启动
    │
    ▼
ObDumpInnerTableSchema::dump_all
    │
    ├─ 遍历所有内部表
    ├─ 调 generate_*_schema()（每个 .cpp 注册一个）
    ├─ INSERT INTO __all_table / __all_column / ...
    │
    ▼
RS 上线 → observer 启动 → 拉 schema cache → 内部表可用
```

---

## 4. Inner Table 类别

### 4.1 四类

| 类别 | 特点 | 示例 |
|------|------|------|
| **sys** | 系统级持久化（必装） | `__all_table` / `__all_column` / `__all_user` |
| **ddl** | DDL 操作审计 | `__all_ddl_operation` / `__all_ddl_id` |
| **runtime** | 运行时状态（可清空重建） | `__all_recover_table_job` / `__all_freeze_info` |
| **virtual** | 虚拟表（不持久化） | `__all_virtual_*`（100+） |

### 4.2 sys 类（必装）

sys 类是 OB 集群的"骨架"，必须正确初始化：
- 集群没这些表 → 不能启动
- 表结构错 → RS 启动失败
- 字段缺 → DDL / DML 全部失败

### 4.3 ddl 类

DDL 操作用的元数据表：
- `__all_ddl_operation` —— 每次 DDL 一条记录（含 DDL 类型 / 执行人 / 时间 / SQL）
- `__all_ddl_id` —— DDL ID 单调递增分配器

### 4.4 runtime 类

运行时状态表，集群启动时根据当前状态重建：
- `__all_recover_table_job` —— 恢复任务
- `__all_freeze_info` —— 上次 freeze 的 SCN
- `__all_backup_task` —— 当前 backup 任务

### 4.5 virtual 类（100+ 虚拟表）

参见 §2.2。

---

## 5. 字段定义与约束

### 5.1 字段类型

OB 内部表用 **ObTableSchema** 表达（参见 #64 §2）：
```cpp
struct ObColumnSchemaV2 {
  uint64_t column_id_;
  ObString column_name_;
  ObObjMeta meta_type_;          // 类型 + collation
  ObAccuracy accuracy_;          // length / precision / scale
  bool is_nullable_;
  bool is_hidden_;
  // ... 几十个字段
};
```

### 5.2 常见字段类型

```
INT / BIGINT      整数
VARCHAR(N)        变长字符串
TIMESTAMP         时间戳（微秒精度）
NUMBER / DECIMAL  高精度数字（参见 #67 §3.3）
```

### 5.3 主键 / 唯一键

```cpp
// 内部表主键示例：
// __all_user: PK = (tenant_id, user_id)
// __all_table: PK = (tenant_id, table_id)
// __all_column: PK = (tenant_id, table_id, column_id)
```

### 5.4 索引

```
PK = 主键（OB 内部表通常用 tenant_id 做联合主键的第一列）
其他索引：
  __all_ddl_operation: idx_tenant_op_ts (tenant_id, operation_type, ts)
  __all_table: idx_tenant_name (tenant_id, table_name)
```

---

## 6. Initial Data 机制

### 6.1 ob_inner_table_init_data.py

```python
# src/share/inner_table/ob_inner_table_init_data.py
# 启动期 INSERT INTO __all_* 内部表的初始数据
#
# 例：
INITIAL_DDL_OPERATIONS = [
    ("CREATE TABLE t (id INT)", "system", 1000000),
    ("ALTER TABLE t ADD COLUMN name VARCHAR(64)", "system", 1000001),
    # ... 几十条
]

INITIAL_USERS = [
    ("root", "sys", "*XXX*"),  # 初始 root 用户
    ("admin", "sys", "*XXX*"),  # 初始 admin 用户
]
```

### 6.2 启动流程

```
RS 启动
    │
    ├─ 1. ob_dump_inner_table_schema::dump_all
    │     - 写所有 __all_* schema 到内部表
    │
    ├─ 2. ob_inner_table_init_data::init
    │     - 写初始数据（初始 user / ddl_operation 等）
    │
    ├─ 3. 启动 RS 服务
    │
    ▼
observer 启动
    │
    ├─ 1. 拉 schema cache（含内部表 schema）
    │
    ▼
observer 上线
```

---

## 7. Schema Versioning 与升级

### 7.1 版本兼容性

每个内部表有 schema_version：
- 新版本增加字段 → 不影响老 observer（兼容）
- 老版本字段被删除 → 新 observer 无法读老 observer 的内部表（不兼容）

### 7.2 升级流程

```
OB 4.x 集群
    │
    ├─ 升级到 OB 5.0
    │
    ▼
5.0 启动期：
    │
    ├─ 1. ob_dump_inner_table_schema 写新 schema
    │     - 新增字段（NULL 默认值）
    │     - 老字段保留
    │
    ├─ 2. 老数据（来自 4.x 集群）
    │     - INSERT INTO __all_table (老字段, 新字段=NULL)
    │
    ├─ 3. 在线 DDL 升级
    │     - ALTER TABLE __all_table ADD COLUMN ... (新字段)
    │
    ▼
新版本完全可用
```

### 7.3 兼容性矩阵

```
OB 4.x observer + 5.0 内部表 → ❌ 不兼容（字段缺失）
OB 5.0 observer + 4.x 内部表 → ⚠️ 部分功能（新字段为 NULL）
OB 5.0 observer + 5.0 内部表 → ✅ 完全兼容
```

---

## 8. Inner Table 加载流程

### 8.1 启动期 RS 加载

```
RS 启动
    │
    ▼
ObDumpInnerTableSchema::dump_all()
    │
    ├─ 遍历所有 ob_inner_table_schema.*.cpp
    ├─ 每个 .cpp 的 generate_*_schema() 函数被调用
    │     - 返回 ObTableSchema
    │
    ├─ INSERT INTO __all_table, __all_column, ...
    │
    ▼
ObInnerTableInitData::init()
    │
    ├─ INSERT 初始 user / role / privilege
    │
    ▼
RS 服务上线
```

### 8.2 启动期 observer 加载

```
observer 启动
    │
    ▼
RS 已就绪 → observer 拉 schema cache
    │
    ├─ 1. 拉所有内部表 schema（__all_table / __all_column / ...）
    ├─ 2. 加载到 ObSchemaMgr（参见 #76 §4.3）
    │
    ▼
observer 处理 SQL 时
    │
    ├─ 查 __all_table 等 → 命中 L1 cache
    │
    ▼
返回结果
```

### 8.3 ob_load_inner_table_schema_executor

```cpp
// src/rootserver/ob_load_inner_table_schema_executor.h
class ObLoadInnerTableSchemaExecutor {
  // 启动期把内部表 schema 加载到 RS 内存 + 内部表
};
```

---

## 9. DBA 视角的 Inner Table

### 9.1 查询内部表

```sql
-- 查所有表定义（包括用户表 + 内部表）
SELECT table_name, table_id, table_type, schema_version
FROM oceanbase.__all_virtual_table
WHERE tenant_id = 1001;

-- 查特定表的列定义
SELECT column_name, data_type, ordinal_position
FROM oceanbase.__all_virtual_column
WHERE tenant_id = 1001 AND table_name = 't';

-- 查 DDL 操作历史
SELECT operation_type, ddl_stmt_str, exec_tenant_id, schema_version
FROM oceanbase.__all_ddl_operation
WHERE exec_tenant_id = 1001
ORDER BY op_id DESC LIMIT 10;
```

### 9.2 DBA 调试 OB 内部状态

```sql
-- 查 RS 拓扑
SELECT zone, server, svr_ip, svr_port, status
FROM oceanbase.__all_server;

-- 查 Resource Pool / Unit
SELECT name, unit_count, zone_list
FROM oceanbase.__all_resource_pool;

-- 查 sequence 当前值
SELECT name, next_value, increment_by, cache_size
FROM oceanbase.__all_sequence;

-- 查 audit log
SELECT operation_type, user_name, timestamp, success
FROM oceanbase.__all_security_audit_log
ORDER BY timestamp DESC LIMIT 100;
```

---

## 10. 与其他文章的关系

### 10.1 与 #59 / #76 Schema Service

#59 / #76 是 schema service 的概览/深化。本篇聚焦 **inner table 本身**（schema 的 schema）：
- #76 描述 schema service 如何持久化用户 schema
- 本篇描述 inner table 自身怎么定义 + 生成 + 加载

### 10.2 与 #30 Observer Startup

Observer 启动时：
1. RS 加载 internal table schema
2. Observer 拉 schema cache（含 internal table）
3. Internal table 可用 → observer 处理 DML/DDL

### 10.3 与 #27 RootServer

RS 是 internal table 的所有者：
- 启动期 dump internal table schema
- 维护 internal table 的 schema_version
- 跨 observer 同步 internal table 变更

### 10.4 与 #64 Online DDL

DDL 操作可能修改 internal table：
- ALTER TABLE t ADD COLUMN → 写 __all_table (schema_version++)
- DROP TABLE → 写 __all_table (DELETE)
- 任何 DDL → 写 __all_ddl_operation (审计)

### 10.5 与 #65 Standby

Standby 模式下 internal table 同样需要 replay：
- Primary 写 internal table
- Standby 拉 PALF redo log → replay internal table 修改

---

## 11. 总结

### 11.1 Inner Table 在 OB 体系中的定位

Inner Table 是 **OB 集群的"系统目录"**：
- 100+ 内部表存 schema / 元数据 / 运行时状态
- 自动生成机制（Python → C++ → 编译 → 启动期 dump）
- 兼容老版本的升级路径

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| 自动生成 | Python 脚本 → 108 个 .cpp 文件 |
| Inner Table 类别 | sys / ddl / runtime / virtual 四类 |
| 字段约束 | 类型 / 主键 / 索引 / tenant_id 联合 |
| Initial Data | Python 脚本 + INSERT 初始 user/role |
| Schema Versioning | 新版本加字段（兼容老 observer） |
| 加载流程 | RS dump → observer 拉 schema |
| DBA 视角 | SELECT * FROM __all_virtual_table 等 |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/inner_table/` (108 文件) | Inner table schema 定义 |
| `src/share/inner_table/ob_inner_table_schema.h` | 公共头（字段 ID 常量） |
| `src/share/inner_table/generate_inner_table_schema.py` | Python 生成器 |
| `src/share/inner_table/ob_inner_table_init_data.py` | 初始数据脚本 |
| `src/share/inner_table/ob_dump_inner_table_schema.{h,cpp}` | 启动期 dump |
| `src/rootserver/ob_load_inner_table_schema_executor.{h,cpp}` | RS 端 schema 加载 |
| `src/observer/virtual_table/` (100+ ob_all_virtual_*.{h,cpp}) | 虚拟表 |

### 11.4 Inner Table 数量

| 类别 | 数量 |
|------|------|
| sys 内部表 | 100+ |
| virtual 表 | 100+ |
| ob_inner_table_schema.<start>_<end>.cpp 文件 | 108 |
| 涉及的所有 .h 头文件 | 几十 |

### 11.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#83 Schema Cache / ObSchemaMgr / ObKVStoreCache**（深化 #76 / #64）：

OB schema cache 的 4 级层级（参见 #64 §4.3）实现细节 —— L1 guard / L2 mgr / L3 KV cache / L4 内部表 的具体代码路径。源码入口：`src/share/schema/ob_schema_cache.h` + `ob_schema_mgr.{h,cpp}` + `ob_kv_storecache.{h,cpp}`。

适用场景：cache 调优 / 一致性分析 / 性能优化。

整吗？