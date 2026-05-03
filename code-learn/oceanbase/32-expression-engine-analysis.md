# 32-expression-engine — 表达式引擎：ObExpr、表达式计算与求值框架

> 基于 OceanBase 主线源码
> 使用 doom-lsp（clangd LSP）进行符号解析与数据流追踪

---

## 0. 概述

表达式是 SQL 计算的最小单元。从 `a + b` 的简单算术到复杂的函数调用、类型转换、CASE WHEN 逻辑——每个计算环节都依赖表达式引擎。**表达式引擎**是 SQL 执行引擎中最重要的基础组件之一。

OceanBase 的表达式引擎整体架构如下：

```
SQL 文本
   │
   ├→ 解析器（Parser）→ ObRawExpr（原始表达式）
   │
   ├→ 优化器 → ObRawExpr 变换（常量折叠、简化、等价变换）
   │
   ├→ 代码生成（cg_expr）→ ObExpr（运行时表达式）
   │
   └→ 执行引擎 → ObExpr::eval() / eval_batch() / eval_vector()
```

**三层表达式表示**：

| 层级 | 类 | 位置 | 用途 |
|------|-----|------|------|
| 逻辑层 | `ObRawExpr` | `src/sql/resolver/expr/` | 解析器/优化器使用的表达式树 |
| 算子层 | `ObExprOperator` | `src/sql/engine/expr/ob_expr_operator.h` | 运算符注册、类型推导 |
| 运行时层 | `ObExpr` | `src/sql/engine/expr/ob_expr.h:523` | 向量化求值的核心运行时结构 |

### 与前面文章的关联

| 文章 | 关联点 |
|------|--------|
| 24-ob-datum | 表达式运算的操作数类型 `ObDatum`，表达式结果载体 |
| 09-sql-executor | 表达式的执行上下文，表达式在算子中的求值位置 |
| 25-thread-model | 表达式求值运行在 SQL 工作线程上 |
| 26-ob-obj | 旧版 `ObObj` 数据类型，正在被 ObDatum 逐步替代 |

---

## 1. ObExpr 运行时框架

`ObExpr`（`ob_expr.h:523`）是表达式的**运行时核心结构体**。它不是基类，而是一个类似"扁平化 vtable"的 POD 结构体——通过函数指针实现多态，而非 C++ 虚函数继承。

### 1.1 ObExpr 结构体

```cpp
// ob_expr.h ~line 523
class ObExpr
{
  // ...
  int32_t magic_;                         // 魔法数，用于校验
  ObExprOperatorType type_;               // 表达式类型
  ObDatumMeta datum_meta_;                // 结果数据的元信息
  common::ObObjMeta obj_meta_;            // 结果对象的元信息
  int32_t max_length_;                    // 最大长度

  // 标志位联合体
  bool batch_result_ : 1;                 // 是否批量结果
  bool is_called_in_sql_ : 1;            // 是否在 SQL 中调用
  bool is_static_const_ : 1;             // 是否是静态常量
  bool is_boolean_ : 1;                  // 是否是布尔类型
  bool is_dynamic_const_ : 1;            // 是否是动态常量
  bool need_stack_check_ : 1;            // 是否需要栈检查
  bool is_fixed_length_data_ : 1;        // 是否是定长数据
  bool nullable_ : 1;                    // 是否可为空

  // 求值函数指针 —— 运行时多态的核心
  EvalFunc eval_func_;                    // 单行求值函数
  EvalBatchFunc eval_batch_func_;         // 批量求值函数
  EvalVectorFunc eval_vector_func_;       // 向量化求值函数
  EvalEnumSetFunc eval_enumset_func_;     // ENUM/SET 求值函数

  // 表达式树结构
  ObExpr **inner_functions_;              // 内部函数指针数组
  int32_t inner_func_cnt_;                // 内部函数数量
  ObExpr **args_;                         // 子表达式（参数）指针数组
  int32_t arg_cnt_;                       // 子表达式数量
  ObExpr **parents_;                      // 父表达式指针数组
  int32_t parent_cnt_;                    // 父表达式数量

  // Frame 中的偏移
  int32_t frame_idx_;                     // 所属 frame 的索引
  int32_t datum_off_;                     // datum 在 frame 中的偏移
  int32_t eval_info_off_;                 // eval_info 在 frame 中的偏移
  int32_t res_buf_off_;                   // 结果缓冲区在 frame 中的偏移
  int32_t res_buf_len_;                   // 结果缓冲区长度
  // ... 更多偏移字段
};
```

**设计关键**：`ObExpr` 不使用虚函数。所有求值行为通过函数指针（`eval_func_` / `eval_batch_func_` / `eval_vector_func_`）在代码生成阶段（`cg_expr`）指定。这使得每个表达式实例可以针对具体的操作数类型选择最优的求值函数——例如 `add_int_int` 比 `add_number_number` 快得多。

### 1.2 表达式的三种求值模式

OceanBase 的表达式引擎支持三种求值模式，通过函数指针实现：

```
┌──────────────────────────────────────────────────────────┐
│                    ObExpr 求值入口                         │
│                                                          │
│  ObExpr::eval()         单行求值 → 返回 ObDatum*          │
│    │                                                     │
│    ├─ batch_result_? ─── 批量结果，按索引取 datum          │
│    ├─ eval_func_? ─────── 调用 eval_func_()               │
│    └─ 已求值? ────────── 跳过（惰性求值优化）               │
│                                                          │
│  ObExpr::eval_batch()   批量求值 → 填充 batch datum        │
│    │                                                     │
│    ├─ batch_result_? ─── 否 → 退化为单行 eval()            │
│    ├─ eval_batch_func_?  调用 eval_batch_func_()           │
│    └─ skip 向量 ────────── 跳过已处理行                     │
│                                                          │
│  ObExpr::eval_vector()  向量化求值 → 直接填充 Vector       │
│    │                                                     │
│    ├─ eval_vector_func_? 调用 eval_vector_func_()          │
│    └─ VectorFormat ────── Uniform/Discrete/Fixed/Const    │
└──────────────────────────────────────────────────────────┘
```

**关键源码**（`ob_expr.h` 行号已验证）：

```cpp
// 单行求值 — ob_expr.h:1488
OB_INLINE int ObExpr::eval(ObEvalCtx &ctx, common::ObDatum *&datum) const
{
  int ret = common::OB_SUCCESS;
  char *frame = ctx.frames_[frame_idx_];
  datum = (ObDatum *)(frame + datum_off_);
  ObEvalInfo *eval_info = (ObEvalInfo *)(frame + eval_info_off_);
  if (is_batch_result()) {
    // 批量结果：按 batch_idx 取 datum
    if (NULL == eval_func_ || eval_info->is_projected()) {
      if (UINT32_MAX != vector_header_off_) {
        ret = cast_to_uniform(ctx.get_batch_size(), ctx);
      }
      datum = datum + ctx.get_batch_idx();
    } else {
      ret = eval_one_datum_of_batch(ctx, datum);
    }
  } else if (NULL != eval_func_ && !eval_info->is_evaluated(ctx)) {
    // 非常量且有求值函数且未求值 → 执行求值
    if (OB_UNLIKELY(need_stack_check_) && OB_FAIL(check_stack_overflow())) {
      // ...
    } else {
      if (datum->ptr_ != frame + res_buf_off_) {
        datum->ptr_ = frame + res_buf_off_;
      }
      ret = eval_func_(*this, ctx, *datum);
      // ...
      eval_info->set_evaluated(true);
    }
  }
  return ret;
}
```

### 1.3 ObEvalCtx — 求值上下文

`ObEvalCtx`（`ob_expr.h:181`）是表达式求值的运行时上下文。每个执行算子实例持有自己的 `ObEvalCtx`，包含当前行的 frame 指针、batch 参数、临时分配器等信息。

```
ObEvalCtx
├── frames_[]              ── frame 数组（每个表达式在 frame 中有 offset）
├── max_batch_size_        ── 最大批量大小
├── exec_ctx_              ── 执行上下文（ObExecContext*）
├── tmp_alloc_             ── 临时内存分配器
├── datum_caster_          ── datum 类型转换器
├── batch_idx_             ── 当前 batch 行索引
├── batch_size_            ── 当前 batch 大小
├── expr_res_alloc_        ── 表达式结果分配器
└── pvt_skip_for_eval_row_ ── 私有 skip 位图
```

### 1.4 ObEvalInfo — 求值状态

`ObEvalInfo`（`ob_expr.h:319`）跟踪每个表达式的求值状态，支持惰性求值（lazy evaluation）：

```cpp
struct ObEvalInfo {
  bool evaluated_   : 1;  // 是否已求值
  bool projected_   : 1;  // 是否已被投影（子算子直接提供值）
  bool notnull_     : 1;  // 是否确定非空
  bool point_to_frame_ : 1; // 是否指向 frame 内的 datum
  // ...
};
```

### 1.5 ObExprBasicFuncs — 基础函数集合

`ObExprBasicFuncs`（`ob_expr.h:386`）为每个表达式类型提供通用的哈希和比较函数：

```cpp
struct ObExprBasicFuncs {
  ObExprHashFuncType default_hash_;       // 默认哈希
  ObBatchDatumHashFunc default_hash_batch_; // 批量默认哈希
  ObExprHashFuncType murmur_hash_;        // Murmur 哈希
  ObExprHashFuncType xx_hash_;            // xxHash
  ObExprHashFuncType wy_hash_;            // wyHash
  ObExprCmpFuncType null_first_cmp_;      // NULL 优先比较
  ObExprCmpFuncType null_last_cmp_;       // NULL 最后比较
  // ...
};
```

---

## 2. ObExprOperator 继承体系

`ObExprOperator`（`ob_expr_operator.h:303`）是表达式的**运算符基类**。它使用传统的 C++ 继承体系，每个运算符类型对应一个子类。

### 2.1 完整继承树

```
ObDLinkBase<ObExprOperator>
  └── ObExprOperator                     → 基础运算符类
        ├── ObFuncExprOperator           → 一般函数运算符（函数调用）
        │     ├── ObLocationExprOperator → 位置相关函数
        │     └── (各类 SQL 函数子类)
        ├── ObRelationalExprOperator     → 比较运算符 (=, <, >, <=, >=, !=)
        ├── ObSubQueryRelationalExpr     → 子查询比较 (IN, ANY, ALL)
        ├── ObArithExprOperator          → 算术运算符 (+, -, *, /)
        ├── ObVectorExprOperator         → 向量运算符（向量化搜索）
        ├── ObLogicalExprOperator        → 逻辑运算符 (AND, OR, NOT)
        ├── ObStringExprOperator         → 字符串函数 (SUBSTR, CONCAT, LENGTH)
        ├── ObBitwiseExprOperator        → 位运算 (&, |, ^, ~)
        └── ObMinMaxExprOperator         → MIN/MAX 聚合
```

### 2.2 定义位置（ob_expr_operator.h）

| 类 | 行号 | 说明 |
|-----|------|------|
| `ObExprOperator` | 303 | 基类，含 `cg_expr()`、`calc_result_type*()` |
| `ObFuncExprOperator` | 1097 | 函数运算符，含 `calc_resultN()` 系列 |
| `ObRelationalExprOperator` | 1122 | 比较运算符 |
| `ObSubQueryRelationalExpr` | 1499 | 子查询相关比较 |
| `ObArithExprOperator` | 1657 | 算术运算符 |
| `ObVectorExprOperator` | 1786 | 向量运算符 |
| `ObLogicalExprOperator` | 1824 | 逻辑运算符 |
| `ObStringExprOperator` | 1918 | 字符串运算符 |
| `ObBitwiseExprOperator` | 1956 | 位运算符 |
| `ObMinMaxExprOperator` | 2099 | 最值运算符 |

### 2.3 基类核心接口

```cpp
class ObExprOperator : public common::ObDLinkBase<ObExprOperator>
{
public:
  // 代码生成：为 ObExpr 填充函数指针
  virtual int cg_expr(ObExprCGCtx &op_cg_ctx,
                      const ObRawExpr &raw_expr,
                      ObExpr &rt_expr) const;

  // 结果类型推导
  virtual int calc_result_type0(ObExprResType &type, ObExprTypeCtx &type_ctx) const;
  virtual int calc_result_type1(ObExprResType &type, ObExprResType &type1, ...) const;
  virtual int calc_result_type2(ObExprResType &type, ObExprResType &type1, ObExprResType &type2, ...) const;
  // ... calc_result_type3 ...

  // 旧引擎的值计算
  virtual int calc_result0(ObObj &result, ObExprCtx &expr_ctx) const;
  virtual int calc_result1(ObObj &result, const ObObj &obj1, ...) const;
  virtual int calc_result2(ObObj &result, const ObObj &obj1, const ObObj &obj2, ...) const;
  // ...
};
```

### 2.4 具体表达式示例：ObExprAdd

`ObExprAdd`（`ob_expr_add.h`）继承 `ObArithExprOperator`，是加法运算符的实现。它展示了**完整的三阶段（单行/批量/向量化）求值模式**：

```cpp
class ObExprAdd : public ObArithExprOperator
{
public:
  // 单行求值函数（类型组合特化）
  static int add_int_int(EVAL_FUNC_ARG_DECL);
  static int add_float_float(EVAL_FUNC_ARG_DECL);
  static int add_double_double(EVAL_FUNC_ARG_DECL);
  static int add_number_number(EVAL_FUNC_ARG_DECL);
  static int add_datetime_datetime(EVAL_FUNC_ARG_DECL);
  // ... 约 30+ 种类型组合 ...

  // 批量求值函数
  static int add_int_int_batch(BATCH_EVAL_FUNC_ARG_DECL);
  static int add_float_float_batch(BATCH_EVAL_FUNC_ARG_DECL);
  // ...

  // 向量化求值函数
  static int add_int_int_vector(VECTOR_EVAL_FUNC_ARG_DECL);
  static int add_float_float_vector(VECTOR_EVAL_FUNC_ARG_DECL);
  // ...

  // 溢出检测（使用编译器内建函数）
  template<typename T1, typename T2, typename T3>
  OB_INLINE static bool is_add_out_of_range(T1 val1, T2 val2, T3 &res)
  {
    return __builtin_add_overflow(val1, val2, &res);
  }

  // 代码生成：cg_expr 将运算符绑定到 ObExpr
  virtual int cg_expr(ObExprCGCtx &op_cg_ctx,
                      const ObRawExpr &raw_expr,
                      ObExpr &rt_expr) const override;
};
```

加法表达式有超过 **40 种类型组合的求值函数**！这包括：
- `int + int`、`int + uint`、`uint + uint`、`uint + int`
- `float + float`、`double + double`
- `number + number`（高精度十进制）
- `datetime + number`、`number + datetime`
- `interval + datetime`、`datetime + interval`
- `decimalint32` 到 `decimalint512` 的各种精度
- `collection + collection`（数组操作）
- 每种都对应三种求值模式

---

## 3. 表达式树与求值路径

### 3.1 表达式树结构

表达式在执行时组织为**有向无环图（DAG）**，每个 `ObExpr` 通过 `args_` 和 `parents_` 指针连接。

```
SELECT a + b * 2 FROM t

表达式树：
                ┌─────────────────┐
                │   ObExpr (+)    │
                │  type=T_OP_ADD  │
                │  eval_func_=    │
                │  add_int_int    │
                └────────┬────────┘
                        / \
                ┌──────/   \──────┐
                │                  │
        ┌───────┴──────┐   ┌──────┴───────┐
        │ ObExpr (col) │   │  ObExpr (*)   │
        │ type=T_REF   │   │ type=T_OP_MUL │
        │ frame_idx=0  │   │ eval_func_=   │
        │ datum_off=X  │   │ mul_int_int   │
        └──────────────┘   └───────┬───────┘
                                  / \
                          ┌──────/   \──────┐
                          │                  │
                  ┌───────┴──────┐   ┌──────┴───────┐
                  │ ObExpr (col) │   │ ObExpr (const)│
                  │ type=T_REF   │   │ type=T_INT    │
                  │ frame_idx=0  │   │ value=2       │
                  │ datum_off=Y  │   │ eval_func_=   │
                  └──────────────┘   │ NULL(常量)    │
                                      └──────────────┘
```

### 3.2 求值流程（后序遍历）

```
求值顺序（后序遍历，叶子到根）：
  1. 求值 b       → 读取列值（直接取 frame 中 datum）
  2. 求值 2       → 常量，跳过了求值
  3. 求值 b * 2   → 调用 mul_int_int(b_datum, const_2)
  4. 求值 a       → 读取列值
  5. 求值 a + ... → 调用 add_int_int(a_datum, mul_result)

Frame 布局：
┌──────────────────────────────────────────────┐
│  Frame[idx=0]                                 │
│  ├── datum_off=a   → ObDatum(a)              │
│  ├── datum_off=b   → ObDatum(b)              │
│  ├── datum_off=*   → ObDatum(result)          │
│  ├── datum_off=+   → ObDatum(result)          │
│  ├── eval_info_off=* → ObEvalInfo             │
│  ├── eval_info_off=+ → ObEvalInfo             │
│  └── res_buf_off=*   → 结果缓冲空间            │
└──────────────────────────────────────────────┘
```

### 3.3 惰性求值（Lazy Evaluation）

`ObEvalInfo` 的 `evaluated_` 标志位实现了惰性求值：

- **第一次**求值时：执行 `eval_func_` 并设置 `evaluated_ = true`
- **后续**求值：跳过，直接返回已缓存的结果
- **投影优化**：如果值由子算子直接投影（`projected_ = true`），完全跳过

这是 OceanBase 表达式引擎的重要优化——同一个表达式在同一行内多次引用时只计算一次。

### 3.4 批量求值（Batch Evaluation）

批量求值时，表达式结果以**列格式**（columnar）存储在 frame 中：

```
batch_size=1024 时的 datum 布局：
┌──────────────────────────────────┐
│  ObDatum[0] ← 行 0 的结果        │
│  ObDatum[1] ← 行 1 的结果        │
│  ObDatum[2] ← 行 2 的结果        │
│  ...                             │
│  ObDatum[1023] ← 行 1023 的结果  │
└──────────────────────────────────┘
```

批量求值的核心路径（`ob_expr.h:1525`）：

```cpp
OB_INLINE int ObExpr::eval_batch(ObEvalCtx &ctx,
                                 const ObBitVector &skip,
                                 const int64_t size) const
{
  if (!is_batch_result()) {
    // 非批量：退化为单行求值
    bool const_dry_run = skip.accumulate_bit_cnt(size) >= size;
    ret = eval(ctx, datum);
  } else if (info.is_projected() || NULL == eval_batch_func_) {
    // 已经投影或无求值函数，跳过
  } else if (size > 0) {
    ret = do_eval_batch(ctx, skip, size);
  }
}
```

### 3.5 向量化求值（Vector Evaluation）

向量化求值是 OceanBase 最新的求值模式，支持四种 Vector 格式：

```
VectorFormat:
├── VEC_UNIFORM      — 统一格式：值连续存储，null 位图
├── VEC_UNIFORM_CONST — 常量格式：所有行相同值
├── VEC_FIXED        — 定长格式：定长数据（int, double）
└── VEC_DISCRETE     — 离散格式：指针数组，适合不定长数据
```

向量化求值的好处：
- **SIMD 友好**：连续内存布局利于 SIMD 指令
- **减少虚函数开销**：提前计算类型匹配，消除热路径上的分支
- **缓存友好**：列式存储减少 cache miss

---

## 4. Raw Expression → ObExpr 的转换

### 4.1 ObRawExpr — 优化器表达式

`ObRawExpr`（`src/sql/resolver/expr/ob_raw_expr.h`）是解析器和优化器使用的表达式表示。它是一个完整的表达式树，包含了类型信息、原始 SQL 文本、依赖关系等。

```
ObRawExpr
├── type_               ── 表达式类型
├── result_type_        ── 结果类型
├── expr_level_         ── 表达式层级
├── relation_scope_     ── 关联作用域
├── children_           ── 子表达式数组
├── alias_name_         ── 别名
├── is_stack_expr_      ── 是否为栈上表达式
└── internal_info_      ── 内部信息（如函数参数类型）
```

### 4.2 代码生成：cg_expr

`cg_expr()`（code generation expression）是 `ObExprOperator` 的虚函数，负责将 `ObRawExpr` 转换为 `ObExpr` 并填充函数指针。

```cpp
// 基类默认实现 — ob_expr_operator.h ~cg_expr
virtual int cg_expr(ObExprCGCtx &op_cg_ctx,
                    const ObRawExpr &raw_expr,
                    ObExpr &rt_expr) const;
```

`ObExprAdd::cg_expr()` 的实现示例（伪代码表示）：

```cpp
int ObExprAdd::cg_expr(ObExprCGCtx &op_cg_ctx,
                       const ObRawExpr &raw_expr,
                       ObExpr &rt_expr) const
{
  // 1. 获取操作数类型
  ObExprType left_type = rt_expr.args_[0]->datum_meta_.type_;
  ObExprType right_type = rt_expr.args_[1]->datum_meta_.type_;

  // 2. 根据类型组合绑定求值函数
  if (left_type == int && right_type == int) {
    rt_expr.eval_func_ = add_int_int;
    rt_expr.eval_batch_func_ = add_int_int_batch;
    rt_expr.eval_vector_func_ = add_int_int_vector;
  } else if (left_type == double && right_type == double) {
    rt_expr.eval_func_ = add_double_double;
    rt_expr.eval_batch_func_ = add_double_double_batch;
    rt_expr.eval_vector_func_ = add_double_double_vector;
  }
  // ... 更多类型组合 ...
}
```

### 4.3 转换流程

```
解析器 SQL 解析
    │
    ▼
ObRawExpr 树（完整 SQL 语义）
    │
    │  优化器变换：
    │  ├─ 常量折叠（ConstFolding）
    │  ├─ 谓词推入（Predicate Pushdown）
    │  └─ 表达式简化
    │
    ▼
ObRawExpr 树（优化后）
    │
    │  cg_expr() 遍历
    │  └─ 每个 ObExprOperator 实现各自的 cg_expr()
    │
    ▼
ObExpr 数组 / 表达式 DAG
    │  └─ 函数指针已绑定到特定类型的求值函数
    │
    ▼
执行引擎调用 eval() / eval_batch() / eval_vector()
```

---

## 5. 表达式优化

### 5.1 常量折叠（Constant Folding）

如果在 `cg_expr` 阶段发现**所有参数都是常量**，则表达式可以在编译期直接求值，避免运行时重复计算：

```
原始：SELECT 1 + 2 FROM t
                    ↓
优化后：SELECT 3 FROM t   （1+2 在代码生成时已计算）
```

常量表达式在 `ObExpr` 中标记为 `is_static_const_ = true`，求值时直接跳过。

### 5.2 NOT NULL 传播

如果表达式的所有子表达式都保证非空，则 `ObEvalInfo::notnull_` 置位，可以跳过 NULL 检查：

```
已知 NOT NULL 的列：a, b
  a + b  → notnull_ = true （无需检查 NULL）
```

### 5.3 表达式简化

优化器会对表达式树进行语义等价变换：

```
a = a      → true  （恒等式消除）
a > b AND a > b  → a > b  （重复消除）
a + 0      → a     （加法单位元消除）
a * 1      → a     （乘法单位元消除）
NOT (a > b) → a <= b （德摩根律）
```

### 5.4 自适应过滤器滑动窗口

`ObAdaptiveFilterSlideWindow`（`ob_expr_operator.h:114`）为运行时过滤器（runtime filter）提供自适应控制：

```
滑动窗口大小 = 4096
如果过滤器过滤率 < 阈值（默认 0.5）：
  ├─ 禁用该窗口中的过滤器
  └─ 如果持续过低，扩大窗口惩罚
```

---

## 6. 设计决策

### 6.1 函数指针 vs 虚函数

OceanBase 的 `ObExpr` 采用**函数指针**而非虚函数实现运行时多态：

| 方案 | ObExprOperator（编译时） | ObExpr（运行时） |
|------|------------------------|------------------|
| 多态方式 | C++ 虚函数（class hierarchy） | 函数指针（vtable 扁平化） |
| 用途 | 类型推导、代码生成 | 高性能求值 |
| 分派时机 | 执行计划生成时 | 每行/每批求值时 |

**为什么运行时不用虚函数？**
- 虚函数每次调用有间接开销（vtable 查找）
- 函数指针允许按**类型组合**精确特化（`add_int_int` vs `add_double_double`）
- `cg_expr` 在编译期就确定了最佳函数，消除了求值时的类型分派

### 6.2 类型组合爆炸的处理

每个运算符需要应对大量类型组合。以加法为例有 40+ 个求值函数。OceanBase 的解决方案：

1. **模板元编程**：使用 `EVAL_FUNC_ARG_DECL` 宏统一函数签名
2. **类型特化**：`cg_expr` 中通过 if-else 链或查表法选择函数
3. **分组处理**：同一类算术类型（如所有整型变体）共享核心算法

### 6.3 惰性求值的优缺点

**优点**：
- 同一表达式多行引用只计算一次
- 配合条件分支（CASE WHEN），未走到的分支不求值

**缺点**：
- 需要 `ObEvalInfo` 的状态管理开销
- 批量求值时状态清理有成本（跨行需要重置）

### 6.4 内存管理

表达式结果的内存通过 Frame 统一管理：

```
Frame 一次性分配（含所有表达式的 datum + eval_info + 缓冲区）
  │
  ├── 定长结果：嵌入 Frame，无需额外分配
  │     └── int, double, date 等
  │
  └── 变长结果：使用 ObExprStrResAlloc 从 res_buf 中分配
        └── varchar, text, blob 等
        └── ObDynReserveBuf 支持动态扩容
```

`ObExprStrResAlloc`（`ob_expr.h:1091`）是变长字符串结果的分配器，从预分配的 `res_buf` 中顺序分配，避免对全局内存分配器的频繁调用。

### 6.5 旧引擎过渡：calc_result vs eval

OceanBase 表达式引擎经历了从旧引擎到新引擎的迁移：

```cpp
// 旧引擎（逐步废弃）
virtual int calc_result1(ObObj &result, const ObObj &obj1, ObExprCtx &expr_ctx) const;

// 新引擎（当前主流）
static int add_int_int(EVAL_FUNC_ARG_DECL);           // ObDatum 接口
```

旧引擎使用 `ObObj` 类型和新引擎使用 `ObDatum` 类型。新引擎通过函数指针直接静态注册，性能更高（见第 24 篇关于 ObDatum 的分析）。

---

## 7. 源码索引

### 核心文件

| 文件 | 行数 | 说明 |
|------|------|------|
| `src/sql/engine/expr/ob_expr.h` | ~1840 | `ObExpr`、`ObEvalCtx`、`ObEvalInfo`、`ObExprBasicFuncs` |
| `src/sql/engine/expr/ob_expr.cpp` | — | `ObExpr` 成员函数实现 |
| `src/sql/engine/expr/ob_expr_operator.h` | ~2800 | `ObExprOperator` 基类及继承体系 |
| `src/sql/engine/expr/ob_expr_operator.cpp` | — | `ObExprOperator` 实现 |

### 关键类行号（已验证）

| 符号 | 文件 | 行号 |
|------|------|------|
| `ObDatumMeta` | `ob_expr.h` | 61 |
| `ObEvalCtx` | `ob_expr.h` | 181 |
| `ObEvalInfo` | `ob_expr.h` | 319 |
| `ObExprBasicFuncs` | `ob_expr.h` | 386 |
| `ObDynReserveBuf` | `ob_expr.h` | 433 |
| `ObExpr` | `ob_expr.h` | 523 |
| `ObExpr::eval()` | `ob_expr.h` | 1488 |
| `ObExpr::eval_batch()` | `ob_expr.h` | 1525 |
| `ObExpr::eval_vector()` | `ob_expr.h` | 1551 |
| `ObExprStrResAlloc` | `ob_expr.h` | 1091 |
| `ObExprOperator` | `ob_expr_operator.h` | 303 |
| `ObFuncExprOperator` | `ob_expr_operator.h` | 1097 |
| `ObRelationalExprOperator` | `ob_expr_operator.h` | 1122 |
| `ObArithExprOperator` | `ob_expr_operator.h` | 1657 |
| `ObVectorExprOperator` | `ob_expr_operator.h` | 1786 |
| `ObLogicalExprOperator` | `ob_expr_operator.h` | 1824 |
| `ObStringExprOperator` | `ob_expr_operator.h` | 1918 |
| `ObBitwiseExprOperator` | `ob_expr_operator.h` | 1956 |
| `ObMinMaxExprOperator` | `ob_expr_operator.h` | 2099 |
| `ObAdaptiveFilterSlideWindow` | `ob_expr_operator.h` | 114 |

### 具体表达式（示例）

| 符号 | 文件 | 行数 |
|------|------|------|
| `ObExprAdd` | `ob_expr_add.h` | 353 |
| `ObExprAggAdd` | `ob_expr_add.h` | 聚合用加法 |
| `ObExprSubstr` | `ob_expr_substr.h` | 字符串函数 |
| `ObRawExpr` | `src/sql/resolver/expr/ob_raw_expr.h` | 原始表达式 |
| `ObRawExprPrinter` | `src/sql/printer/ob_raw_expr_printer.h` | 原始表达式打印 |

### 辅助文件

| 文件 | 说明 |
|------|------|
| `ob_expr_res_type.h` | 表达式结果类型定义 |
| `ob_i_expr_extra_info.h` | 表达式额外信息接口 |
| `ob_expr_extra_info_factory.h` | 额外信息工厂 |
| `ob_expr_cmp_func.h` | 比较函数集合 |
| `share/datum/ob_datum_funcs.h` | ObDatum 函数集合 |

---

## 8. 总结

OceanBase 的表达式引擎是一个**分层、高度特化**的求值框架：

1. **三层表示**：`ObRawExpr`（逻辑层）→ `ObExprOperator`（算子层）→ `ObExpr`（运行时层）

2. **双重重用**：编译时用 C++ 继承体系（`ObExprOperator` 子类），运行时用函数指针（避免虚函数开销）

3. **三种求值模式**：单行（`eval`）、批量（`eval_batch`）、向量化（`eval_vector`），通过 `cg_expr` 按需选择

4. **类型特化**：每个运算符有数十个针对具体类型组合的求值函数，在代码生成时按类型绑定

5. **惰性求值**：通过 `ObEvalInfo` 跟踪求值状态，避免重复计算

6. **常量折叠**：纯常量表达式在编译期完成求值

下一篇文章将分析 **聚合函数与 GROUP BY**——查看 `ObExprSum`、`ObExprCount` 等聚合运算符的实现，以及 GROUP BY 的执行路径。
