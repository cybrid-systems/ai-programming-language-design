# 23. MySQL 存储过程 (Stored Procedures)

> 本文分析 MySQL 存储过程的实现，包括缓存管理、执行流程、参数传递、递归控制、游标与异常处理。核心文件：`sql/sp_head.cc`、`sql/sp.cc`。

---

## 1. 概述

MySQL 存储过程在服务器层实现，其核心是 `sp_head` 类。每个存储过程被解析后编译为一个 `sp_head` 实例，缓存到 `sp_cache` 中，后续调用直接复用缓存的指令序列。存储过程支持 `IN/OUT/INOUT` 参数、游标、声明式异常处理（`HANDLER`）、以及有限递归。

| 组件 | 文件 | 职责 |
|------|------|------|
| `class sp_head` | `sp_head.h:389` | 存储过程/函数/触发器的主控类 |
| `sp_head::execute()` | `sp_head.cc:2009` | 通用执行入口 |
| `sp_head::execute_procedure()` | `sp_head.cc:2971` | CALL 执行入口 |
| `sp_head::execute_function()` | `sp_head.cc:2748` | 函数调用入口 |
| `sp_cache` | `sp.cc` | 存储过程缓存管理 |

---

## 2. 核心数据结构

`sp_head` 类包含以下关键字段：

```cpp
// sp_head.h:389
class sp_head {
  sp_name m_name;                           // 存储过程名
  Sp_params m_params;                       // 参数定义（IN/OUT/INOUT）
  Mem_root_array<Sp_definition> m_body;     // 指令序列（预解析的 sp_instr 数组）
  Mem_root_array<Sp_handler> m_handlers;    // 声明式异常处理器

  uint m_flags;                             // 标志（IS_INVOKED 等）
  sql_mode_t m_sql_mode;                   // 创建时的 SQL_MODE
  sp_head *m_next_cached_sp;               // 缓存链表中的下一个实例
  sp_head *m_first_instance;               // 第一个实例
  int m_recursion_level;                   // 递归深度

  Sp_chistics m_chistics;                  // 特征（language, sql access, etc.）
  sp_resultmap m_result_type;              // 返回结果类型
};
```

**缓存机制**：每个存储过程在 `sp_cache` 中以链表形式缓存多个实例（`m_first_instance → m_next_cached_sp → ...`），用于支持递归调用。

### 指令类型

```cpp
// sp_head.h — 指令类型定义
class sp_instr;
class sp_instr_jump;        // 无条件跳转（如 LEAVE 标签）
class sp_instr_hreturn;     // HANDLER 返回
class sp_instr_stmt;        // SQL 语句执行
class sp_instr_set;         // SET 变量赋值
class sp_instr_cpush;       // 打开游标
class sp_instr_cfetche;     // FETCH 游标
class sp_instr_cpop;        // 关闭游标
class sp_instr_creturn;     // RETURN（函数返回值）
```

---

## 3. 执行流程

### 3.1 `sp_head::execute()` — 通用执行入口

```cpp
// sp_head.cc:2009
bool sp_head::execute(THD *thd, bool merge_da_on_success) {
  /* Step 1: 设置执行 arena */
  Query_arena execute_arena(&execute_mem_root,
                            Query_arena::STMT_INITIALIZED_FOR_SP);
  Query_arena backup_arena;

  /* Step 2: 栈溢出检查 */
  // (8~16)×STACK_MIN_SIZE 取决于编译选项
  const int sp_stack_size = 8 * STACK_MIN_SIZE;
  if (check_stack_overrun(thd, sp_stack_size, (uchar *)&old_packet))
    return true;

  /* Step 3: 设置递归标记 */
  m_flags |= IS_INVOKED;                        // line 2048

  /* Step 4: 链接缓存链中的下一个递归实例 */
  m_first_instance->m_first_free_instance = m_next_cached_sp;

  /* Step 5: 设置诊断区隔离 */
  Diagnostics_area sp_da(false);
  thd->push_diagnostics_area(&sp_da);           // line 2089

  /* Step 6: 逐条执行指令序列 */
  for (uint ip = 0; ip < m_body.size(); ip++) {
    m_body[ip]->exec_core(thd);                 // line 2200

    // 指令执行失败时查找匹配的 HANDLER
    if (err && m_handlers.size() > 0) {
      for (auto &handler : m_handlers) {
        if (handler.matches(err_code)) {
          thd->clear_error();
          ip = handler.target_ip - 1;           // 跳转
          break;
        }
      }
    }
  }

  /* Step 7: 重置递归标记 */
  m_flags &= ~IS_INVOKED;
}
```

### 3.2 存储过程调用：`sp_head::execute_procedure`

```cpp
// sp_head.cc:2971
bool sp_head::execute_procedure(THD *thd,
                                mem_root_deque<Item *> *args) {
  /* Step 1: 参数绑定 — IN/INOUT/OUT */
  if (m_params.size() > 0) {
    sp_param::set_parameters(thd, this, args);  // line 2995
  }

  /* Step 2: 设置用户变量默认值 */
  for (auto &var : m_defined_vars) {
    var->set_default(thd);                      // line 3020
  }

  /* Step 3: 执行主体 */
  bool err = execute(thd, false);               // line 3026

  /* Step 4: 写出 OUT/INOUT 参数值到调用者 */
  sp_param::send_out_parameters(thd);           // line 3034
}
```

---

## 4. 递归控制

存储过程的递归通过缓存链中的多实例实现：

```
CALL sp()
 └─ sp_head::execute_procedure()
     └─ sp_head::execute()
         ├─ m_flags |= IS_INVOKED          # 标记为"被调用"
         ├─ m_first_instance->m_first_free_instance = m_next_cached_sp
         │   # 下一个递归使用缓存中的下一个实例
         └─ 执行指令
             └─ CALL sp()  # 递归
                 ├─ sp_cache_lookup → m_first_free_instance
                 ├─ m_recursion_level++
                 └─ sp_head::execute() ...
```

`m_recursion_level` 控制递归深度限制。默认 `max_sp_recursion_depth = 0`（禁止递归），用户需显式设置。

---

## 5. HANDLER 与异常处理

声明式异常处理器在 `sp_head` 中以 `m_handlers` 链表存储：

```sql
DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
  SET done = 1;
```

执行时循环检查（`sp_head.cc:2200`）：

```cpp
// 伪代码：指令循环中的异常处理
for (uint ip = 0; ip < m_body.size(); ip++) {
  auto err = m_body[ip]->exec_core(thd);
  if (err) {
    for (auto &handler : m_handlers) {
      if (handler.condition == err_code) {
        thd->clear_error();               // 清除错误
        ip = handler.target_ip;           // 跳转到处理代码
        break;
      }
    }
  }
}
```

---

## 6. 诊断区隔离

每次调用使用独立 `Diagnostics_area`：

```cpp
// sp_head.cc:2089
Diagnostics_area sp_da(false);
thd->push_diagnostics_area(&sp_da);
```

- 过程中的错误/警告被捕获在 `sp_da` 中，不污染调用者
- 调用者通过 `GET DIAGNOSTICS` 或 `DECLARE EXIT HANDLER` 获取错误

---

## 7. 安全上下文

```cpp
// sp_head.cc:2009
opt_trace_disable_if_no_security_context_access(thd);
```

按 `SQL SECURITY DEFINER` / `SQL SECURITY INVOKER` 切换安全上下文。`invoker` 模式使用 CALL 用户的权限，`definer` 模式使用创建者的权限。

---

## 8. 总结

1. **预解析指令序列**：`CREATE PROCEDURE` 时解析为 `sp_instr` 数组，执行时逐条调用 `exec_core()`。
2. **缓存链支持递归**：多实例链表避免递归时的数据结构覆盖。
3. **诊断区隔离**：`push_diagnostics_area` 隔离过程的警告/错误。
4. **异常处理**：`m_handlers` 链表 + 指令 IP 跳转实现声明式 HANDLER。
5. **游标处理**：`sp_instr_cpush` / `sp_instr_cfetche` 实现游标逐行读取。

### 源码引用汇总

| 文件 | 行号 | 关键内容 |
|------|------|----------|
| `sp_head.h` | 389 | `class sp_head` 定义 |
| `sp_head.cc` | 2009 | `sp_head::execute()` |
| `sp_head.cc` | 2748 | `sp_head::execute_function()` |
| `sp_head.cc` | 2971 | `sp_head::execute_procedure()` |
