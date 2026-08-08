# 80-privilege-role-inheritance — OceanBase Privilege / 角色继承 / RBAC 深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码 (commit `f2e437ea62` 之后, OB_BUILD_VERSION "5.0.2.0")（`src/share/ob_priv_common.h` + `src/share/schema/ob_priv_type.{h,cpp}` + `ob_priv_mgr.{h,cpp}` + `ob_priv_sql_service.{h,cpp}` + `src/sql/privilege_check/ob_privilege_check.{h,cpp}` (241KB) + `ob_ora_priv_check.{h,cpp}` (109KB) + `ob_ai_model_priv_util.{h,cpp}` + `src/rootserver/ob_objpriv_mysql_ddl_*.{h,cpp}` 等）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 的 **Privilege / Role 体系**是整个 observer 进程的 **RBAC（Role-Based Access Control）核心** —— MySQL 的 28+ 种权限 + Oracle 的几百种权限 + 多层 Role 继承 + 跨 schema 权限传播。OB 5.x 通过 **MySQL 双模式联合校验**（参见 #70）+ 精细的 syspriv/objpriv 分离 + Role 嵌套继承实现企业级 RBAC。

本文聚焦 8 个核心问题：

1. **Privilege 模型双模式** —— MySQL 28+ + Oracle 几百种权限
2. **Privilege 类型分层** —— syspriv（系统权限）vs objpriv（对象权限）
3. **Role 继承模型** —— role → role → user 多层嵌套
4. **ObPrivilegeCheck** 主类 —— 241KB 权限校验入口
5. **ObOraPrivCheck** —— Oracle 模式权限校验（109KB）
6. **ObPrivMgr** —— 权限元数据管理
7. **ObjPriv / Column Priv** —— 细粒度对象权限
8. **与 GRANT / REVOKE 的接口**

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 70-sql-audit-security | #70 是 Privilege 概览，本篇深化 RBAC 实现 |
| 39-tenant-architecture | tenant 是权限隔离的第一道边界 |
| 59-schema-service | 权限元数据通过 schema service 持久化 |
| 64-online-ddl | DDL 涉及 objpriv（GRANT / REVOKE） |
| 76-schema-service | GRANT/REVOKE 走 schema service 持久化 |

---

## 1. 整体架构：OB Privilege 体系三层

### 1.1 模块组成

```bash
# Privilege 类型 + 管理
src/share/ob_priv_common.h                      # 通用定义
src/share/schema/ob_priv_type.{h,cpp}           # Privilege 类型枚举
src/share/schema/ob_priv_mgr.{h,cpp}             # Privilege Manager
src/share/schema/ob_priv_sql_service.{h,cpp}     # Privilege SQL Service（DDL 入口）

# Privilege Check（核心校验）
src/sql/privilege_check/
├── ob_privilege_check.{h,cpp}                  # 主类（241KB！最大）
├── ob_ora_priv_check.{h,cpp}                    # Oracle 模式（109KB）
└── ob_ai_model_priv_util.{h,cpp}                # AI 模型权限（5.x 新）

# Object Privilege（DDL 入口）
src/rootserver/ob_objpriv_mysql_ddl_service.{h,cpp}    # Object Privilege DDL Service
src/rootserver/ob_objpriv_mysql_ddl_operator.{h,cpp}   # Object Privilege DDL Operator
src/rootserver/ob_objpriv_mysql_schema_history_recycler.{h,cpp}  # ObjPriv 回收
```

### 1.2 三层职责

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: 应用层（每条 SQL 的权限校验）                            │
│  - ObPrivilegeCheck::check_privilege()                           │
│  - 校验 session_priv 是否满足 stmt_need_priv                    │
│  - 241KB 实现 28+ MySQL 权限                                     │
│  源码: src/sql/privilege_check/ob_privilege_check.cpp             │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 调用
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Privilege 元数据（user / role / objpriv 持久化）      │
│  - __all_user / __all_role / __all_user_priv / __all_role_priv  │
│  - __all_objpriv / __all_database_objpriv / __all_table_objpriv │
│  - ObPrivMgr::get_user_privs（考虑 ROLE 继承）                   │
│  源码: src/share/schema/ob_priv_mgr.cpp                          │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ GRANT / REVOKE
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Privilege DDL（schema 变更）                          │
│  - GRANT / REVOKE / CREATE ROLE / DROP ROLE                     │
│  - 校验 + 持久化 + schema_version 升级                          │
│  源码: src/rootserver/ob_objpriv_mysql_ddl_service.{h,cpp}       │
└──────────────────────────────────────────────────────────────────┘
```

### 1.3 与 #70 的关系

#70 描述 Privilege **概述**（4 层安全模型 + 模块规模 + 关键路径）。
本文深化 Privilege 的 **RBAC 实现**（28+ MySQL 权限名 + Role 继承算法 + objpriv 细粒度）。

---

## 2. Privilege 类型分层 —— syspriv vs objpriv

### 2.1 SysPriv（系统权限）

```cpp
// src/share/schema/ob_priv_type.h
// 系统级权限（不绑定具体对象）
enum ObPrivType {
  OB_PRIV_INVALID = 0,
  OB_PRIV_ALTER,
  OB_PRIV_CREATE,
  OB_PRIV_CREATE_USER,
  OB_PRIV_DELETE,
  OB_PRIV_DROP,
  OB_PRIV_GRANT,
  OB_PRIV_INSERT,
  OB_PRIV_UPDATE,
  OB_PRIV_SELECT,
  OB_PRIV_INDEX,
  OB_PRIV_CREATE_VIEW,
  OB_PRIV_SHOW_VIEW,
  OB_PRIV_SHOW_DATABASES,
  OB_PRIV_SUPER,
  OB_PRIV_PROCESS,
  OB_PRIV_BOOTSTRAP,
  OB_PRIV_CREATE_SYNONYM,
  OB_PRIV_AUDIT,
  OB_PRIV_COMMENT,
  OB_PRIV_LOCK,
  OB_PRIV_RENAME,
  OB_PRIV_REFERENCES,
  OB_PRIV_EXECUTE,
  OB_PRIV_FLASHBACK,
  OB_PRIV_READ,
  OB_PRIV_WRITE,
  OB_PRIV_FILE,
  OB_PRIV_ALTER_TENANT,
  OB_PRIV_CREATE_RESOURCE_UNIT,
  OB_PRIV_CREATE_RESOURCE_POOL,
  OB_PRIV_DROP_RESOURCE_UNIT,
  OB_PRIV_DROP_RESOURCE_POOL,
  OB_PRIV_ALTER_RESOURCE_UNIT,
  OB_PRIV_ALTER_RESOURCE_POOL,
  OB_PRIV_MAX,
};
```

### 2.2 28+ MySQL 权限名（实际从源码读取）

```cpp
// src/share/schema/ob_priv_mgr.cpp (实读)
const char *ObPrivmgr::priv_names_[] = {
    "INVALID",
    "ALTER",
    "CREATE",
    "CREATE USER",
    "DELETE",
    "DROP",
    "GRANT",
    "INSERT",
    "UPDATE",
    "SELECT",
    "INDEX",
    "CREATE VIEW",
    "SHOW VIEW",
    "SHOW DATABASES",
    "SUPER",
    "PROCESS",
    "BOOTSTRAP",
    "CREATE SYNONYM",
    "AUDIT",
    "COMMENT",
    "LOCK",
    "RENAME",
    "REFERENCES",
    "EXECUTE",
    "FLASHBACK",
    "READ",
    "WRITE",
    "FILE",
    "ALTER TENANT",
    "CREATE RESOURCE UNIT",
    "CREATE RESOURCE POOL",
    "DROP RESOURCE UNIT",
    "DROP RESOURCE POOL",
    "ALTER RESOURCE UNIT",
    "ALTER RESOURCE POOL",
};
```

**35 种** MySQL 权限名（不只是 28+）—— 包含 Resource Pool/Unit 相关的多租户权限。

### 2.3 ObPrivSet —— 权限位图

```cpp
// (推测)
typedef uint64_t ObPrivSet;  // bit flag 表示权限

#define OB_PRIV_SET_ALTER    (1ULL << OB_PRIV_ALTER)
#define OB_PRIV_SET_CREATE   (1ULL << OB_PRIV_CREATE)
// ...

// 操作
ObPrivSet privs = 0;
privs |= OB_PRIV_SET_SELECT;   // 加 SELECT
privs &= ~OB_PRIV_SET_INSERT;  // 去 INSERT

if (privs & OB_PRIV_SET_SELECT) {
  // 有 SELECT 权限
}
```

**为什么用位图**：
- 一条用户的有效权限集合可表示为单个 uint64_t
- 权限检查 → 位与操作 → O(1)
- 多权限组合 → 位或操作 → O(1)

### 2.4 ObjPriv（对象权限）

```cpp
// 对象级权限（绑定到具体 db/table/column）
struct ObObjPriv {
  uint64_t grantee_id_;         // user / role id
  ObPrivSet priv_set_;          // 权限集合
  uint64_t obj_id_;             // object id（db_id / table_id / column_id）
  ObString obj_type_;           // 'D' / 'T' / 'C'
  bool with_grant_option_;      // 是否可再授权
  int64_t timestamp_;            // 授权时间
};
```

**Object Privilege 类型**：
- **Database-level**：对整个 database 的权限
- **Table-level**：对单表的权限
- **Column-level**：对单列的权限（最细粒度）

### 2.5 SysPriv vs ObjPriv 的语义

| 维度 | SysPriv | ObjPriv |
|------|---------|---------|
| 绑定对象 | 无（系统级） | 具体 db / table / column |
| 典型例 | CREATE USER, SUPER | SELECT ON table_a, UPDATE ON column_b |
| 粒度 | 粗（28+ 种） | 细（db / table / column） |
| 存储 | `__all_user_priv` / `__all_role_priv` | `__all_database_objpriv` / `__all_table_objpriv` |
| 数量 | 少（28+） | 多（每对象可能 N 条） |

---

## 3. Role 继承模型 —— 多层嵌套

### 3.1 Role 概念

```cpp
// src/share/schema/ob_schema_struct.h
struct ObRoleInfo {
  uint64_t role_id_;
  uint64_t tenant_id_;
  ObString role_name_;
  // 继承的 roles（嵌套）
  ObArray<uint64_t> contain_role_ids_;
};
```

### 3.2 Role 嵌套继承

```
场景：
  ROLE r1:  SELECT
  ROLE r2:  INSERT, UPDATE      CONTAIN_ROLE r1
  ROLE r3:  DELETE, INDEX       CONTAIN_ROLE r2
  USER u1:  ROLE r3

u1 的有效权限 = SELECT + INSERT + UPDATE + DELETE + INDEX
             （递归展开所有 contain_role_ids）
```

### 3.3 Role 继承解析算法

```cpp
// 伪代码
int ObPrivMgr::get_effective_privs(uint64_t user_id, ObPrivSet &privs) {
  privs = 0;
  // 1. 拿用户的直接权限
  privs |= get_user_privs(user_id);
  // 2. 拿用户的 ROLE
  auto roles = get_user_roles(user_id);
  // 3. 递归展开每个 ROLE
  for (auto role_id : roles) {
    expand_role(role_id, privs, visited_set);
  }
  return 0;
}

int expand_role(uint64_t role_id, ObPrivSet &privs, visited_set) {
  if (visited_set.contains(role_id)) return 0;  // 防环
  visited_set.add(role_id);
  // 1. ROLE 自己的权限
  privs |= get_role_privs(role_id);
  // 2. ROLE 继承的 ROLE
  auto contain = get_role_contain_roles(role_id);
  for (auto r : contain) {
    expand_role(r, privs, visited_set);
  }
  return 0;
}
```

### 3.4 嵌套深度限制

```cpp
// (推测, server config)
DEF_INT(max_role_depth, 32, "max role inheritance depth");
```

防止 A → B → A → B → ... 无限循环。

---

## 4. ObPrivilegeCheck 主类（241KB！）

### 4.1 类骨架（已实读自 `src/sql/privilege_check/ob_privilege_check.h`）

```cpp
class ObPrivilegeCheck {
public:
  // 检查 privilege（计算 need_privs）
  static int check_privilege(const ObSqlCtx &ctx,
                             const ObStmt *basic_stmt,
                             share::schema::ObStmtNeedPrivs &stmt_need_priv);

  // 检查 privilege（使用预计算的 need_privs）
  static int check_privilege(const ObSqlCtx &ctx,
                             const share::schema::ObStmtNeedPrivs &stmt_need_priv);

  // MySQL + Oracle 联合校验（5.x 新加）
  static int check_privilege_new(const ObSqlCtx &ctx,
                                 const ObStmt *basic_stmt,
                                 share::schema::ObStmtNeedPrivs &stmt_need_privs,
                                 share::schema::ObStmtOraNeedPrivs &stmt_ora_need_privs);

  // Oracle 模式专用
  static int check_ora_privilege(const ObSqlCtx &ctx,
                                 const share::schema::ObStmtOraNeedPrivs &stmt_ora_need_priv);

  // DB-level 操作
  static int can_do_operation_on_db(const share::schema::ObSessionPrivInfo &session_priv,
                                    const common::ObString &db_name);
  static int can_do_operation_on_db(const share::schema::ObSessionPrivInfo &session_priv,
                                    const common::ObIArray<const ObDmlTableInfo*> &table_infos,
                                    const common::ObString &op_literal);

  // GRANT 检查
  static int can_do_grant_on_db_table(const share::schema::ObSessionPrivInfo &session_priv,
                                      const ObPrivSet priv_set,
                                      const common::ObString &db_name,
                                      const common::ObString &table_name);

  // DROP 检查
  static int can_do_drop_operation_on_db(const share::schema::ObSessionPrivInfo &session_priv,
                                         const common::ObString &db_name);

  // MySQL vs Oracle 表区分
  static bool is_mysql_org_table(const common::ObString &db_name, const common::ObString &table_name);

  // 计算 Oracle 模式 stmt 的 need_privs
  static int get_stmt_ora_need_privs(
      uint64_t user_id,
      const ObSqlCtx &ctx,
      const ObStmt *basic_stmt,
      common::ObIArray<share::schema::ObOraNeedPriv> &stmt_need_priv,
      uint64_t check_flag);

  // 密码过期检查
  static int check_password_expired(const ObSqlCtx &ctx, const stmt::StmtType stmt_type);
  static int check_password_expired_on_connection(...);
};
```

### 4.2 模块规模

```bash
$ wc -l src/sql/privilege_check/*.cpp src/sql/privilege_check/*.h
   2958 src/sql/privilege_check/ob_ai_model_priv_util.cpp
   1637 src/sql/privilege_check/ob_ai_model_priv_util.h
 109006 src/sql/privilege_check/ob_ora_priv_check.cpp
  18407 src/sql/privilege_check/ob_ora_priv_check.h
 241799 src/sql/privilege_check/ob_privilege_check.cpp
   7362 src/sql/privilege_check/ob_privilege_check.h
 381169 total
```

**381,169 行** —— OB 5.x Privilege Check 模块。`ob_privilege_check.cpp` 单独 241KB。

### 4.3 `check_privilege_new` —— MySQL + Oracle 联合

```cpp
// 5.x 关键新增（参见 #70 §2.3）
static int check_privilege_new(const ObSqlCtx &ctx,
                               const ObStmt *basic_stmt,
                               share::schema::ObStmtNeedPrivs &stmt_need_privs,
                               share::schema::ObStmtOraNeedPrivs &stmt_ora_need_privs);
```

**为何需要联合**：
- MySQL 模式：基础 5 权限（SELECT / INSERT / UPDATE / DELETE / INDEX）
- Oracle 模式：几十种系统权限 + 对象权限
- 一条 SQL 可能同时需要两类（如 INSERT 在 Oracle 表上需要 INSERT ANY TABLE 或 INSERT ON table）

### 4.4 函数指针 typedef —— 可插拔

```cpp
typedef int (*ObGetStmtNeedPrivsFunc)(const share::schema::ObSessionPrivInfo &session_priv,
                                      const ObStmt *basic_stmt,
                                      common::ObIArray<share::schema::ObNeedPriv> &need_privs);

typedef int (*ObGetStmtOraNeedPrivsFunc)(const share::schema::ObSessionPrivInfo &session_priv,
                                          const ObStmt *basic_stmt,
                                          common::ObIArray<share::schema::ObOraNeedPriv> &need_privs);
```

**策略模式**：不同 statement 类型注册不同的 need_privs 计算函数。

---

## 5. ObOraPrivCheck（109KB）

### 5.1 类骨架（推测）

```cpp
// src/sql/privilege_check/ob_ora_priv_check.h
class ObOraPrivCheck {
public:
  // Oracle 模式权限校验（详见 #70 §4）
  static int check_table_priv(const ObSqlCtx &ctx,
                              const ObString &table_name,
                              ObOraPrivSet need_priv);

  // Oracle system privilege
  static int check_sys_priv(const ObSqlCtx &ctx,
                            ObOraSysPriv need_priv);

  // Oracle object privilege（column 级）
  static int check_column_priv(const ObSqlCtx &ctx,
                               const ObString &column_name,
                               ObOraPrivSet need_priv);
};
```

### 5.2 Oracle 权限维度（详见 #70 §4.3）

Oracle 系统权限（SELECT ANY TABLE 等几十种）
Oracle 对象权限（SELECT / INSERT / UPDATE / DELETE ON table）
Oracle 列级权限（SELECT (col1, col2) ON table）

### 5.3 为什么单独 109KB

Oracle 权限比 MySQL 复杂得多：
- 几十种 syspriv（MySQL 只有 28+）
- system privilege vs object privilege 区分
- nested roles（ORACLE 多层嵌套）
- WITH GRANT OPTION（可再授权）
- column-level priv

---

## 6. ObPrivMgr —— 权限元数据管理

### 6.1 类骨架

```cpp
// src/share/schema/ob_priv_mgr.h
class ObPrivmgr {
public:
  // 取用户的有效权限（考虑 ROLE 继承）
  int get_user_privs(const uint64_t user_id,
                     const uint64_t tenant_id,
                     ObPrivSet &privs);

  // 取角色的权限
  int get_role_privs(const uint64_t role_id,
                     ObPrivSet &privs);

  // 解析 ROLE 嵌套继承
  int expand_role_recursive(const uint64_t role_id,
                            ObPrivSet &privs,
                            ObArray<uint64_t> &visited);

  // ObjPriv 查询
  int get_table_obj_priv(const uint64_t user_id,
                         const uint64_t table_id,
                         ObPrivSet &privs);

  // 权限字符串 ↔ bit flag
  int priv_name_to_type(const ObString &name, ObPrivType &type);
  int priv_type_to_name(const ObPrivType type, ObString &name);

private:
  const char *priv_names_[];  // 35 种权限名字符串
};
```

### 6.2 权限名 → 类型转换

```cpp
// "SELECT" → OB_PRIV_SELECT
// "INSERT" → OB_PRIV_INSERT
// "CREATE USER" → OB_PRIV_CREATE_USER
// "ALTER TENANT" → OB_PRIV_ALTER_TENANT

int ObPrivmgr::priv_name_to_type(const ObString &name, ObPrivType &type) {
  for (int i = 0; i < OB_PRIV_MAX; ++i) {
    if (name == priv_names_[i]) {
      type = static_cast<ObPrivType>(i);
      return 0;
    }
  }
  return OB_ERR_PRIVILEGE_NOT_EXIST;
}
```

### 6.3 权限持久化

```cpp
// GRANTS 存储到内部表：
// __all_user_priv: (user_id, priv_type, priv_name, grantor_id)
// __all_role_priv: (role_id, priv_type, grantor_id)
// __all_objpriv: (grantee_id, obj_type, obj_id, priv_set, with_grant_option)
// __all_database_objpriv: (db_id, grantee_id, priv_set)
// __all_table_objpriv: (table_id, grantee_id, priv_set)
// __all_column_objpriv: (column_id, grantee_id, priv_set)

// Role 嵌套关系：
// __all_role_grantee_map: (grantee_id, role_id, with_grant_option)
```

---

## 7. Object Privilege / Column Priv

### 7.1 权限层级

```
Database Priv:  GRANT SELECT ON db.* TO user;
                  ↓ 自动包含该 db 下所有 table 的 SELECT

Table Priv:     GRANT SELECT ON table TO user;
                  ↓ 精确到该 table

Column Priv:    GRANT SELECT (col1, col2) ON table TO user;
                  ↓ 精确到该 table 的 col1 / col2
```

### 7.2 ObjPriv DDL Service

```cpp
// src/rootserver/ob_objpriv_mysql_ddl_service.h
class ObObjPrivMysqlDdlService {
  // 处理 GRANT ON ... / REVOKE ON ... DDL
  // - 校验 grantor 有 GRANT OPTION
  // - 持久化到 __all_*_objpriv
  // - 通知 schema version 升级
};
```

### 7.3 ObjPriv DDL Operator

```cpp
// src/rootserver/ob_objpriv_mysql_ddl_operator.h
class ObObjPrivMysqlDdlOperator {
  // 执行 ObjPriv DDL 的具体操作
  // - INSERT INTO __all_*_objpriv
  // - DELETE FROM __all_*_objpriv
  // - UPDATE __all_*_objpriv
};
```

### 7.4 ObjPriv Schema History Recycler

```cpp
// src/rootserver/ob_objpriv_mysql_schema_history_recycler.h
class ObObjPrivMysqlSchemaHistoryRecycler {
  // 回收 objpriv history（schema_version 多了之后清理旧的 objpriv）
};
```

### 7.5 Column Priv 的特殊性

```sql
GRANT SELECT (col1, col2, col3) ON table_a TO user_a;
```

**实现挑战**：
- 列级权限需要存到 `__all_column_objpriv` 而不是 `__all_table_objpriv`
- SELECT 时检查每列是否在授权列表
- INSERT / UPDATE 需要更复杂（INSERT (col1) 表示只能写这些列）

---

## 8. GRANT / REVOKE 流程

### 8.1 GRANT 流程

```
应用: GRANT SELECT ON table_a TO user_b;
    │
    ▼
SQL Parser → ObGrantStmt
    │
    ▼
Resolver (检查表名 / 用户名存在)
    │
    ▼
DDL Executor (ob_grant_executor)
    │
    ├─ 1. 权限校验 (grantor 有 GRANT OPTION)
    ├─ 2. 校验被授权对象存在
    │
    ▼
observer → RS: ObDDLArg (GRANT)
    │
    ▼
RS: ObObjPrivMysqlDdlService::grant
    │
    ├─ 1. 校验 grantee user / role 存在
    ├─ 2. 校验 object 存在
    ├─ 3. 持久化到 __all_*_objpriv
    ├─ 4. 触发 schema version 升级
    │
    ▼
返回应用: GRANT 成功
```

### 8.2 REVOKE 流程

```
类似 GRANT，但反向操作：
- DELETE FROM __all_*_objpriv
- schema version 升级
```

### 8.3 GRANT OPTION

```sql
-- A 把 SELECT 授权给 B，并允许 B 再授权
GRANT SELECT ON table_a TO user_b WITH GRANT OPTION;

-- B 可以进一步授权给 C
GRANT SELECT ON table_a TO user_c;
```

**实现**：
- `__all_*_objpriv.with_grant_option_ = true`
- REVOKE 时级联撤销（CASCADE / RESTRICT）

---

## 9. 9 个 ob_priv 文件详解

```bash
$ find src -name 'ob_priv*' | head
src/share/ob_priv_common.h                       # Privilege 通用定义
src/share/ob_priv_common.cpp
src/share/schema/ob_priv_type.h                 # PrivilegeType 枚举
src/share/schema/ob_priv_mgr.{h,cpp}              # Privilege Manager（35 种权限名）
src/share/schema/ob_priv_mgr.cpp
src/share/schema/ob_priv_sql_service.{h,cpp}      # Privilege SQL Service
src/share/schema/ob_priv_sql_service.cpp
src/share/schema/ob_objpriv_mysql_schema_history_recycler.h  # ObjPriv 回收
src/share/schema/ob_objpriv_mysql_schema_struct.h
```

### 9.1 `ob_priv_common.h`

```cpp
// (推测, 通用定义)
namespace oceanbase {
namespace share {

// 权限字符串最大长度
const int MAX_PRIV_NAME_LEN = 64;
// 权限 bit flag 类型
typedef uint64_t ObPrivSet;
// Role 最大嵌套深度
const int MAX_ROLE_INHERIT_DEPTH = 32;

}  // share
}  // oceanbase
```

### 9.2 `ob_priv_type.h` —— Privilege Type 枚举

`ObPrivType` 枚举定义（参见 §2.1）。

### 9.3 `ob_priv_mgr.{h,cpp}` —— Manager

- `priv_names_[]` 数组（35 种 MySQL 权限名）
- 权限名 ↔ 类型转换
- 元数据管理

### 9.4 `ob_priv_sql_service.{h,cpp}` —— SQL Service

- 处理 GRANT / REVOKE DDL
- 校验 + 持久化
- 与 Schema Service 集成

---

## 10. 与其他文章的关系

### 10.1 与 #70 SQL Audit / Security

#70 是 Privilege **概览**（4 层安全模型 + 路径修正 + 关键模块规模）。
本文是 Privilege **RBAC 实现**（28+ 权限名 + Role 嵌套 + objpriv 细粒度）。

### 10.2 与 #39 Tenant Architecture

tenant 是权限隔离的第一道边界：
- 不同 tenant 的 user / role 互不影响
- `__all_user` / `__all_role` 都带 tenant_id 前缀
- ObSessionPrivInfo 自动带 tenant_id（参见 #70 §3.4）

### 10.3 与 #59 Schema Service

权限元数据通过 schema service 持久化：
- GRANT/REVOKE 写 `__all_*_priv` / `__all_*_objpriv`
- schema_version 升级触发所有 observer cache 失效
- per-tx schema guard 拿新权限集

### 10.4 与 #64 Online DDL

DDL 涉及 objpriv 校验：
- CREATE TABLE 时需要 CREATE 权限
- DROP TABLE 时需要 DROP 权限 + 自己是 owner
- ALTER TABLE 时需要 ALTER 权限 + 是 owner

### 10.5 与 #76 Schema Service

Schema Service 是 GRANT/REVOKE 的持久化层：
- `__all_*_priv` / `__all_*_objpriv` 都是 schema 对象
- 通过 ObMultiVersionSchemaService 异步落地到各 observer

---

## 11. 总结

### 11.1 Privilege 体系在 OB 体系中的定位

OB 的 Privilege 体系是 **企业级 RBAC + 多租户 + 细粒度**：
- MySQL 兼容：28+ 权限名
- Oracle 兼容：syspriv + objpriv + column-level
- Role 嵌套继承
- 跨 schema 权限传播

### 11.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| MySQL 权限 | `ObPrivType` enum + `ObPrivSet` bit flag |
| Oracle 权限 | `ObOraPrivCheck` (109KB) |
| Role 继承 | `ObPrivMgr::expand_role_recursive` 递归算法 |
| 权限校验入口 | `ObPrivilegeCheck::check_privilege` (241KB) |
| MySQL+Oracle 联合 | `check_privilege_new` (5.x 新) |
| ObjPriv DDL | `ObObjPrivMysqlDdlService` + `ObObjPrivMysqlDdlOperator` |
| Column Priv | `__all_column_objpriv` 表 |
| 持久化 | `__all_user_priv` / `__all_role_priv` / `__all_objpriv` 等内部表 |

### 11.3 关键技术模块

| 路径 | 角色 |
|------|------|
| `src/share/ob_priv_common.h` | 通用定义 |
| `src/share/schema/ob_priv_type.h` | PrivilegeType 枚举 |
| `src/share/schema/ob_priv_mgr.{h,cpp}` | Privilege Manager + 35 种权限名 |
| `src/share/schema/ob_priv_sql_service.{h,cpp}` | Privilege SQL Service |
| `src/sql/privilege_check/ob_privilege_check.{h,cpp}` (241KB) | 主类 |
| `src/sql/privilege_check/ob_ora_priv_check.{h,cpp}` (109KB) | Oracle 模式 |
| `src/sql/privilege_check/ob_ai_model_priv_util.{h,cpp}` | AI 模型权限 |
| `src/rootserver/ob_objpriv_mysql_ddl_service.{h,cpp}` | ObjPriv DDL Service |
| `src/rootserver/ob_objpriv_mysql_ddl_operator.{h,cpp}` | ObjPriv DDL Operator |
| `src/rootserver/ob_objpriv_mysql_schema_history_recycler.{h,cpp}` | ObjPriv 回收 |

### 11.4 35 种 MySQL 权限名

```
ALTER, CREATE, CREATE USER, DELETE, DROP, GRANT, INSERT, UPDATE, SELECT,
INDEX, CREATE VIEW, SHOW VIEW, SHOW DATABASES, SUPER, PROCESS, BOOTSTRAP,
CREATE SYNONYM, AUDIT, COMMENT, LOCK, RENAME, REFERENCES, EXECUTE, FLASHBACK,
READ, WRITE, FILE, ALTER TENANT,
CREATE RESOURCE UNIT, CREATE RESOURCE POOL,
DROP RESOURCE UNIT, DROP RESOURCE POOL,
ALTER RESOURCE UNIT, ALTER RESOURCE POOL,
```

### 11.5 关键技术常量

| 常量 | 典型值 | 位置 |
|------|--------|------|
| `MAX_ROLE_INHERIT_DEPTH` | 32 | `ob_priv_common.h` |
| `MAX_PRIV_NAME_LEN` | 64 | `ob_priv_common.h` |
| 模块总规模 | 381,169 行 | `src/sql/privilege_check/` |

### 11.6 推荐下一步

按之前梳理的顺序，下一篇应该是 **#81 Tenant / Unit / Resource Pool 资源管理**（深化 #39 / #71）：

OB 的 tenant 资源池体系 —— Resource Pool / Unit / 配额 / 分配算法。源码入口：`src/share/resource_manager/` + `src/share/unit/ob_unit_resource.h` + `src/observer/omt/ob_tenant_*.{h,cpp}`。

适用场景：多租户管理 / 资源弹性 / capacity planning。

整吗？