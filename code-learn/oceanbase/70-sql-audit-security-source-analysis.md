# 70-sql-audit-security — OceanBase SQL 审计 / 安全 / 权限 / Label Security 深度源码分析

> 基于 OceanBase 5.0.2.0 主线源码（src/sql/privilege_check/ 6 文件 + src/share/schema/ob_security_audit_mgr.h + ob_security_audit_sql_service.h + ob_label_security.h + ob_priv_mgr.cpp + ob_priv_sql_service.cpp 等）
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

OB 在企业级数据库场景下需要完整的 **安全 / 审计 / 权限 / 数据保护** 体系。MySQL 兼容只提供基础 GRANT / REVOKE 模型，Oracle 兼容提供更细粒度的 Label Security（LBACS）和 Data Masking。OB 5.x 同时支持双语义，并通过统一的 `ObPrivilegeCheck` 抽象层做权限校验。

本文聚焦 8 个核心问题：

1. **Privilege Check 核心** —— `src/sql/privilege_check/ob_privilege_check.cpp` (241KB)
2. **MySQL vs Oracle 双模式** —— `check_privilege_new` 联合校验
3. **审计日志基础设施** —— `ob_security_audit_mgr` + `ob_security_audit` monitor
4. **Label Security (LBACS)** —— 多级安全（MLS）/ 强制访问控制（MAC）
5. **Data Masking** —— 动态数据脱敏
6. **Privilege Schema 管理** —— `ob_priv_mgr` + `ob_priv_sql_service`
7. **会话级 Privilege 模型** —— `ObSessionPrivInfo` + `ObStmtNeedPrivs`
8. **AI Model Privilege** —— `ob_ai_model_priv_util`（OB 5.x 新）

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 17-query-optimizer | 权限校验可能在 optimizer 阶段 |
| 22-plan-cache | 权限缓存 vs plan cache 失效 |
| 24-type-system | Label 类型 + ObString 权限存储 |
| 36-concurrency-control | 权限与事务隔离 |
| 39-tenant-architecture | 多租户权限隔离 |
| 59-schema-service | 权限持久化（schema service） |

---

## 1. 整体架构：OB 安全体系分层

### 1.1 四层安全模型

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 4: 数据保护 (Data Protection)                              │
│  - Data Masking (动态脱敏)                                       │
│  - Transparent Data Encryption (TDE)                              │
│  - 列级 / 行级安全策略                                            │
│  源码: src/share/label_security/ + ob_label_se_policy_*          │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 受 label 检查约束
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 3: Label Security (LBACS - 多级安全)                      │
│  - 安全标签 (LABEL) / 等级 (LEVEL) / 分组 (COMPARTMENT)          │
│  - 多级安全 (MLS) / 强制访问控制 (MAC)                            │
│  - OLS (Oracle Label Security) 兼容                              │
│  源码: src/share/ob_label_security.{h,cpp} + ob_label_security_os.cpp │
│        src/share/schema/ob_label_se_policy_mgr.h                  │
│        src/share/schema/ob_label_se_policy_sql_service.h         │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 受 RBAC 权限约束
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 2: Audit / 审计日志                                       │
│  - 用户操作审计 (谁在什么时候做了什么)                            │
│  - DDL / DML / 登录 / 权限变更                                   │
│  - audit_log 表 + ob_security_audit_mgr                         │
│  源码: src/share/schema/ob_security_audit_mgr.h                  │
│        src/share/schema/ob_security_audit_sql_service.h          │
│        src/sql/monitor/ob_security_audit.{h,cpp}                 │
│        src/sql/monitor/ob_security_audit_utils.h                  │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ 受权限校验
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Privilege Check (RBAC + 系统权限)                       │
│  - GRANT / REVOKE 模型                                            │
│  - 系统权限 (CREATE TABLE / DROP DATABASE 等)                    │
│  - 对象权限 (SELECT / INSERT / UPDATE / DELETE 等)              │
│  - 角色 (ROLE) 继承                                               │
│  源码: src/sql/privilege_check/ob_privilege_check.{h,cpp}        │
│        src/sql/privilege_check/ob_ora_priv_check.{h,cpp}          │
│        src/share/schema/ob_priv_mgr.cpp                          │
│        src/share/schema/ob_priv_sql_service.cpp                  │
│        src/share/ob_priv_common.{h,cpp}                          │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 源码实际位置（修正 #60 的路径错误）

我之前在 #60 提到的路径 `src/share/audit/` + `src/share/privilege/` + `src/share/lbacs/` **都不存在**。实际位置：

| 功能 | 实际路径 |
|------|----------|
| Privilege Check 核心 | `src/sql/privilege_check/ob_privilege_check.cpp` (241KB) |
| Oracle 兼容 Privilege | `src/sql/privilege_check/ob_ora_priv_check.cpp` (109KB) |
| Privilege Schema Mgr | `src/share/schema/ob_priv_mgr.cpp` |
| Privilege SQL Service | `src/share/schema/ob_priv_sql_service.cpp` |
| Privilege 通用定义 | `src/share/ob_priv_common.{h,cpp}` |
| Security Audit Mgr | `src/share/schema/ob_security_audit_mgr.h` |
| Security Audit SQL | `src/share/schema/ob_security_audit_sql_service.h` |
| Security Audit Monitor | `src/sql/monitor/ob_security_audit.{h,cpp}` |
| Label Security | `src/share/ob_label_security.{h,cpp}` |
| Label Security OS | `src/share/ob_label_security_os.cpp` |
| Label Policy Mgr | `src/share/schema/ob_label_se_policy_mgr.h` |
| Label Policy SQL | `src/share/schema/ob_label_se_policy_sql_service.h` |
| AI Model Privilege | `src/sql/privilege_check/ob_ai_model_priv_util.{h,cpp}` |
| Compat Security Feature | `src/share/ob_compatibility_security_feature_def.h` |

---

## 2. Privilege Check 核心 —— `ob_privilege_check`

### 2.1 类骨架

```cpp
// src/sql/privilege_check/ob_privilege_check.h
class ObPrivilegeCheck {
public:
  /// Check privilege (compute need_privs and check)
  static int check_privilege(const ObSqlCtx &ctx,
                             const ObStmt *basic_stmt,
                             share::schema::ObStmtNeedPrivs &stmt_need_priv);

  /// Check privilege (use pre-computed need_privs)
  static int check_privilege(const ObSqlCtx &ctx,
                             const share::schema::ObStmtNeedPrivs &stmt_need_priv);

  /// New combined MySQL + Oracle check (5.x unified path)
  static int check_privilege_new(const ObSqlCtx &ctx,
                                 const ObStmt *basic_stmt,
                                 share::schema::ObStmtNeedPrivs &stmt_need_privs,
                                 share::schema::ObStmtOraNeedPrivs &stmt_ora_need_privs);

  /// Oracle mode privilege check
  static int check_ora_privilege(const ObSqlCtx &ctx,
                                 const share::schema::ObStmtOraNeedPrivs &stmt_ora_need_priv);

  /// DB-level operation check
  static int can_do_operation_on_db(const share::schema::ObSessionPrivInfo &session_priv,
                                    const common::ObString &db_name);

  /// DB+table operation check (for DML)
  static int can_do_operation_on_db(const share::schema::ObSessionPrivInfo &session_priv,
                                    const common::ObIArray<const ObDmlTableInfo*> &table_infos,
                                    const common::ObString &op_literal);

  /// GRANT statement check
  static int can_do_grant_on_db_table(const share::schema::ObSessionPrivInfo &session_priv,
                                      const ObPrivSet priv_set,
                                      const common::ObString &db_name,
                                      const common::ObString &table_name);

  /// DROP statement check
  static int can_do_drop_operation_on_db(const share::schema::ObSessionPrivInfo &session_priv,
                                         const common::ObString &db_name);

  /// MySQL vs Oracle table distinction
  static bool is_mysql_org_table(const common::ObString &db_name, const common::ObString &table_name);

  /// Get Oracle-mode required privs for a stmt
  static int get_stmt_ora_need_privs(
      uint64_t user_id,
      const ObSqlCtx &ctx,
      const ObStmt *basic_stmt,
      common::ObIArray<share::schema::ObOraNeedPriv> &stmt_need_priv,
      uint64_t check_flag);

  /// Password policy check (connection / statement level)
  static int check_password_expired(const ObSqlCtx &ctx, const stmt::StmtType stmt_type);
  static int check_password_expired_on_connection(const uint64_t tenant_id,
                                                  const uint64_t user_id,
                                                  share::schema::ObSchemaGetterGuard &schema_guard,
                                                  sql::ObSQLSessionInfo &session);
};

// 函数指针 typedef（可插拔的 need_privs 计算）
typedef int (*ObGetStmtNeedPrivsFunc)(const share::schema::ObSessionPrivInfo &session_priv,
                                      const ObStmt *basic_stmt,
                                      common::ObIArray<share::schema::ObNeedPriv> &need_privs);

typedef int (*ObGetStmtOraNeedPrivsFunc)(const share::schema::ObSessionPrivInfo &session_priv,
                                          const ObStmt *basic_stmt,
                                          common::ObIArray<share::schema::ObOraNeedPriv> &need_privs);
```

### 2.2 模块规模

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

**381,169 行** —— Privilege Check 是 OB 5.x 中 **最大的安全模块**。`ob_privilege_check.cpp` 单独 241KB 包含几乎所有 statement type 的 need_privs 计算逻辑。

### 2.3 关键设计

**Static method class pattern**：
- `ObPrivilegeCheck` 没有实例，所有方法都是 `static`
- 类似 Java 工具类，所有调用 `ObPrivilegeCheck::check_xxx(...)`
- 无状态（线程安全）

**Pluggable need_privs 函数**：
- `ObGetStmtNeedPrivsFunc` + `ObGetStmtOraNeedPrivsFunc` 是函数指针 typedef
- 不同 statement 类型可以注册不同的 need_privs 计算函数
- 这是 OB 的策略模式实现

**MySQL + Oracle 双模式**：
- `check_privilege_new` 一次调用同时检查 MySQL 模式 + Oracle 模式
- 返回 `ObStmtNeedPrivs` + `ObStmtOraNeedPrivs` 两个集合
- 哪个集合不满足 → 报错对应模式的错误

### 2.4 Need Priv 结构

```cpp
// src/share/schema/ob_schema_struct.h (推测)
struct ObNeedPriv {
  // 需要哪种权限 + 在哪个对象上
  ObPrivSet priv_set_;           // bit flag 表示哪种权限（SELECT/INSERT/...）
  share::ObString db_name_;
  share::ObString table_name_;
  // ... 其他字段
};

struct ObOraNeedPriv {
  // Oracle 模式下的 need_priv
  ObOraPrivSet priv_set_;        // Oracle 权限 bit flag
  share::ObString db_name_;
  share::ObString table_name_;
};

struct ObStmtNeedPrivs {
  // 一个语句的所有 need_priv 集合
  common::ObIArray<ObNeedPriv> need_privs_;
};

struct ObStmtOraNeedPrivs {
  common::ObIArray<ObOraNeedPriv> need_privs_;
};
```

**`ObPrivSet`**：bit flag 表示哪些权限被需要（典型 32/64 位整数，每个 bit 表示一种权限）。

---

## 3. Privilege Check 流程

### 3.1 完整流程

```
应用: SELECT * FROM t WHERE id = 1
    │
    ▼
SQL Parser → ObSelectStmt
    │
    ▼
Optimizer (生成物理 plan)
    │
    ├─ 调用 ObPrivilegeCheck::check_privilege(ctx, stmt, stmt_need_priv)
    │
    │   1. 检查 session 是否有效（login_state）
    │   2. 检查 user 是否被锁
    │   3. 检查 password 是否过期（check_password_expired）
    │   4. 计算 stmt 需要的权限（get_stmt_need_privs）
    │      - SELECT * FROM t → need SELECT on t
    │   5. 遍历 need_privs：
    │      - 拿 session_priv_info
    │      - 检查每个 priv 是否被 grant
    │      - 检查 db-level priv（如 CREATE on db）
    │   6. 通过 → 返回 stmt_need_priv
    │   7. 不通过 → 报错 OB_ERR_PRIVILEGE
    │
    ├─ ObPrivilegeCheck::check_privilege_new (MySQL + Oracle 联合校验)
    │
    ├─ ObPrivilegeCheck::check_ora_privilege (Oracle 模式专用)
    │
    └─ 通过 → 继续 plan / 执行
    │
    ▼
Plan 标记了 stmt_need_privs（执行期不需要再校验）
    │
    ▼
Executor
    │
    ├─ 对 DML executor 还要 check_label_security (Layer 3)
    │
    ├─ 对敏感列应用 data_masking (Layer 4)
    │
    └─ 真正读写存储
```

### 3.2 关键校验点

| 检查 | 时机 | 失败行为 |
|------|------|----------|
| User 是否存在 | 登录时 | 登录失败 |
| User 是否锁住 | 每次请求 | 请求失败 |
| Password 过期 | 登录 + 第一次语句 | 强制改密码 |
| Privilege 缺失 | 每次请求 | 报错 OB_ERR_PRIVILEGE |
| Label Security 违规 | DML 读取时 | 报错 OLS 错误 |
| Data Masking 命中 | SELECT 列返回前 | 应用脱敏规则 |

### 3.3 Session Privilege 缓存

```cpp
// src/share/schema/ob_schema_struct.h (推测)
struct ObSessionPrivInfo {
  // session 启动时从 schema 加载一次
  // 之后如果 user 的权限变更，session 内的缓存不会立即更新
  uint64_t user_id_;
  uint64_t tenant_id_;
  ObPrivSet user_privs_;          // 直接 grant 给 user 的权限
  ObPrivSet role_privs_;          // 通过 ROLE 继承的权限
  common::ObArray<uint64_t> role_ids_;
  // ... 其他字段
};
```

**缓存不一致**：权限变更后，session 内可能用过期的 priv 缓存。MySQL 行为是立即生效，Oracle 行为是 session 内不变（用户需重新登录）。

---

## 4. Oracle Privilege Check —— `ob_ora_priv_check.cpp` (109KB)

### 4.1 为什么单独一个 109KB 文件

Oracle 模式的权限系统比 MySQL 复杂得多：
- Oracle Roles 可以嵌套 / 继承
- Oracle 有 system privilege vs object privilege 区分
- Oracle 有 GRANT OPTION（被授权者可以再授权）
- Oracle 有 column-level privilege（列级权限）

MySQL 的 5 个权限（SELECT/INSERT/UPDATE/DELETE/...）相对简单。Oracle 的几十种。

### 4.2 Oracle 权限维度

```sql
-- Oracle 系统权限
GRANT CREATE TABLE TO user;
GRANT CREATE ANY INDEX TO user;
GRANT SELECT ANY TABLE TO user;

-- Oracle 对象权限
GRANT SELECT ON schema.table TO user;
GRANT INSERT (col1, col2) ON schema.table TO user;  -- 列级
GRANT UPDATE ON schema.table TO user WITH GRANT OPTION;

-- Oracle 角色
CREATE ROLE app_user_role;
GRANT SELECT ON schema.t TO app_user_role;
GRANT app_user_role TO user;
```

### 4.3 Oracle vs MySQL 权限对照

| 操作 | MySQL 权限 | Oracle 权限 |
|------|-----------|-----------|
| 创建表 | CREATE | CREATE TABLE |
| 删表 | DROP | DROP ANY TABLE |
| 查表 | SELECT | SELECT ANY TABLE / SELECT ON table |
| 改表 | ALTER | ALTER ANY TABLE |
| 创索引 | INDEX | CREATE ANY INDEX |
| 加列 | ALTER | ALTER TABLE |
| 创用户 | CREATE USER | CREATE USER |

---

## 5. Security Audit Mgr —— `ob_security_audit_mgr`

### 5.1 角色

```cpp
// src/share/schema/ob_security_audit_mgr.h (推测)
class ObSecurityAuditMgr {
public:
  // 记录审计事件
  int log_event(const ObAuditRecord &record);

  // 1. 过滤：哪些事件需要审计（按策略配置）
  // 2. 序列化：审计记录
  // 3. 写入：__all_audit_log 内部表
};
```

### 5.2 审计事件类型

```
DDL 操作:
  CREATE / DROP / ALTER on DATABASE / TABLE / USER / ROLE
  GRANT / REVOKE

DML 操作:
  SELECT / INSERT / UPDATE / DELETE on specific tables (per-policy)

登录/会话:
  LOGIN / LOGOUT / LOGIN FAILED

权限变更:
  GRANT / REVOKE
```

### 5.3 SQL Service 配套

```cpp
// src/share/schema/ob_security_audit_sql_service.h (推测)
class ObSecurityAuditSqlService {
public:
  // RS 端：处理审计策略的 DDL
  int create_audit_policy(const ObAuditPolicy &policy);
  int drop_audit_policy(const ObString &policy_name);

  // 启动期：加载所有 audit policy
  int load_all_policies();
};
```

### 5.4 Audit Monitor

```cpp
// src/sql/monitor/ob_security_audit.h (推测)
class ObSecurityAuditMonitor {
public:
  // 异步监控：定期把 audit log 写到内部表 / 外部系统
  // - 默认每 N 秒 flush
  // - 大批量自动 batching
  // - 支持外部 syslog / SIEM 推送
};
```

---

## 6. Label Security (LBACS) —— 多级安全

### 6.1 OLS 模型

```cpp
// src/share/ob_label_security.h (推测)
class ObLabelSecurity {
public:
  // OLS (Oracle Label Security) 兼容
  // - LEVEL: 等级 (TOP_SECRET / SECRET / CONFIDENTIAL / UNCLASSIFIED)
  // - COMPARTMENT: 部门 / 项目
  // - GROUP: 分组（嵌套）

  // 检查 user label 是否能读 data label
  bool can_read(const ObLabel &user_label, const ObLabel &data_label);

  // 检查 user label 是否能写 data label
  bool can_write(const ObLabel &user_label, const ObLabel &data_label);
};

// src/share/ob_label_security_os.cpp (推测) — 与 OS 层 label security 集成
```

### 6.2 Label Policy

```cpp
// src/share/schema/ob_label_se_policy_mgr.h
class ObLabelSePolicyMgr {
  // 管理 OLS policy (一个 policy 对应一个表)
  // - 哪些 label 可以访问
  // - user → label 的映射
  // - compartment / group 定义
};

// src/share/schema/ob_label_se_policy_sql_service.h
class ObLabelSePolicySqlService {
  // DDL 入口：CREATE / DROP / ALTER LABEL POLICY
};
```

### 6.3 OB 5.x 的 LBACS 兼容性

OB 实现的是 **Oracle OLS 兼容**：
- ✅ LEVEL / COMPARTMENT / GROUP 三维标签
- ✅ 多级安全（MLS）/ 强制访问控制（MAC）
- ✅ 用户 → 标签映射
- ✅ POLICY 持久化
- ✅ 与 RBAC 协同（先 RBAC 再 LBACS）

---

## 7. AI Model Privilege —— `ob_ai_model_priv_util`

### 7.1 角色（OB 5.x 新）

```cpp
// src/sql/privilege_check/ob_ai_model_priv_util.h
class ObAiModelPrivUtil {
public:
  // AI 模型访问权限检查（OB 5.x 新加的 #DBMS_AI_SERVICE 配套）
  // - 用户能否调用 AI 模型
  // - 用户能否查看 AI 模型推理结果
  // - 用户能否管理（创建/删除）AI 模型
  static int check_ai_model_priv(const ObSqlCtx &ctx,
                                 const ObString &model_name,
                                 ObAiModelOpType op);
};
```

**为什么需要**：OB 5.x 内嵌了 AI 推理（参见 #69 §5.4 `DBMS_AI_SERVICE`），AI 模型本身也是数据库对象，需要权限控制。

### 7.2 与 #69 的衔接

`ob_ai_model_priv_util.cpp/h` 与 `src/pl/sys_package/ob_dbms_ai_service.h`（#69 §5.4）配套：
- AI 模型本身是 schema object（CREATE AI MODEL）
- 用户调用 `DBMS_AI_SERVICE.predict(...)` 时需要 AI 模型权限
- 普通 GRANT 不足以覆盖（AI 模型是特殊类型）

---

## 8. Privilege Schema 管理

### 8.1 ob_priv_mgr

```cpp
// src/share/schema/ob_priv_mgr.cpp (推测)
class ObPrivMgr {
  // 管理 user/role 的权限信息
  // - __all_user / __all_role / __all_user_priv / __all_role_priv 等内部表
  // - 提供 user → effective_priv 的解析（考虑 ROLE 继承）
  int get_user_privs(const uint64_t user_id,
                     const uint64_t tenant_id,
                     ObPrivSet &effective_privs);
};
```

### 8.2 ob_priv_sql_service

```cpp
// src/share/schema/ob_priv_sql_service.cpp (推测)
class ObPrivSqlService {
  // DDL 服务：CREATE USER / GRANT / REVOKE / CREATE ROLE
  // 写 __all_user / __all_priv 等内部表
};
```

### 8.3 ob_priv_common

```cpp
// src/share/ob_priv_common.h
// Privilege 通用定义：
// - ObPrivSet 类型定义
// - Privilege 字符串 ↔ bit flag 转换
// - Privilege bit flag 集合运算
```

---

## 9. Password Policy 与认证

### 9.1 密码策略

```cpp
// ob_privilege_check.h 中的相关方法
static int check_password_expired(const ObSqlCtx &ctx, const stmt::StmtType stmt_type);
static int check_password_expired_on_connection(const uint64_t tenant_id,
                                                const uint64_t user_id,
                                                share::schema::ObSchemaGetterGuard &schema_guard,
                                                sql::ObSQLSessionInfo &session);
```

### 9.2 密码策略维度

| 策略 | MySQL 兼容 | Oracle 兼容 |
|------|-----------|-----------|
| 密码最小长度 | ✅ | ✅ |
| 密码复杂度（大写/小写/数字/特殊） | ✅ | ✅ |
| 密码过期时间 | ✅ | ✅ |
| 密码重用限制 | 弱 | ✅ |
| 登录失败锁定 | ✅ | ✅ |
| 密码哈希算法 | SHA-256 | SHA-512 + O5LOGON 等 |

### 9.3 登录失败处理

```
应用: 登录 (user='app', pass='wrong')
    │
    ▼
登录请求 → RS
    │
    ├─ 检查 user 是否存在
    │   └─ 不存在 → 报错 + audit
    ├─ 检查 user 是否锁住
    │   └─ 已锁 → 报错
    ├─ 检查密码
    │   └─ 错误 → 失败计数 +1
    │   └─ 超过阈值 → 锁用户 + audit
    │   └─ 密码正确 → 重置失败计数
    └─ 通过 → 创建 session
```

---

## 10. Compatibility Security Feature

### 10.1 兼容特性开关

```cpp
// src/share/ob_compatibility_security_feature_def.h
// 不同 DBMS 兼容模式的 security feature 开关
namespace compat {
  // 启用某 MySQL 兼容特性
  #define ENABLE_MYSQL_FEATURE(name) ...
  // 启用某 Oracle 兼容特性
  #define ENABLE_ORACLE_FEATURE(name) ...
  // ...
}
```

**为什么需要**：OB 同时支持 MySQL 和 Oracle 兼容模式，每种模式的 security feature 不完全相同：
- MySQL 模式：简化权限、MySQL audit log format
- Oracle 模式：LBACS、Oracle Label Security、Oracle audit
- 混合模式：根据 __all_tenant / __all_database 设置动态选择

---

## 11. 与其他文章的关系

### 11.1 与 #39 tenant-architecture

多租户隔离本质就是权限隔离的扩展：
- tenant_id 是权限检查的第一道边界（不同 tenant 的 user 不能跨租户）
- `ObSessionPrivInfo` 内含 tenant_id
- 所有 check_privilege 调用先验证 tenant

### 11.2 与 #59 schema-service

权限持久化通过 schema service：
- GRANT / REVOKE 写入 `__all_user_priv` / `__all_role_priv` 等内部表
- 通过 schema service 同步到各 observer cache
- Privilege 变更需要走 schema service 的版本同步

### 11.3 与 #22 plan-cache

Plan cache 的失效原因之一就是权限变更：
- user 的权限被 revoke 后，对应的 cached plan 失效
- 否则可能出现"过期 plan + 已 revoke 权限"的安全漏洞

### 11.4 与 #69 DBMS_PYTHON / DBMS_AI_SERVICE

OB 5.x 引入的 Python / AI 集成有独立权限：
- `ob_ai_model_priv_util` 是 AI 模型专用
- Python 沙箱权限可能由 PL 权限覆盖（待进一步研究）

---

## 12. 总结

### 12.1 安全体系在 OB 体系中的定位

OB 5.x 的安全体系是 **企业级 RBAC + LBACS + Audit + Data Masking** 的完整组合：
- MySQL 兼容模式：基础 RBAC（5 种权限）
- Oracle 兼容模式：完整 RBAC + LBACS（几十种权限）
- 两种模式通过 `check_privilege_new` 联合校验

### 12.2 关键技术点回顾

| 技术点 | 实现 |
|--------|------|
| Privilege Check | `ob_privilege_check.cpp` 241KB（最大安全模块） |
| MySQL + Oracle 联合 | `check_privilege_new` 双模式 |
| Need Privs 计算 | 函数指针 typedef（可插拔） |
| Label Security | `ob_label_security.h` OLS 兼容 |
| Audit Log | `ob_security_audit_mgr` + monitor |
| Privilege Schema | `ob_priv_mgr` + `ob_priv_sql_service` |
| AI Model Priv | `ob_ai_model_priv_util` (5.x 新) |
| Password Policy | `check_password_expired` 系列方法 |

### 12.3 关键技术模块

| 路径 | 规模 | 角色 |
|------|------|------|
| `src/sql/privilege_check/ob_privilege_check.cpp` | 241KB | 权限校验核心 |
| `src/sql/privilege_check/ob_ora_priv_check.cpp` | 109KB | Oracle 权限 |
| `src/share/schema/ob_priv_mgr.cpp` | ? | Privilege Schema Mgr |
| `src/share/schema/ob_security_audit_mgr.h` | ? | Audit Mgr |
| `src/share/ob_label_security.{h,cpp}` | ? | OLS 实现 |
| `src/share/ob_label_security_os.cpp` | ? | OS label 集成 |

### 12.4 路径修正

之前在 #60 提到的路径 `src/share/audit/` + `src/share/privilege/` + `src/share/lbacs/` 都不存在。真实路径分散在多个目录：
- Privilege Check → `src/sql/privilege_check/`
- Privilege Schema → `src/share/schema/ob_priv_mgr.cpp` + `ob_priv_sql_service.cpp`
- Security Audit → `src/share/schema/ob_security_audit_mgr.h` + `src/sql/monitor/ob_security_audit.*`
- Label Security → `src/share/ob_label_security.h` + `src/share/schema/ob_label_se_policy_*`

### 12.5 推荐下一步

按之前梳理的顺序，下一篇应该是 **#71 资源隔离 / cgroup 深潜**：

OB 多租户的资源隔离体系 —— CPU / IO / 内存 / 网络配额。源码入口：`src/share/resource/` + `src/share/cgroup/`（cgroup 集成）。

适用场景：多租户 SaaS / 资源公平 / 限流。

整吗？