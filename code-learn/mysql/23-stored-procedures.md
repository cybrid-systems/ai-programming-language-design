# 23. MySQL 存储过程（Stored Procedures）— 源码分析

> 本文分析 MySQL 存储过程的实现，包括 SP 缓存/重载、执行流程、参数传递、变量域、游标管理、异常处理和递归控制。核心源文件：`sql/sp_head.cc`、`sql/sp.cc`、`sql/sp_cache.cc`、`sql/sql_prepare.cc`。

---

## 0. 概述

MySQL 存储过程是预编译的 SQL 语句集合，存储在 `mysql.proc` 系统表中。每次调用时，MySQL SP 框架从缓存（`sp_cache`）加载或从系统表反序列化 `sp_head` 对象，解释执行其中的指令。

### 存储过程执行流程

```
CALL sp_name(@param1, @param2, ...)

  └─ sp_find_routine()                 ← 查找存储过程定义
  └─ sp_cache_lookup()                 ← 缓存查找
  └─ sp_head::execute()                ← 主执行入口
      ├─ sp_head::execute_function()   ← 函数执行
      └─ sp_lex_keeper::reset_lex()    ← 重置词法分析环境
```

---

## 1. 核心数据结构

### 1.1 sp_head — 存储过程对象

```cpp
// sql/sp_head.h
class sp_head {
 public:
  /** 存储过程名 */
  const char *m_name;
  /** 返回类型（仅函数） */
  sp_return_type m_return_type;
  /** 参数列表 */
  sp_param_list m_params;          /* List<sp_variable> */
  /** 局部变量定义 */
  sp_variable_list m_vars;         /* List<sp_variable> */
  /** 游标列表 */
  sp_cursor_list m_cursors;
  /** 异常处理器列表 */
  sp_handler_list m_handlers;
  /** 指令序列（编译后的字节码）*/
  sp_instr_list m_instructions;

  /** 安全性定义 */
  enum_sp_suids m_suid;            /* DEFINER / INVOKER */

  /** SQL 模式 */
  ulong m_sql_mode;
  /** character set 客户端 */
  const CHARSET_INFO *m_charset_client;
  /** character set 连接 */
  const CHARSET_INFO *m_charset_connection;

  /** 缓存状态 */
  uint m_creation_epoch;
  uint m_last_cached;

  // 方法
  bool execute(THD *thd, bool *last_spvar);
  bool execute_function(THD *thd, Item **ret_value);
};
```

### 1.2 sp_instr 指令序列

每个存储过程语句（BEGIN/END/SET/IF/WHILE/CURSOR...）编译为一条 `sp_instr` 指令：

```cpp
// sql/sp_head.h
class sp_instr {
 public:
  /** 指令在指令列表中的位置 */
  uint m_ip;
  /** 源文件/行号信息（用于调试） */
  const char *m_source;
  uint m_lineno;

  /** 执行当前指令 */
  virtual bool exec_core(THD *thd, uint *nextp) = 0;

  /** 解析参数并执行 */
  bool exec(THD *thd, ...);
};

/* 具体指令类型 */
class sp_instr_stmt : public sp_instr {
  /* SET / SELECT / INSERT / UPDATE / DELETE 等语句 */
  LEX *m_lex;            /* 词法分析结果 */
};

class sp_instr_set : public sp_instr {
  /* SET var = expr */
  sp_variable_t *m_var;
  Item *m_value;
};

class sp_instr_if : public sp_instr {
  /* IF cond THEN stmt1 ELSE stmt2 */
  Item *m_cond;
  uint m_then_ip;    /* 条件真时跳转到 m_then_ip */
  uint m_else_ip;    /* 条件假时跳转到 m_else_ip */
};

class sp_instr_jump : public sp_instr {
  /* 无条件跳转到 m_destination_ip */
  uint m_destination_ip;
};

class sp_instr_hpush_jump : public sp_instr {
  /* 异常处理器压栈（进入 BEGIN/END 块）*/
  uint m_handler_ip;   /* 处理器入口 IP */
};

class sp_instr_hpop : public sp_instr {
  /* 异常处理器出栈 */
};

class sp_instr_cpush : public sp_instr {
  /* 打开游标 */
};

class sp_instr_cpop : public sp_instr {
  /* 关闭游标 */
};

class sp_instr_cfetch : public sp_instr {
  /* FETCH [NEXT FROM] cursor INTO var1, var2, ... */
};
```

### 1.3 sp_variable — 变量

```cpp
// sql/sp.h
struct sp_variable_t {
  sp_param_mode mode;    /* IN / OUT / INOUT */
  const char *name;      /* 变量名 */
  Item *default_value;   /* DEFAULT 值 */
  Item **value_ptr;      /* 运行时值指针 */
  bool local;            /* true=局部变量, false=参数 */

  /* 编译后的类型 */
  enum_field_types type; /* MYSQL_TYPE_VARCHAR, MYSQL_TYPE_INT, ... */
};
```

---

## 2. 存储过程执行

### 2.1 sp_head::execute()

```cpp
// sql/sp_head.cc
bool sp_head::execute(THD *thd, bool *last_spvar) {
  /* ──── 步骤 1：准备执行上下文 ──── */
  /* 保存/恢复 thd 中的 sql_mode、charset 等 */

  /* ──── 步骤 2：分配参数和局部变量 ──── */
  /* 在 thd->sp_ctx 中创建 stack frame */
  sp_ctx->push_frame();
  for (auto &var : m_vars) {
    /* 为每个变量分配空间 / 设置默认值 */
    var->value_ptr = new Item_field(...);
    if (var->default_value) {
      *(var->value_ptr) = var->default_value->copy();
    }
  }

  /* ──── 步骤 3：设置参数值 ──── */
  /* 将 CALL 传递的实际参数赋值给 IN/INOUT 参数 */
  for (i = 0; i < m_params.size(); i++) {
    if (m_params[i]->mode == sp_param_mode_t::sp_param_in ||
        m_params[i]->mode == sp_param_mode_t::sp_param_inout) {
      *(m_params[i]->value_ptr) = call_args[i]->copy();
    }
  }

  /* ──── 步骤 4：执行指令序列 ──── */
  uint ip = 0;   /* 指令指针 */
  while (ip < m_instructions.size()) {
    sp_instr *instr = m_instructions[ip];
    uint next_ip;

    bool ret = instr->exec(thd, &next_ip);
    if (ret) {  /* 发生错误 */
      /* 查找匹配的异常处理器 */
      ip = sp_find_handler(thd, ...);
    } else {
      ip = next_ip;
    }
  }

  /* ──── 步骤 5：复制 OUT/INOUT 参数到用户变量 ──── */
  for (i = 0; i < m_params.size(); i++) {
    if (m_params[i]->mode != sp_param_in) {
      /* 将返回值写入 @param1, @param2, ... */
      set_user_var(thd, call_args[i]->name, *(m_params[i]->value_ptr));
    }
  }

  /* ──── 步骤 6：清理 ──── */
  sp_ctx->pop_frame();
  return false;
}
```

### 2.2 指令执行示例—sp_instr_stmt::exec_core()

```cpp
// sql/sp_head.cc
bool sp_instr_stmt::exec_core(THD *thd, uint *nextp) {
  /* ──── 编译 SQL 语句 ──── */
  /* 使用存储过程上下文的 LEX 编译 */
  LEX *old_lex = thd->lex;
  thd->lex = m_lex;
  mysql_parse(thd, thd->query(), thd->query_length());

  /* ──── 执行 SQL 语句 ──── */
  bool err = mysql_execute_command(thd);

  /* ──── 是否有结果集？ ──── */
  if (thd->lex->result && !err) {
    /* SELECT 语句 → 发送结果集 */
    /* 但存储过程中的 SELECT 不会返回给客户端 */
    /* 除非是最后一个语句或游标 FETCH */
    if (!thd->sp_runtime_ctx->is_last_stmt()) {
      /* 丢弃结果集 */
      thd->send_result_metadata(nullptr, 0);
    }
  }

  *nextp = m_ip + 1;
  thd->lex = old_lex;
  return err;
}
```

### 2.3 变量作用域实现

MySQL 存储过程中的变量作用域基于嵌套块结构：

```sql
CREATE PROCEDURE p()
BEGIN
  DECLARE x INT DEFAULT 1;       -- Layer 0: ip=0 到 ip=4
  BEGIN
    DECLARE x INT DEFAULT 2;     -- Layer 1: ip=2 到 ip=3
    SELECT x;  -- 输出 2
  END;
  SELECT x;                      -- 输出 1
END;
```

```cpp
// sp_head.cc 中变量查找
sp_variable_t *sp_head::find_variable(THD *thd, const char *name,
                                       size_t length) {
  /* 从当前层向上查找变量（类似 C 的作用域规则）*/
  for (auto frame = sp_ctx->current_frame();
       frame != nullptr;
       frame = frame->parent()) {
    for (auto &var : frame->m_vars) {
      if (strcmp(var->name, name) == 0)
        return var;
    }
  }
  return nullptr;
}
```

---

## 3. 游标管理

游标的生命周期：

```sql
DECLARE cur CURSOR FOR SELECT ...;   -- 声明（不执行）
OPEN cur;                           -- 执行 SELECT，准备结果集
FETCH cur INTO var1, var2;          -- 取下一行
CLOSE cur;                          -- 清理
```

实现：

```cpp
// sp_head.cc — 游标操作
class sp_cursor_t {
  /* SELECT 语句的 LEX */
  LEX *m_lex;
  /* 执行结果（临时表）*/
  TABLE *m_result_table;
  /* 当前读取位置（行号）*/
  ha_rows m_fetch_position;
};

// sp_instr_cpush::exec_core — 打开游标
bool sp_instr_cpush::exec_core(THD *thd, uint *nextp) {
  /* 执行 SELECT 语句，结果写入临时表 */
  /* 游标读取时从临时表逐行读取（而非从原始表）*/
  ...
}

// sp_instr_cfetch::exec_core — 取下一行
bool sp_instr_cfetch::exec_core(THD *thd, uint *nextp) {
  /* 从临时表逐行读取 */
  int error = cursor->m_result_table->file->ha_rnd_pos(
      cursor->m_result_table->record[0],
      cursor->m_fetch_position++);
  /* 将读取的行复制到目标变量 */
  for (i = 0; i < m_vars.size(); i++) {
    copy_value_to_spvar(thd, m_vars[i], cursor->m_result_table->field[i]);
  }
  return false;
}
```

---

## 4. 异常处理（Handler）

```sql
DECLARE CONTINUE HANDLER FOR SQLEXCEPTION, SQLWARNING, NOT FOUND
BEGIN
  -- 异常处理代码
END;
```

实现：

```cpp
// sp_head.cc — 异常处理

/* 异常处理器压栈/出栈对应 ENTER/EXIT 块 */
class sp_handler_t {
  enum handler_type { CONTINUE, EXIT };
  enum condition_type { SQLEXCEPTION, SQLWARNING, NOT_FOUND, SPECIFIC };
  uint m_handler_ip;     /* 处理器入口指令号 */
  uint m_block_start;    /* 处理器覆盖的块起始 IP */
  uint m_block_end;      /* 处理器覆盖的块结束 IP */
};

// 执行出错时的异常处理查找
uint sp_head::sp_find_handler(THD *thd, int sql_errno) {
  for (auto handler : sp_ctx->handler_stack()) {
    if (handler->covers(当前 IP) &&
        handler->matches(sql_errno)) {
      if (handler->type == EXIT) {
        /* 退出当前块，跳转到块后的第一条指令 */
        return handler->m_block_end + 1;
      } else { /* CONTINUE */
        /* 处理完成后继续执行下一条指令 */
        return handler->m_handler_ip;
      }
    }
  }
  return NOT_FOUND; /* 没有匹配的处理器 → 错误返回给客户端 */
}
```

---

## 5. 递归控制

MySQL 存储过程支持递归调用，但有默认限制：

```sql
SET max_sp_recursion_depth = 255;  -- 默认 0（禁止递归）
```

```cpp
// sp_head.cc
bool sp_head::execute(THD *thd, ...) {
  /* 递归深度检查 */
  if (thd->sp_runtime_ctx->recursion_level() >=
      thd->variables.max_sp_recursion_depth) {
    my_error(ER_SP_RECURSION_LIMIT, ...);
    return true;
  }
  thd->sp_runtime_ctx->increment_recursion_level();
  ...
  thd->sp_runtime_ctx->decrement_recursion_level();
}
```

---

## 6. 缓存管理

### 6.1 sp_cache

```cpp
// sql/sp_cache.cc
class sp_cache {
 public:
  /* 哈希表：name → sp_head* */
  struct sp_cache_entry {
    char *name;
    sp_head *sp;
    sp_cache_entry *next;  /* 同一哈希槽的下一项 */
    uint m_creation_epoch; /* 缓存 epoch */
  };
  sp_cache_entry **m_array;   /* 哈希桶数组 */
  uint m_array_size;          /* 桶大小 */
  uint m_old_epoch_value;     /* 旧缓存清理阈值 */

  sp_head *lookup(const char *name);
  void insert(const char *name, sp_head *sp);
  void flush();              /* 清理过期的缓存 */
};
```

**缓存验证**：

每次调用 SP 时，检查 `m_creation_epoch` 是否和系统表的版本号一致。如果不一致（有人 ALTER PROCEDURE 修改了定义），强制从系统表重新加载。

```cpp
// sp_head.cc
bool sp_head::execute(THD *thd, ...) {
  /* 检查缓存是否有效 */
  if (m_creation_epoch != thd->query_epoch()) {
    /* 缓存过期 → 重新加载 */
    sp_update_cache(thd, this);
  }
  ...
}
```

---

## 7. 源码索引

| 函数/结构 | 文件 | 关键作用 |
|-----------|------|---------|
| `sp_head` class | `sql/sp_head.h` | 存储过程主对象 |
| `sp_instr` class | `sql/sp_head.h` | 指令基类 |
| `sp_instr_stmt` | `sql/sp_head.h` | SQL 语句指令 |
| `sp_instr_set` | `sql/sp_head.h` | SET 指令 |
| `sp_instr_if` | `sql/sp_head.h` | IF 分支指令 |
| `sp_instr_jump` | `sql/sp_head.h` | 跳转指令 |
| `sp_instr_hpush_jump` | `sql/sp_head.h` | 异常处理器压栈 |
| `sp_instr_cpush` | `sql/sp_head.h` | 游标打开指令 |
| `sp_instr_cfetch` | `sql/sp_head.h` | 游标 FETCH 指令 |
| `sp_variable_t` | `sql/sp.h` | 变量/参数定义 |
| `sp_handler_t` | `sql/sp_head.h` | 异常处理器 |
| `sp_cursor_t` | `sql/sp_head.h` | 游标 |
| `sp_head::execute()` | `sql/sp_head.cc` | 执行入口 |
| `sp_find_handler()` | `sql/sp_head.cc` | 异常处理查找 |
| `sp_cache::lookup()` | `sql/sp_cache.cc` | 缓存查找 |
| `sp_find_routine()` | `sql/sp.cc` | 从系统表加载 |
