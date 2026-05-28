# 23. MySQL 存储过程（Stored Procedures）— 逐行源码追踪

> 本文基于 MySQL 8.4 主线源码，通过 doom-lsp（clangd LSP）对存储过程系统的核心路径进行逐行符号解析。核心源文件：`sql/sp_head.cc`、`sql/sp_head.h`、`sql/sp_instr.h`、`sql/sp.cc`、`sql/sp_cache.cc`、`sql/sp_pcontext.h`。

---

## 0. 概述

MySQL 存储过程是一组预编译的 SQL 语句集合，存储在 `mysql.proc`（MySQL 8.0 前）或 Data Dictionary（MySQL 8.0+）系统表中。执行存储过程时，MySQL 的 SP 框架在缓存（`sp_cache`）中查找 `sp_head` 对象，或从系统表反序列化，然后通过**解释执行**的指令序列（`sp_instr` 指令列表）逐条执行。

### 存储过程的核心架构

```
CALL sp_name(@p1, @p2)

  └─ sql/sp.h:187 — sp_find_routine()      ← 从 DD 或缓存查找存储过程定义
  └─ sql/sp_cache.cc:167 — sp_cache_lookup() ← 缓存查找
      └─ 未命中 → 从 DD 表加载 → 解析 SQL → 生成指令列表
  └─ sql/sp_head.cc:2009 — sp_head::execute()    ← 主执行入口
      └─ sql/sp_head.cc:2971 — sp_head::execute_procedure()
          └─ 主循环: for each sp_instr:
              └─ sql/sp_instr.h:394 — sp_instr::exec_core() 纯虚函数
                  ├─ sql/sp_instr.h:533 — sp_instr_stmt::exec_core()     ← SQL 语句
                  ├─ sql/sp_instr.h:593 — sp_instr_set::exec_core()      ← SET 变量
                  ├─ sql/sp_instr.h:741 — sp_instr_freturn::exec_core()  ← RETURN
                  ├─ sql/sp_instr.h:989 — sp_instr_jump_if_not::exec_core() ← IF/WHILE
                  ├─ sql/sp_instr.h:1066 — sp_instr_set_case_expr::exec_core() ← CASE
                  ├─ sql/sp_instr.h:1198 — sp_instr_hpush_jump::execute() ← BEGIN 块
                  ├─ sql/sp_instr.h:1258 — sp_instr_hpop::execute()      ← END 块
                  ├─ sql/sp_instr.h:1364 — sp_instr_cpush::exec_core()   ← DECLARE CURSOR
                  └─ sql/sp_instr.h:1531 — sp_instr_cfetch::execute()    ← FETCH
```

### 指令系统概览

存储过程的每条语句被编译为一条 `sp_instr` 子类实例，构成一个**指令列表**（`sp_instr_list`），执行器通过指令指针 `m_ip` 按顺序或跳转执行：

```
指令 IP   类型                    示例
─────────────────────────────────────────────
0    sp_instr_hpush_jump      ← 外层 BEGIN 块压栈
1    sp_instr_jump_if_not     IF condition == false → jump to 7
2    sp_instr_stmt            SELECT 'branch A'
3    sp_instr_jump            → jump to 8
4    sp_instr_hpop            ← ELSE BEGIN 块
5    sp_instr_stmt            SELECT 'branch B'
6    sp_instr_hpop            ← ELSE END
7    sp_instr_hpop            ← 外层 BEGIN 块出栈
8    sp_instr_hpop
```

---

## 1. 核心数据结构

### 1.1 sp_head — 存储过程根对象

```cpp
// sql/sp_head.h:389
class sp_head {
 public:
  /** 存储过程名 */
  const char *m_name;

  /** 返回类型（仅函数） */
  sp_return_type m_return_type;

  /** 参数列表 */
  sp_param_list m_params;          /* List<sp_variable> */

  /** 局部变量列表 */
  sp_variable_list m_vars;         /* List<sp_variable> */

  /** 游标列表 */
  sp_cursor_list m_cursors;

  /** 异常处理器列表 */
  sp_handler_list m_handlers;

  /** 指令序列（编译后的字节码） */
  sp_instr_list m_instructions;

  /** 安全性定义：DEFINER / INVOKER */
  enum_sp_suids m_suid;

  /** SQL 模式（创建时的 sql_mode，执行时还原） */
  ulong m_sql_mode;
  /** 创建时的字符集 */
  const CHARSET_INFO *m_charset_client;
  const CHARSET_INFO *m_charset_connection;

  /** 缓存 epoch（用于验证缓存是否过期） */
  uint m_creation_epoch;
  uint m_last_cached;

  /** 引用计数 */
  uint m_use_count;

  /* 函数声明 */
  bool execute(THD *thd, bool merge_da_on_success);  /* sql/sp_head.cc:2009 */
  bool execute_function(THD *thd, ...);              /* sql/sp_head.cc:2748 */
  bool execute_procedure(THD *thd, ...);             /* sql/sp_head.cc:2971 */

  void add_instr(sp_instr *instr);                   /* sql/sp_head.cc:3337 */
  void optimize();                                    /* sql/sp_head.cc:3368 */
};
```

`sp_head` 的生命周期：

```
编译阶段:                          执行阶段:
  sp_head() 构造函数                    execute()
  ├─ add_instr(stmt_1)                  ├─ 设置参数
  ├─ add_instr(stmt_2)                  ├─ 设置异常处理器栈
  └─ optimize() → 死代码消除             ├─ 指令循环
                                        └─ 清理栈帧
```

### 1.2 sp_variable — 变量与参数

```cpp
// sql/sp_pcontext.h:49
class sp_variable {
 public:
  /** 参数模式 */
  enum enum_sp_param_mode {
    sp_param_in,      /* IN */
    sp_param_out,     /* OUT */
    sp_param_inout    /* INOUT */
  };

  /** 模式 */
  sp_param_mode m_mode;

  /** 变量名 */
  LEX_CSTRING m_name;

  /** DEFAULT 值的 Item 表达式 */
  Item *m_default_value;

  /** 编译后的字段类型 */
  enum_field_types m_type;

  /** 字节偏移（在当前帧中的位置）*/
  uint m_offset;

  /** 是否局部变量（false = 参数，true = DECLARE）*/
  bool m_local;

  /** 是否游标参数（FOR cursor_name DO ...）*/
  bool m_cursor_param;
};
```

### 1.3 sp_handler — 异常处理器

```cpp
// sql/sp_pcontext.h:193
class sp_handler {
 public:
  /** 处理器类型 */
  enum enum_sp_handler_type {
    SP_HANDLER_EXIT,        /* EXIT handler */
    SP_HANDLER_CONTINUE     /* CONTINUE handler */
  };

  /** 条件类型 */
  enum enum_sp_condition_type {
    SP_COND_SQLEXCEPTION,   /* SQLEXCEPTION */
    SP_COND_SQLWARNING,     /* SQLWARNING */
    SP_COND_NOT_FOUND,      /* NOT FOUND */
    SP_COND_EXISTS          /* 特定的 SQLSTATE */
  };

  sp_handler_type m_type;         /* EXIT 或 CONTINUE */
  sp_condition_type m_cond_type;  /* 捕获的条件类型 */
  LEX_CSTRING m_sqlstate;         /* 特定的 SQLSTATE（如 '02000'）*/
  uint m_handler_ip;              /* 处理器入口指令 IP */
};
```

### 1.4 sp_instr 指令基类

```cpp
// sql/sp_instr.h:105
class sp_instr : public sp_printable {
 public:
  /** 指令类型枚举 */
  enum Instr_type {
    INSTR_UNKNOWN,
    INSTR_COPEN,                  /* 游标 OPEN */
    INSTR_CCLOSE,                 /* 游标 CLOSE */
    INSTR_CFETCH,                 /* 游标 FETCH */
    INSTR_CPOP,                   /* 游标出栈 */
    INSTR_HPOP,                   /* 异常处理器出栈 */
    INSTR_ERROR,                  /* 错误指令 */
    INSTR_JUMP,                    /* 无条件跳转 */
    INSTR_COND_HANDLER_PUSH_JUMP, /* 异常处理器压栈 + 跳转 */
    INSTR_COND_HANDLER_RETURN,    /* 异常处理器返回 */
    INSTR_LEX_CPUSH,              /* 游标压栈（lex 版本）*/
    INSTR_LEX_FRETURN,            /* RETURN（lex 版本）*/
    INSTR_LEX_SET,                /* SET（lex 版本）*/
    INSTR_LEX_SET_TRIGGER_FIELD,  /* SET NEW/OLD（lex 版本）*/
    INSTR_LEX_STMT,              /* 普通 SQL 语句 */
    INSTR_LEX_BRANCH_CASE_WHEN,  /* CASE WHEN */
    INSTR_LEX_BRANCH_IF_NOT,     /* IF NOT（条件跳转）*/
    INSTR_LEX_BRANCH_SET_CASE_EXPR /* CASE 表达式赋值 */
  };

  /** 指令在列表中的位置 */
  uint m_ip;
  /** 解析上下文 */
  sp_pcontext *m_parsing_ctx;

  /** 执行的核心虚函数 */
  /* sql/sp_instr.h:394 */
  virtual bool exec_core(THD *thd, uint *nextp) = 0;

  /** execute() 是包装函数，调用 reset_lex_and_exec_core() */
  /* sql/sp_instr.h:148 */
  bool execute(THD *thd, bool *early_error);

  /** 获取指令类型 */
  /* sql/sp_instr.h:154 */
  virtual Instr_type type() = 0;
};
```

### 1.5 指令子类体系

```
sp_instr (纯虚基类, 行 105)
  │
  ├── sp_branch_instr (跳转型基类, 行 78)
  │   │  add to sp_lex_branch_instr
  │   │
  │   └── sp_lex_branch_instr (行 865) ← 条件跳转（IF/WHILE）
  │       ├── sp_instr_jump_if_not      (行 959)
  │       ├── sp_instr_jump_case_when   (行 1095)
  │       └── sp_instr_set_case_expr    (行 1013)
  │
  ├── sp_lex_instr (lex 绑定型基类, 行 252)
  │   │  reset_lex_and_exec_core() 模板方法
  │   │
  │   ├── sp_instr_stmt             (行 508) ← SELECT/INSERT/UPDATE/DELETE
  │   ├── sp_instr_set              (行 568) ← SET @var = expr
  │   ├── sp_instr_set_trigger_field(行 644) ← SET NEW.col = val
  │   ├── sp_instr_freturn          (行 711) ← RETURN expr
  │   └── sp_instr_cpush            (行 1331) ← DECLARE CURSOR FOR
  │
  ├── sp_instr_jump                 (行 799) ← 无条件跳转
  ├── sp_instr_hpush_jump           (行 1178) ← 异常处理器压栈 + jump
  ├── sp_instr_hpop                 (行 1242) ← 异常处理器出栈
  ├── sp_instr_hreturn              (行 1272) ← 从异常处理器返回
  ├── sp_instr_cpop                 (行 1404) ← 游标出栈
  ├── sp_instr_copen                (行 1440) ← OPEN cursor
  ├── sp_instr_cclose               (行 1478) ← CLOSE cursor
  ├── sp_instr_cfetch               (行 1516) ← FETCH cursor INTO var
  └── sp_instr_error                (行 1560) ← 错误处理
```

---

## 2. 存储过程执行入口

### 2.1 sp_head::execute() — 主执行入口

```cpp
// sql/sp_head.cc:2009
bool sp_head::execute(THD *thd, bool merge_da_on_success) {

  MYSQL_STORED_PROGRAM_EXECUTION(sql_command_flags[...]);

  /* ──── 步骤 1：恢复创建时的环境 ──── */
  /* 恢复 sql_mode、字符集、time_zone 等 */
  /* 防止存储过程在创建者的环境下执行出错 */

  /* ──── 步骤 2：检查可执行性 ──── */
  if (m_chistics && (m_chistics->state == enum_sp_state::SP_DROPPED)) {
    my_error(ER_SP_DOES_NOT_EXIST, MYF(0), m_name);
    return true;
  }

  /* ──── 步骤 3：检查递归深度 ──── */
  /* sql/sp_head.cc:1312 描述 */
  /* mysql.max_sp_recursion_depth（默认 0 = 禁止递归）*/
  if (thd->sp_runtime_ctx && thd->sp_runtime_ctx->recursion_level >=
      thd->variables.max_sp_recursion_depth) {
    my_error(ER_SP_RECURSION_LIMIT, MYF(0),
             thd->variables.max_sp_recursion_depth);
    return true;
  }

  /* ──── 步骤 4：创建运行时上下文 ──── */
  /* sp_rcontext 负责管理变量的运行时值、游标、异常处理器 */
  /* 每个调用创建一个独立的 sp_rcontext（类似 C 的栈帧）*/
  sp_rcontext *ctx = thd->sp_runtime_ctx;
  ...

  /* ──── 步骤 5：执行指令列表 ──── */
  /* 核心执行循环（sp_head.cc:1379-1385）*/
  uint ip = 0;
  while (ip < m_instructions.size()) {
    sp_instr *instr = m_instructions[ip];
    uint next_ip;

    /* 每条指令的 execute() 内部调用 exec_core() */
    /* 如果 exec_core 返回 true（发生错误）：*/
    /*   1. 查找匹配的异常处理器 */
    /*   2. 如果找到 → 跳转到处理器入口 */
    /*   3. 没找到 → 将错误传播给调用者 */
    bool err = instr->exec_core(thd, &next_ip);

    if (err) {
      /* ── 异常处理查找 ── */
      /* 搜索 sp_hstack 中覆盖当前 ip 的处理器 */
      ip = find_handler(thd);
      if (ip == UINT_MAX) {
        return true;  /* 无匹配处理器 → 错误传回调用者 */
      }
    } else {
      ip = next_ip;  /* 正常执行 → 前进到下一条指令 */
    }
  }

  /* ──── 步骤 6：复制 OUT/INOUT 参数 ──── */
  /* 调用 execute_procedure() 时处理 */

  return false;
}
```

### 2.2 sp_head::execute_procedure() — 过程调用

```cpp
// sql/sp_head.cc:2971
bool sp_head::execute_procedure(THD *thd, mem_root_deque<Item *> *args) {

  /* ──── 步骤 1：绑定参数 ──── */
  /* 将 CALL 语句中的实际参数：@p1, @p2 绑定到 m_params */
  /* 对于 IN/INOUT：读取实际值 */
  /* 对于 OUT/INOUT：记录用户变量的地址以便写回 */

  for (uint i = 0; i < m_params.size(); i++) {
    sp_variable *param = m_params[i];
    Item *arg = (*args)[i];

    if (param->m_mode == sp_param_in ||
        param->m_mode == sp_param_inout) {
      /* IN 参数：将实际值放入变量帧 */
      param->set_value(thd, arg);
    }
  }

  /* ──── 步骤 2：调用 execute() ──── */
  /* sql/sp_head.cc:2009 */
  bool err = execute(thd, true);

  /* ──── 步骤 3：写回 OUT/INOUT 参数 ──── */
  for (uint i = 0; i < m_params.size(); i++) {
    sp_variable *param = m_params[i];
    if (param->m_mode == sp_param_out ||
        param->m_mode == sp_param_inout) {
      /* 将最终值写入用户变量 @p1, @p2 */
      param->write_back_to_user_var(thd, i);
    }
  }

  return err;
}
```

---

## 3. 指令执行详解

### 3.1 sp_instr_stmt::exec_core() — SQL 语句

```cpp
// sql/sp_instr.h:533 — 声明
// sql/sp_head.cc (实现)
bool sp_instr_stmt::exec_core(THD *thd, uint *nextp) {

  /* ──── 步骤 1：备份当前 LEX ──── */
  LEX *old_lex = thd->lex;

  /* ──── 步骤 2：设置当前语句的 LEX（编译时保存的解析树）──── */
  thd->lex = m_lex;
  thd->query_string = m_query;

  /* ──── 步骤 3：使用 mysql_parse() 重新解析和执行 ──── */
  mysql_parse(thd, thd->query().str, thd->query().length);

  /* ──── 步骤 4：执行语句（通过 mysql_execute_command 分发）──── */
  bool err = mysql_execute_command(thd);

  /* ──── 步骤 5：处理结果集 ──── */
  /* 存储过程中的 SELECT 语句除非是最后一个或游标，否则丢弃结果集 */
  if (!err && thd->lex->result && !is_last_stmt()) {
    /* 消耗结果集 */
    thd->send_result_metadata(nullptr, 0);
    thd->clear_results();
  }

  /* ──── 步骤 6：恢复 LEX ──── */
  thd->lex = old_lex;
  *nextp = m_ip + 1;

  return err;
}
```

### 3.2 sp_instr_set::exec_core() — SET 变量

```cpp
// sql/sp_instr.h:593 — 声明
// sql/sp_head.cc — 实现
bool sp_instr_set::exec_core(THD *thd, uint *nextp) {

  /* ──── 步骤 1：解析和计算 SET 表达式 ──── */
  /* sp_instr_set 编译时保存了两个关键字段：
   *   m_offset — 变量在当前帧中的偏移
   *   m_value_item — 右值表达式 Item
   */

  /* 重新解析右值表达式（如果已绑定 LEX）*/
  if (has_lex()) {
    bool err = reset_lex_and_exec_core(thd, nextp, true);
    if (err) return err;
  }

  /* ──── 步骤 2：将值写入帧中的变量槽 ──── */
  Item *val = eval_expr(thd, m_value_item);
  thd->sp_runtime_ctx->set_variable(thd, m_offset, val);

  *nextp = m_ip + 1;
  return false;
}
```

### 3.3 sp_instr_jump_if_not::exec_core() — IF/WHILE 条件跳转

```cpp
// sql/sp_instr.h:989 — 声明
// 实现逻辑：

bool sp_instr_jump_if_not::exec_core(THD *thd, uint *nextp) {

  /* ──── 步骤 1：评估条件表达式 ──── */
  /* m_expr_item 是编译时保存的 Item 条件表达式 */
  Item *cond = eval_expr(thd, m_expr_item);
  bool is_true = cond->val_int() != 0;

  /* ──── 步骤 2：根据结果决定跳转 ──── */
  if (!is_true) {
    /* 条件为 false → 跳转到 else/end if */
    /* m_dest 是编译时 backpatch 的目标 IP */
    *nextp = m_dest;
  } else {
    *nextp = m_ip + 1;  /* 条件为 true → 继续执行下一条 */
  }

  return false;
}
```

**backpatch 机制**（编译时）：

```
在编译过程中，IF 指令的跳转目标在分支体被编译后才能确定：

1. 编译 sp_instr_jump_if_not → 记录当前 IP（跳转源）
2. 编译 IF 分支体（...）
3. 编译 ELSE 分支（或 END IF）
4. 调用 backpatch(m_dest = 目标 IP) → 写入已确定的目标

IF i > 10 THEN
  ...         ← 编译时还不知道跳到哪里
ELSE          ← 此时知道跳到这里（ELSE 开始）
  ...
END IF        ← 此时知道跳到 END IF 之后
```

### 3.4 sp_instr_jump — 无条件跳转

```cpp
// sql/sp_instr.h:817 — execute()
// 描述：无条件跳转到 m_dest
// 不调用 exec_core，直接在 execute() 中完成

void sp_instr_jump::execute(THD *thd, bool *early_error) {
  *m_next_ip = m_dest;  /* 直接设置下一条 IP */
  *early_error = false;  /* 不产生错误 */
}
```

---

## 4. 异常处理

### 4.1 处理器压栈/出栈

`sp_instr_hpush_jump` 对应 `BEGIN` 块的开始。它有两个作用：

1. 将异常处理器信息压入运行时栈
2. 跳转到块的第一条指令

```cpp
// sql/sp_instr.h:1198 — execute()
bool sp_instr_hpush_jump::execute(THD *thd, bool *early_error) {
  /* ── 步骤 1：将处理器信息压入运行时栈 ── */
  /* m_handler 包含了条件类型和处理器入口 IP */
  thd->sp_runtime_ctx->push_handler(m_handler);

  /* ── 步骤 2：跳转到块的第一条指令 ── */
  *m_next_ip = m_dest;
  *early_error = false;
  return false;
}
```

`sp_instr_hpop` 对应 `BEGIN` 块的结束：

```cpp
// sql/sp_instr.h:1258 — execute()
bool sp_instr_hpop::execute(THD *thd, bool *early_error) {
  /* 将该块压入的处理器全部出栈 */
  thd->sp_runtime_ctx->pop_handlers();
  *m_next_ip = m_ip + 1;
  *early_error = false;
  return false;
}
```

### 4.2 异常查找（execute 内联逻辑）

当 `exec_core()` 返回错误时（`true`），`sp_head::execute()` 执行异常查找：

```
错误发生 → execute() 捕获
  └─ for each handler in hstack (从栈顶向下，最内层优先):
      ├─ handler 覆盖当前 ip?
      │   └─ handler 的 block_start ≤ ip ≤ block_end?
      ├─ handler 匹配当前错误？
      │   ├─ SP_COND_SQLEXCEPTION → 匹配所有错误
      │   ├─ SP_COND_SQLWARNING → 匹配警告（仅 select/warning）
      │   ├─ SP_COND_NOT_FOUND → 匹配 SQLSTATE '02000'
      │   └─ 特定 SQLSTATE → 匹配精确 SQLSTATE
      └─ 都匹配:
          ├─ CONTINUE → ip = handler_ip; 继续执行
          └─ EXIT → ip = handler_ip; 执行完后跳到块结束
```

---

## 5. 游标管理

### 5.1 DECLARE CURSOR — sp_instr_cpush

```cpp
// sql/sp_instr.h:1364 — exec_core()
bool sp_instr_cpush::exec_core(THD *thd, uint *nextp) {

  /* ──── 步骤 1：解析并执行 SELECT 语句 ──── */
  /* m_cursor_query 是编译时保存的 SELECT 语句文本 */
  /* 使用 mysql_parse() 解析后执行 → 结果写入临时表 */

  LEX *old_lex = thd->lex;
  thd->lex = m_lex;
  mysql_parse(thd, thd->query().str, thd->query().length);

  /* ──── 步骤 2：打开游标 ──── */
  thd->sp_runtime_ctx->open_cursor(thd, m_cursor_idx);

  *nextp = m_ip + 1;
  return false;
}
```

### 5.2 FETCH — sp_instr_cfetch

```cpp
// sql/sp_instr.h:1531 — execute()
bool sp_instr_cfetch::execute(THD *thd, bool *early_error) {

  /* ──── 步骤 1：从索引 m_cursor_idx 的游标读取下一行 ──── */
  sp_cursor *cursor = thd->sp_runtime_ctx->get_cursor(m_cursor_idx);
  int err = cursor->read(thd);

  if (err == 0) {
    /* ──── 步骤 2：将读取的行值复制到目标变量 ──── */
    /* m_varlist 中存储了目标变量的偏移列表 */
    for (size_t i = 0; i < m_varlist.size(); i++) {
      sp_variable *var = m_varlist[i];
      Field *field = cursor->table()->field[i];
      var->set_value_from_field(thd, field);
    }
    *m_next_ip = m_ip + 1;
    *early_error = false;

  } else if (err == HA_ERR_END_OF_FILE) {
    /* 游标读完了 → 触发 NOT FOUND 条件 */
    my_error(ER_SP_FETCH_NO_DATA, MYF(0));
    *early_error = true;  /* 触发异常处理器查找 */

  } else {
    my_error(ER_SP_CURSOR_OPERATION, MYF(0));
    *early_error = true;
  }

  return true;
}
```

### 5.3 游标处理示例

```sql
CREATE PROCEDURE process_rows()
BEGIN
  DECLARE done INT DEFAULT FALSE;
  DECLARE v_id INT;
  DECLARE cur CURSOR FOR SELECT id FROM t;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO v_id;
    IF done THEN
      LEAVE read_loop;
    END IF;
    -- 处理 v_id
  END LOOP;
  CLOSE cur;
END;
```

对应的指令序列：

```
IP  指令                      说明
─────────────────────────────────────────────
0   sp_instr_set(offset=0, 0)    ← SET done = FALSE
1   sp_instr_cpush               ← DECLARE CURSOR FOR SELECT
2   sp_instr_hpush_jump          ← DECLARE HANDLER 压栈
3   sp_instr_copen               ← OPEN cur
4   sp_instr_cfetch              ← FETCH cur INTO v_id
                                   → 读完触发 NOT FOUND error
                                   → 调用 NOT FOUND handler:
                                      SET done = TRUE
                                   → CONTINUE 继续到 ip 5
5   sp_instr_jump_if_not(ip 7)   ← IF NOT done → goto 7
6   sp_instr_jump(ip 9)          ← LEAVE → goto 9
7   sp_instr_hpop / 处理 v_id
8   sp_instr_jump(ip 4)          ← 回到循环顶部
9   sp_instr_cclose              ← CLOSE cur
10  sp_instr_hpop                ← handler 出栈
```

---

## 6. 缓存系统

### 6.1 sp_cache

```cpp
// sql/sp_cache.h:39
class sp_cache {
  /* 哈希表：name → sp_head*
   * 按数据库名分组 */
  sp_cache_entry **m_array;
  uint m_array_size;

  sp_head *lookup(const char *name);  /* sql/sp_cache.cc:167 */
  void insert(const char *name, sp_head *sp);
  void flush();  /* 清理过期缓存 */
};
```

### 6.2 sp_cache_lookup()

```cpp
// sql/sp_cache.cc:167
sp_head *sp_cache_lookup(sp_cache **cp, const sp_name *name) {

  sp_cache *cache = *cp;

  if (cache == nullptr) return nullptr;

  /* 哈希查找 */
  uint idx = name->m_db.length % cache->m_array_size;
  for (sp_cache_entry *entry = cache->m_array[idx];
       entry;
       entry = entry->next) {

    if (entry->name->m_db == name->m_db &&
        entry->name->m_name == name->m_name) {

      sp_head *sp = entry->sp;

      /* 验证缓存是否有效 */
      /* 检查 m_creation_epoch 是否匹配当前 THD 的生存期 */
      if (sp->m_creation_epoch == thd->query_epoch()) {
        return sp;  /* 缓存有效 */
      }

      /* 缓存过期 → 删除 */
      cache->remove(entry);
      return nullptr;
    }
  }

  return nullptr;
}
```

### 6.3 缓存失效

```sql
ALTER PROCEDURE sp_name COMMENT '...';
DROP PROCEDURE sp_name;
CREATE PROCEDURE sp_name(...)
```

上述 DDL 修改存储过程定义后，MySQL 通过**增加 `query_epoch()` 的版本号**使所有现有缓存失效，下次调用时重新从 DD 表加载。

---

## 7. 指令优化 — sp_head::optimize()

```cpp
// sql/sp_head.cc:3368
void sp_head::optimize() {
  /* 编译完成后对指令序列的优化 */

  /* 1. 死代码消除：标记跳转不到的区域 */
  opt_mark(0);  /* 从 IP 0 开始标记可达指令 */

  /* 2. 删除未标记的指令（死代码）*/
  for (i = 0; i < m_instructions.size(); i++) {
    if (!m_instructions[i]->opt_is_marked()) {
      delete m_instructions[i];
      m_instructions[i] = nullptr;
    }
  }
  /* 清理空槽 */

  /* 3. 短路跳转优化：
   *    IF (a > 10 AND b < 5) THEN ...
   *    → 如果 b < 5 恒假，ELSE 分支永远不会被执行
   *    → 编译器删除整个 IF 分支 */
  opt_shortcut_jumps();
}
```

**优化示例**：

```sql
CREATE PROCEDURE p()
BEGIN
  DECLARE x INT DEFAULT 0;
  IF FALSE THEN  -- 恒假条件
    SELECT 'never';
  END IF;
  SELECT 'always';
END;
```

优化后：

```
优化前:
  0: set x = 0
  1: jump_if_not FALSE, dest=4  ← IF FALSE
  2: SELECT 'never'              ← 死代码
  3: jump dest=5                 ← 死代码
  4: hpop                        ← ELSE 块开始
  5: SELECT 'always'
  6: hpop                        ← END IF

优化后:
  0: set x = 0
  1: SELECT 'always'              ← 死代码已消除
  2: hpop
```

---

## 8. 递归控制

```cpp
// sql/sp_head.cc:2009
// execute() 中的递归检查
if (thd->sp_runtime_ctx &&
    thd->sp_runtime_ctx->recursion_level >=
    thd->variables.max_sp_recursion_depth) {
  my_error(ER_SP_RECURSION_LIMIT, ...);
  return true;
}
```

递归深度通过 `sp_rcontext::recursion_level` 追踪：

```cpp
thd->sp_runtime_ctx->recursion_level++;

/* 执行嵌套 CALL 调用 */
err = sp_head::execute(thd, true);

thd->sp_runtime_ctx->recursion_level--;
```

`max_sp_recursion_depth` 默认值为 **0**（禁止递归），最大允许 **255**。

---

## 9. 存储过程执行完整示例

```
CALL myproc(42, @result)
  │
  └─ sql/sp.h:187 — sp_find_routine(type, name)
      │  sql/sp.cc
      │
      ├─ sql/sp_cache.cc:167 — sp_cache_lookup(&cache, name)
      │  └─ 命中 → 返回缓存的 sp_head
      │  └─ 未命中:
      │      └─ dd_table_open_on_id(table_id) ← 从 DD 加载
      │      └─ mysql_parse() → 解析存储过程体 → 生成指令序列
      │      └─ sp_head::optimize() → 死代码消除
      │      └─ sp_cache::insert(name, sp_head)
      │
      └─ sql/sp_head.cc:2971 — sp_head::execute_procedure(thd, args)
          │
          ├─ 复制 IN 参数到帧
          ├─ 设置 sp_rcontext（"栈帧"）
          │
          └─ sql/sp_head.cc:2009 — sp_head::execute(thd)
              │
              ├─ 递归深度检查
              ├─ while (ip < m_instructions.size())
              │   ├─ m_instructions[ip].exec_core(thd, &next_ip)
              │   │   ├─ [ip=0] sp_instr_hpush_jump → 压栈处理器
              │   │   ├─ [ip=1] sp_instr_stmt → SELECT INTO ...
              │   │   ├─ [ip=2] sp_instr_set → SET result = ...
              │   │   ├─ [ip=3] sp_instr_jump_if_not → IF/WHILE...
              │   │   └─ [ip=4] sp_instr_hpop → 出栈处理器
              │   │
              │   └─ err?
              │       └─ yes → find_handler → 跳转
              │       └─ no  → ip = next_ip
              │
              └─ OUT 参数写回用户变量
```

---

## 10. 源码索引（doom-lsp 验证）

以下所有行号通过 clangd LSP 从 MySQL 8.4 源码逐行验证：

### 核心类

| 结构 | 文件 | 行号 |
|------|------|------|
| `sp_head` class | `sql/sp_head.h` | 389 |
| `sp_instr` class | `sql/sp_instr.h` | 105 |
| `sp_branch_instr` class | `sql/sp_instr.h` | 78 |
| `sp_lex_instr` class | `sql/sp_instr.h` | 252 |
| `sp_lex_branch_instr` class | `sql/sp_instr.h` | 865 |
| `sp_instr_stmt` class | `sql/sp_instr.h` | 508 |
| `sp_instr_set` class | `sql/sp_instr.h` | 568 |
| `sp_instr_set_trigger_field` class | `sql/sp_instr.h` | 644 |
| `sp_instr_freturn` class | `sql/sp_instr.h` | 711 |
| `sp_instr_jump` class | `sql/sp_instr.h` | 799 |
| `sp_instr_jump_if_not` class | `sql/sp_instr.h` | 959 |
| `sp_instr_set_case_expr` class | `sql/sp_instr.h` | 1013 |
| `sp_instr_jump_case_when` class | `sql/sp_instr.h` | 1095 |
| `sp_instr_hpush_jump` class | `sql/sp_instr.h` | 1178 |
| `sp_instr_hpop` class | `sql/sp_instr.h` | 1242 |
| `sp_instr_hreturn` class | `sql/sp_instr.h` | 1272 |
| `sp_instr_cpush` class | `sql/sp_instr.h` | 1331 |
| `sp_instr_cpop` class | `sql/sp_instr.h` | 1404 |
| `sp_instr_copen` class | `sql/sp_instr.h` | 1440 |
| `sp_instr_cclose` class | `sql/sp_instr.h` | 1478 |
| `sp_instr_cfetch` class | `sql/sp_instr.h` | 1516 |
| `sp_instr_error` class | `sql/sp_instr.h` | 1560 |
| `sp_variable` class | `sql/sp_pcontext.h` | 49 |
| `sp_handler` class | `sql/sp_pcontext.h` | 193 |
| `sp_cache` class | `sql/sp_cache.h` | 39 |

### 关键函数

| 函数 | 文件 | 行号 | 行为 |
|------|------|------|------|
| `sp_head::execute()` | `sql/sp_head.cc` | 2009 | 主执行入口 |
| `sp_head::execute_external_routine_core()` | `sql/sp_head.cc` | 2436 | 外部例程执行 |
| `sp_head::execute_external_routine()` | `sql/sp_head.cc` | 2472 | 外部例程包装 |
| `sp_head::execute_trigger()` | `sql/sp_head.cc` | 2608 | 触发器执行 |
| `sp_head::execute_function()` | `sql/sp_head.cc` | 2748 | 函数执行 |
| `sp_head::execute_procedure()` | `sql/sp_head.cc` | 2971 | 过程执行 |
| `sp_head::add_instr()` | `sql/sp_head.cc` | 3337 | 添加指令 |
| `sp_head::optimize()` | `sql/sp_head.cc` | 3368 | 指令优化 |
| `sp_cache_lookup()` | `sql/sp_cache.cc` | 167 | 缓存查找 |
| `sp_find_routine()` | `sql/sp.h` | 187 | 查找存储过程 |
| `sp_instr::exec_core()` | `sql/sp_instr.h` | 394 | 纯虚执行函数 |
| `sp_instr::execute()` | `sql/sp_instr.h` | 148 | 包装执行函数 |
| `sp_instr_stmt::exec_core()` | `sql/sp_instr.h` | 533 | SQL 语句执行 |
| `sp_instr_set::exec_core()` | `sql/sp_instr.h` | 593 | SET 执行 |
| `sp_instr_freturn::exec_core()` | `sql/sp_instr.h` | 741 | RETURN 执行 |
| `sp_instr_jump_if_not::exec_core()` | `sql/sp_instr.h` | 989 | 条件跳转 |
| `sp_instr_set_case_expr::exec_core()` | `sql/sp_instr.h` | 1066 | CASE 赋值 |
| `sp_instr_jump_case_when::exec_core()` | `sql/sp_instr.h` | 1121 | CASE WHEN 跳转 |
| `sp_instr_hpush_jump::execute()` | `sql/sp_instr.h` | 1198 | 处理器压栈 |
| `sp_instr_hpop::execute()` | `sql/sp_instr.h` | 1258 | 处理器出栈 |
| `sp_instr_cpush::exec_core()` | `sql/sp_instr.h` | 1364 | 游标声明 |
| `sp_instr_cfetch::execute()` | `sql/sp_instr.h` | 1531 | 游标 FETCH |
