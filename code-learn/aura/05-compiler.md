# #5 v2 — Aura Compiler (C++26 Modules + AOT/JIT + Evaluator)

> 接续 #1 v2 Orchestration + #2 v2 Build System + #3 v2 Parser + #4 v2 Runtime:
> 前面讲了 aura 的运行时抽象、构建系统、Parser、Runtime。本文聚焦 **Compiler**
> ——`src/compiler/` 下 36 个 `.ixx` 模块接口单元 + 30+ `.cpp` 实现单元 + 多个
> header,以及 LLVM ORC JIT、AOT 编译、Evaluator 8-TU P0 split 等。

---

## 0. 全文导读

Aura Compiler 五层:

```
Aura source (.aura)
    ↓ Lexer (#3) → Tokens
    ↓ Parser (#3) → AST (Expr 8 类型 variant)
    ↓ Type Checker (type_checker.ixx)
    ↓ IR + Pass Manager (ir.ixx + pass_manager.ixx)
    ↓ Lowering (lowering.ixx)
    ↓ AOT (Ahead-Of-Time) 编译
LLVM IR (.bc / .ll)
    ↓ link with lib/runtime.c (#4)
native binary
    或
    ↓ LLVM ORC JIT (aura_jit.cpp)
runtime in-process
```

本文按"架构 → C++26 Modules → Evaluator 8-TU split → AOT → JIT → ADT
Runtime → Type Checker → 调优"展开。

---

## 1. Compiler 整体架构

### 1.1 目录结构

```
src/compiler/  (182 文件)
├── *.ixx (36 个 C++20 module 接口单元)
│   ├── adt_runtime.ixx          # ADT constructor table
│   ├── arity.ixx                # 算子元数
│   ├── ast_walkers.ixx          # AST 遍历
│   ├── aura_jit.ixx             # LLVM ORC JIT 引擎(推测)
│   ├── cache.ixx                 # 编译 cache
│   ├── coercion_map.ixx          # 类型 coercion
│   ├── compute_kind.ixx          # compute kind 枚举
│   ├── constant_folding.ixx      # 常量折叠
│   ├── covergroup_sampling.ixx   # covergroup 采样
│   ├── diag.ixx                  # 诊断
│   ├── dirty_propagation.ixx     # dirty propagation
│   ├── evaluator.ixx             # Evaluator 主接口
│   ├── ir.ixx                    # 中间表示
│   ├── ir_executor.ixx           # IR 执行
│   ├── lowering.ixx              # AST → IR
│   ├── pass_manager.ixx          # pass 管理
│   ├── query.ixx                 # 查询 primitive
│   ├── service.ixx               # 编译 service
│   ├── type_checker.ixx          # 类型检查
│   ├── value.ixx                 # Value 表示
│   └── ...  共 36 个
├── *.cpp (30+ 个实现单元,module body 不能在 .h)
│   ├── evaluator_ctor.cpp       # Evaluator 构造
│   ├── evaluator_adt.cpp        # ADT 求值
│   ├── evaluator_defuse_index.cpp # defuse 索引
│   ├── evaluator_eval_flat.cpp  # flat 求值
│   ├── macro_expansion.cpp      # 宏展开
│   ├── evaluator_primitives_registry.cpp # primitives 注册
│   ├── evaluator_env.cpp        # 环境
│   ├── evaluator_module_loader.cpp # 模块加载
│   ├── evaluator_workspace_tree.cpp # workspace tree
│   ├── aura_jit.cpp              # JIT 实现
│   ├── aura_jit_bridge.cpp       # JIT bridge
│   ├── aura_jit_runtime.cpp      # JIT runtime stub
│   ├── aura_jit_prim_dispatch_stub.cpp
│   ├── aura_jit_bridge_stub.cpp
│   ├── cache_impl.cpp            # cache 实现
│   ├── constant_folding_impl.cpp # const fold 实现
│   ├── compute_kind_impl.cpp
│   ├── arity_impl.cpp
│   ├── adt_runtime_impl.cpp
│   ├── ast_impl.cpp (在 core/)
│   └── ...  共 30+ 个
├── *.h / *.hh (header-only utility)
│   ├── agent_name_table.h        # agent 名字表
│   ├── agent_name_table_fwd.h
│   ├── aot_hot_update_health.hh  # AOT hot-update health
│   ├── aot_mangle.h              # AOT name mangling
│   ├── aura_error_bridge.h       # error bridge
│   ├── basis_points.h            # 基点
│   ├── bounded_lru.h             # bounded LRU
│   ├── castop_density_policy.hh  # castop density policy
│   ├── ci_build_info.h           # CI build info
│   ├── coercion_provenance_policy.hh
│   ├── compact_policy.hh         # compact policy
│   ├── compile_prims_decl.inc    # primitives decl include
│   ├── compiler_metrics_fields.inc
│   └── ...  共 20+ 个
```

### 1.2 关键依赖

```cpp
// CMakeLists.txt (P0 split)
# P0: evaluator implementation partitions (same module: aura.compiler.evaluator).
src/compiler/evaluator_ctor.cpp
src/compiler/evaluator_adt.cpp
src/compiler/evaluator_defuse_index.cpp
src/compiler/evaluator_eval_flat.cpp
src/compiler/macro_expansion.cpp
src/compiler/evaluator_primitives_registry.cpp
src/compiler/evaluator_env.cpp
src/compiler/evaluator_module_loader.cpp
src/compiler/evaluator_workspace_tree.cpp
```

**关键 insight**: 8 个 evaluator_*.cpp 文件共享同一个 module (`aura.compiler.evaluator`)。
Module 是 **接口 + 单 module purview**,实现跨多个 TU(Translation Unit)
分发。

---

## 2. C++20 Modules 架构

### 2.1 Module 拆分原则

```
一个 .ixx = 一个 module = 一个 module purview
接口 / 公开符号 / 跨模块 import 在 .ixx
实现 / 私有 helper / 内联函数 在 .cpp

原因:
  - .ixx 编译慢(全 purview)
  - .cpp 编译快(只看 .ixx + 自己代码)
  - 修改 .cpp 不触发 .ixx 重新编译
```

### 2.2 evaluator.ixx 示例

```cpp
// src/compiler/evaluator.ixx (头 30 行)
module;

#include "../core/persistent_child_vector.hh"
#include "../core/layout_stamp.hh"  // Issue #2170: LayoutStamp decls
#include "observability_metrics.h"   // CompilerMetrics struct
#include "lock_order_audit.h"
#include "typed_mutation_audit.h"    // Issue #1589
#include "primitives_meta.h"
#include "render_telemetry.hh"
#include "core/arena_auto_policy_stats.h"
#include "core/gc_hooks.h"
#include "core/densify_consistency_report.h"  // Issue #2368
#include "core/resource_quota.hh"               // Issue #1579
#include "security_capabilities.h"             // Issue #1416
#include "security_side_effect.hh"             // Issue #2057/#2152

// 然后 purview:
export module aura.compiler.evaluator;

// export 符号...
```

**关键 insight**: `module;` + include 普通 header 是 **global module fragment** ——
在 purview 之前,避免 `import std;` 与具体头文件的 conflict。

### 2.3 AuraModules.cmake 集成

```cmake
# cmake/AuraModules.cmake
target_compile_features(aura.compiler.evaluator PUBLIC cxx_std_20)
target_compile_options(aura.compiler.evaluator PRIVATE
    -fmodules-ts
    -fmodule-mapper=|@aura-module-mapper@
)
```

每个 .ixx 编译时用 `-fmodules-ts`,生成 BMI(Built Module Interface)。

### 2.4 Cycle Avoidance (FFI Pattern)

```cpp
// adt_runtime.ixx (头 5 行)
module;

#include "../core/persistent_child_vector.hh"

// To avoid cyclic import with evaluator.ixx, we use RegisterFn callback
// (same as FFIRuntime).

// 提供 register_primitives() callback 接口,evaluator 通过 callback 注册
// ADT 原语,避免 ADT 知道 Evaluator 或反之。
```

**关键 insight**: 用 **callback 注册** 避免 module cyclic dependency (evaluator
↔ adt_runtime)。这是 FFI / Plugin 系统的经典做法。

---

## 3. Evaluator 8-TU P0 Split

### 3.1 拆分动机

```
单 TU evaluator.cpp 现状:
  - 编译慢 (全 include 都进)
  - 改动 hot path → 全 TU 重新编译
  - 测试耦合 → 改一处影响全部

P0 split 目标:
  - 编译快 (TU 间接口通过 module export)
  - 改动 hot path (e.g. eval_flat) → 仅该 TU 重编
  - 测试解耦 → 每个 TU 独立测试
```

### 3.2 8 个 TU 的职责

```
evaluator_ctor.cpp
  - Evaluator 构造 + 析构
  - 初始化 env + primitives + closures + modules

evaluator_env.cpp
  - Env 管理 (parent chain, capture, lookup)
  - Cell 创建 / 读取 / 写入
  - Closure 环境捕获

evaluator_primitives_registry.cpp
  - primitives 注册表 (从 primitives_meta.h)
  - prim_dispatch 表构造
  - 自定义原语注册接口

evaluator_eval_flat.cpp
  - EvalResult 计算 (核心 hot path)
  - 8 种 Expr node 分发 (visit)
  - 算子执行

evaluator_adt.cpp
  - ADT 构造 (datatype ...)
  - ADT 字段访问
  - ADT 模式匹配 (match)

evaluator_defuse_index.cpp
  - DefuseIndex 维护 (closure / cell 的 mutation tracking)
  - Issue #1589 typed_mutation_audit

evaluator_module_loader.cpp
  - require / module-load
  - 模块作用域 (Issue #2566 multi-define)
  - free-var 解析

evaluator_workspace_tree.cpp
  - Workspace tree (workspace-tree 模型)
  - workspace 间变量共享

macro_expansion.cpp
  - 宏展开
  - Issue #2562 dual-field require-or-drop
```

### 3.3 跨 TU 接口

```cpp
// evaluator.ixx export 关键接口
export namespace aura::compiler {

class Evaluator {
public:
    // Constructor (in evaluator_ctor.cpp)
    Evaluator(const EvalConfig& cfg);

    // Eval flat (in evaluator_eval_flat.cpp)
    EvalResult eval_flat(const Expr& expr);

    // Env (in evaluator_env.cpp)
    class Env { /* ... */ };

    // ADT (in evaluator_adt.cpp)
    AdtHandle make_adt(const std::string& name, ...);

    // DefuseIndex (in evaluator_defuse_index.cpp)
    class DefuseIndex { /* ... */ };

    // Workspace (in evaluator_workspace_tree.cpp)
    class WorkspaceTree { /* ... */ };

private:
    // 私有字段,跨 TU 不访问
};

}  // namespace aura::compiler
```

### 3.4 eval_flat hot path

```cpp
// evaluator_eval_flat.cpp (核心 hot path)
EvalResult Evaluator::eval_flat(const Expr& expr) {
    // std::visit 模式匹配 8 种 Expr 节点
    return std::visit(*this, expr);
}

// visitor operator()
EvalResult Evaluator::operator()(const LiteralIntNode& n) {
    return EvalResult::fixnum(n.value);
}
EvalResult Evaluator::operator()(const CallNode& n) {
    // 1. eval function
    auto fn = eval_flat(*n.func);
    // 2. eval args
    std::vector<EvalResult> args;
    for (auto& a : n.args) args.push_back(eval_flat(*a));
    // 3. dispatch primitive / closure
    if (fn.is_primitive()) {
        return prim_dispatch(fn.prim_id(), args);
    } else {
        return invoke_closure(fn.closure_id(), args);
    }
}
// ... 其他 6 种节点
```

**关键 insight**: `std::visit` 是 **zero-overhead** 的虚函数替代。无需 RTTI,
无需 vtable,直接 jump table。

---

## 4. AOT (Ahead-Of-Time) 编译

### 4.1 AOT 流程

```
1. parse source → AST
2. type_check AST → typed AST
3. lower AST → IR
4. run passes on IR → optimized IR
5. LLVM IR generation (aura_jit.cpp / AOT 路径)
6. LLVM compile to .bc
7. clang link with lib/runtime.c (#4)
8. native binary (--emit-binary)
```

### 4.2 AOT Mangle

```cpp
// src/compiler/aot_mangle.h
// AOT name mangling (avoid collision in linker)
std::string aot_mangle_function(const std::string& name);
std::string aot_mangle_closure(int64_t closure_id);

// 例子:
//   aura_aot_closure_42
//   aura_aot_module_init_v1234
```

### 4.3 AOT 输出

```
AOT 编译产物:
  - .o files (LLVM 编译)
  - link with lib/runtime.c
  - 生成 native binary

--emit-binary: emit standalone binary
--emit-object: emit .o (for incremental linking)
```

### 4.4 AOT vs JIT 对比

| 维度 | AOT | JIT |
|------|-----|-----|
| **启动** | 慢 (编译期) | 快 (运行时) |
| **运行** | 快 (native) | 中 (解释/部分编译) |
| **迭代** | 慢 (改源码 → 重 AOT) | 快 (重 JIT) |
| **分发** | 单 binary | host + AOT + bridge |

---

## 5. JIT (LLVM ORC)

### 5.1 aura_jit.h — FlatInstruction

```cpp
// src/compiler/aura_jit.h
// LLVM ORC JIT backend for Aura IR
namespace aura::jit {

// Flat instruction format (C-compatible)
struct FlatInstruction {
    uint32_t opcode;
    uint32_t ops[4];
    // Issue #60 Iter 2: shape_id from per-function shape_map
};

// Opcode enum
enum Opcode {
    OP_PRIM_CALL,
    OP_CLOSURE_CALL,
    OP_LOOKUP,
    OP_DEFINE,
    OP_IF,
    OP_LET,
    // ...
};

// ORC JIT 引擎
class AuraJIT {
public:
    // 编译 IR → machine code
    void* compile(const IRModule& mod);

    // 执行
    int64_t invoke(void* fn_ptr, int64_t* args, int64_t count);
};

}  // namespace aura::jit
```

### 5.2 JIT Bridge (`aura_jit_bridge.cpp`)

```cpp
// src/compiler/aura_jit_bridge.cpp
// Host bridge — Aura bytecode ↔ host process

// Issue #1485 C2: dual-epoch fence
void aura_set_current_bridge_epoch(unsigned long long v);
unsigned long long aura_get_current_bridge_epoch(void);

// Issue #1485 C2: defuse_version
void aura_set_aot_defuse_version(unsigned long long v);
unsigned long long aura_get_aot_defuse_version(void);

// Issue #2576: PrimCall ABI (prim_id, args*, count)
int64_t aura_prim_dispatch_bridge(int64_t prim_id, int64_t* args, int64_t count);
```

### 5.3 Host + JIT 完整链路

```
host process:
  1. spawn Aura instance (aura_main)
  2. load source (Racket reader OR C++ reader)
  3. compile via AOT/JIT (mixed mode)
  4. host 提供 aura_jit_bridge.cpp 的实现
     - trace logging
     - JIT recompile decision
     - mutation epoch validation
  5. AOT .o calls bridge functions
  6. bridge 反向 call host services (GC, mutation)
```

### 5.4 JIT Stub (Standalone-AOT)

```cpp
// src/compiler/aura_jit_bridge_stub.cpp + aura_jit_prim_dispatch_stub.cpp
// Standalone-AOT 没 host bridge,所以 weak stubs 防止链接错误

// runtime.c (lib/) 提供:
extern "C" int64_t aura_prim_dispatch(int64_t prim_id, int64_t* args, int64_t count) {
    // 直接 dispatch 内部 prim_table
}
```

---

## 6. ADT Runtime (`adt_runtime.ixx`)

### 6.1 设计动机

```
原本 ADT (datatype ...) 在 evaluator.cpp 内 (g_adt_constructors global)
→ 问题:evaluator 是 monolithic,ADT 改动 → 全 TU 重编
→ 解决:ADT 拆出到 adt_runtime.ixx,per-Evaluator 实例化
```

### 6.2 实现

```cpp
// src/compiler/adt_runtime.ixx
// adt_runtime.ixx — ADT (datatype ...) support extracted from
// the monolithic evaluator TU (refactor Step 2.x, following
// the exact pattern of Issue #131 FFI extraction).

// This module owns the ADT constructor table (previously g_adt_constructors
// global + struct in evaluator). It provides a registration
// function that wires the ADT primitives/ctors into a Primitives table.

// The global state is now per-AdtRuntime instance (per Evaluator).
// Callers (Evaluator ctor) call register_primitives once during init.

// To avoid cyclic import with evaluator.ixx, we use RegisterFn callback
// (same as FFIRuntime).

class AdtRuntime {
public:
    // Register ADT constructor + primitive
    using RegisterFn = std::function<void(int64_t prim_id, int64_t fn_ptr)>;
    void register_primitives(RegisterFn cb);

private:
    std::unordered_map<std::string, AdtConstructor> ctors_;
};
```

### 6.3 Callback 注册模式

```
evaluator_ctor.cpp:
  1. 创建 Evaluator 实例
  2. 创建 AdtRuntime 实例
  3. evaluator_primitives_registry.cpp 注册基础 primitives
  4. adt_runtime.register_primitives(callback)
     → callback 注册 ADT 构造 + 字段访问
  5. evaluator_eval_flat.cpp 用 AdtRuntime 做 dispatch
```

**关键 insight**: callback 模式避免 module cyclic dependency (evaluator ↔
adt_runtime)。这是 FFI / Plugin 系统的经典做法。

---

## 7. Type Checker (`type_checker.ixx`)

### 7.1 类型系统概览

```
Aura 类型系统:
  - 基础类型: int, float, string, bool, void, char
  - 复合类型: pair, list, vector
  - 用户定义: ADT (datatype ...)
  - 函数类型: (args) → ret
  - 多态: type variables (类似 ML/Hindley-Milner)
  - Linear types (Issue #1535): MoveOp / LinearWrap / BorrowOp / DropOp
  - Soft/Sampled blame chain (#2561)
```

### 7.2 Type Checker 流程

```cpp
// src/compiler/type_checker.ixx
class TypeChecker {
public:
    // 1. collect constraints from AST
    Constraints collect(const AST& ast);

    // 2. unify constraints (Hindley-Milner + linear extension)
    Subst unify(const Constraints& c);

    // 3. check linear constraints (Issue #2561)
    //    - ownership check (MoveOp consumes, LinearWrap creates)
    //    - borrow check (BorrowOp borrows, must release)
    //    - blame chain (Soft / Sampled)

    // 4. emit diagnostics
    Diags diagnose(const Subst& s, const Constraints& c);
};
```

### 7.3 type_dep freshness

```
每个 type variable 带 "freshness" 标识:
  - Fresh:   未解析 (unification 候选)
  - Bound:   绑定到具体类型
  - Stale:   重新出现 (需要 re-unify)

Issue #2052: type_dep freshness 是 compile-time tracker,
确保 incremental compilation 时 type variable 不会 stale。
```

---

## 8. Cache + Pass Manager + IR

### 8.1 IR (`ir.ixx`)

```
Aura IR:
  - 与 AST 类似,但更适合优化
  - SSA-style (每个变量定义一次)
  - 含 type annotation
  - 含 provenance (cell / closure 来源)
  - 含 side-effect 标签 (linear types)
```

### 8.2 Pass Manager (`pass_manager.ixx`)

```
Pass 顺序 (Issue #2057):
  1. Constant Folding
  2. Dead Code Elimination
  3. Inline (small functions)
  4. Dirty Propagation (mutation tracking)
  5. Densify (consolidate writes)
  6. Type Check (post-pass)
  7. Final Code Gen
```

### 8.3 Cache (`cache.ixx`)

```
编译 cache:
  - key: (source_hash, options, version)
  - value: (bc / .o, type_info, symbol_table)
  - LRU bounded (bounded_lru.h)
  - invalidate on source change
```

---

## 9. 调优 Checklist

```
□ Compile 时间?
  - 修改 hot path (evaluator_eval_flat.cpp) 是否仅该 TU 重编?
  - 全 build (CMake) vs 增量 build (Ninja)

□ AOT vs JIT 选择?
  - Production: AOT (静态 + 稳定)
  - 开发迭代: JIT (快速 recompile)
  - hot path 性能: PGO + AOT
  - host + JIT 安全: 监控 epoch bump 频率

□ Type Check 性能?
  - 大文件 type check 时间?
  - linear type blame 频率?
  - Stale type_dep 重 unify 频率?

□ 编译 cache 命中率?
  - 命中率 > 80% 算有效
  - 监控 invalidate 频率

□ Pass Manager 开销?
  - 每个 pass 的耗时
  - 全 pass vs 增量 pass

□ AOT 输出大小?
  - --emit-binary 大小
  - Strip 符号表 (减少 binary size)
  - LTO (Link-Time Optimization)
```

---

## 10. v2 subseries 收官回顾（aura v2 #5）

接续 #1-4 v2,本文聚焦 Compiler。

```
aura v2 deep-dive 系列 (本篇为 #5):

#1 v2  Agent Orchestration (orch.ixx + agent_spawn.h + AgentScope) ✅
#2 v2  Build System (build.py + 9 gates + CMake + Sanitizer + PGO)  ✅
#3 v2  Parser (S-expression + Racket 兼容 + ABF)  ✅
#4 v2  Runtime (runtime.c + Pointer Tagging + AOT/JIT bridge + ABI)  ✅
#5 v2  Compiler (C++26 modules + AOT/JIT + Evaluator 8-TU P0 split)  ← 本文
#6 v2  Fiber System (concurrency + GC hooks + mutation safety)
#7 v2  Type System (type_dep freshness + denseness + linear types)
#8 v2  Module System (multi-define + require + free-vars)
#9 v2  JIT / AOT (aura_jit + hot-update + aot_mangle)
#10 v2 Self-Modification (代码自己进化的核心机制)
```

---

## 11. 下一篇预告

按 aura 主题自然顺序:

- **#6 v2 Fiber System** — concurrency + GC hooks + mutation safety(接 #4 Runtime + #1 Orchestration)
- **#7 v2 Type System** — type_dep freshness + denseness + linear types(接 #5 Compiler)
- **#8 v2 Module System** — multi-define + require + free-vars(接 #3 Parser + #5 Compiler)

下一篇选哪个?

---

## 12. 参考(可执行的源码锚点)

- `~/code/aura/src/compiler/evaluator.ixx` — Evaluator 主接口(本文核心)
- `~/code/aura/src/compiler/evaluator_*.cpp` — 8-TU P0 split
- `~/code/aura/src/compiler/aura_jit.h` — FlatInstruction + LLVM ORC JIT
- `~/code/aura/src/compiler/aura_jit.cpp` — JIT 实现
- `~/code/aura/src/compiler/aura_jit_bridge.cpp` — host bridge
- `~/code/aura/src/compiler/aura_jit_bridge_stub.cpp` — standalone-AOT weak stub
- `~/code/aura/src/compiler/aura_jit_prim_dispatch_stub.cpp` — prim dispatch stub
- `~/code/aura/src/compiler/aura_jit_runtime.cpp` — JIT runtime stub
- `~/code/aura/src/compiler/adt_runtime.ixx` — ADT constructor table(Issue #131 FFI extraction pattern)
- `~/code/aura/src/compiler/adt_runtime_impl.cpp`
- `~/code/aura/src/compiler/type_checker.ixx` — type checker
- `~/code/aura/src/compiler/type_checker_impl.cpp`
- `~/code/aura/src/compiler/aot_mangle.h` — AOT name mangling
- `~/code/aura/src/compiler/ast_walkers.ixx` — AST 遍历
- `~/code/aura/src/compiler/cache.ixx` — compile cache
- `~/code/aura/src/compiler/cache_impl.cpp`
- `~/code/aura/src/compiler/ir.ixx` — 中间表示
- `~/code/aura/src/compiler/ir_executor.ixx` — IR 执行
- `~/code/aura/src/compiler/lowering.ixx` — AST → IR
- `~/code/aura/src/compiler/pass_manager.ixx` — pass 管理
- `~/code/aura/src/compiler/coercion_map.ixx` — 类型 coercion
- `~/code/aura/src/compiler/diag.ixx` — 诊断
- `~/code/aura/src/compiler/constant_folding.ixx` — 常量折叠
- `~/code/aura/src/compiler/constant_folding_impl.cpp`
- `~/code/aura/src/compiler/observability_metrics.h` — CompilerMetrics (Issue #441)
- `~/code/aura/src/compiler/lock_order_audit.h` — 锁顺序审计
- `~/code/aura/src/compiler/typed_mutation_audit.h` — typed mutation audit (Issue #1589)
- `~/code/aura/src/compiler/primitives_meta.h` — primitives 元数据
- `~/code/aura/src/compiler/render_telemetry.hh` — render telemetry
- `~/code/aura/src/compiler/security_capabilities.h` — 安全 capabilities (Issue #1416)
- `~/code/aura/src/compiler/security_side_effect.hh` — side-effect (Issue #2057/#2152)
- `~/code/aura/cmake/AuraModules.cmake` — C++20 modules 编译选项
- `~/code/aura/CMakeLists.txt` — P0 split 注释

---

#5 v2 (aura) 完。