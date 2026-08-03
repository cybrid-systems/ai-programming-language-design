# #7 v2 — Aura Type System (Hindley-Milner + linear + type_dep + Soft/Sampled blame)

> 接续 #5 v2 Compiler + #6 v2 Fiber System + #7 前的 6 篇 v2 deep-dive:
> 前面讲了 Compiler、Runtime、Fiber。本文聚焦 **Type System** ——Hindley-Milner
> 风格的多态 + Linear 类型（MoveOp/LinearWrap/BorrowOp/DropOp）+ type_dep freshness
> + Denseness + Soft/Sampled blame chain + ADT exhaustiveness。这是 aura 的类型
> 子系统——"代码自己进化"的静态保障。

---

## 0. 全文导读

Aura Type System 五层:

```
Type (src/core/type.ixx)
  ↓
Constraint System (type_checker.ixx: collect + unify)
  ↓
Linear Extension (MoveOp / LinearWrap / BorrowOp / DropOp)
  ↓
type_dep Freshness (steal/densify joint OccurrenceGoal)
  ↓
Soft / Sampled blame chain (recover + escalate)
  ↓
ADT exhaustiveness + MutateTypeGate + MutationSafety
```

本文按"架构 → Core Type → Constraint System → Linear → type_dep → Blame
→ Exhaustiveness → MutationSafety → 调优"展开。

---

## 1. Type System 整体架构

### 1.1 16+ Type 相关文件

```
src/core/type.ixx                              # Type 主定义
src/core/type_arena.ixx                        # Type arena 分配
src/core/type_impl.cpp                         # Type 实现

src/compiler/type_checker.ixx                  # C++20 module 接口
src/compiler/type_checker_impl.cpp             # 实现

src/compiler/type_concepts.ixx                 # Concept (类型类)
src/compiler/type_concepts_impl.cpp
src/compiler/evaluator_typecheck.cpp            # Evaluator 集成
src/compiler/evaluator_primitives_types.cpp     # primitives 类型

src/compiler/lowering_linear_types.ixx         # Linear lowering
src/compiler/lowering_linear_types_impl.cpp

src/compiler/typed_mutation_audit.h           # 类型化 mutation audit
src/compiler/typed_mutation_audit_pass.ixx
src/compiler/typed_mutation_audit_hooks.cpp
src/compiler/linear_occurrence_mutate_stats.h
src/compiler/jit_typed_mutation_stats.h

src/compiler/type_system_health.hh             # 类型系统健康
src/compiler/mutate_type_gate.hh               # MutateTypeGate
src/compiler/ownership_escape_lowering_gate.h  # Ownership escape gate

src/reflect/type_validate.hh                   # reflection 类型校验
```

### 1.2 关键依赖

```cpp
// src/compiler/type_checker.ixx (头 30 行)
module;

#include "compiler/observability_metrics.h"          // Issue #2262: g_partial_cs_* atomics
#include "compiler/ownership_escape_lowering_gate.h"  // Issue #2263
#include "compiler/typed_mutation_audit.h"             // Issue #2277: TypedMutationAuditCounters delta_timeout_*

export module aura.compiler.type_checker;

import std;
import aura.core;
import aura.core.type;
import aura.diag;
import aura.compiler.coercion_map;
```

### 1.3 近期高频迭代

```
Issue #2564 feat(occurrence): ADT match exhaustiveness goal table + delta reverify roots
Issue #2563 safety(linear): cross-closure free-capture escape discovery + force authority
Issue #2561 reliability(typecheck): Soft/Sampled blame chain recover + miss escalate
Issue #2560 perf(typecheck): partial re-infer cone soft/hard cap + type_dep fan-out
Issue #2559 chore(linear): three-layer linear invariant wire inventory gate
Issue #2555 feat(core): land real TransactionGuard (type-erased host)
Issue #2553 feat(audit): single Agent commit-readiness score (solve × linear × blame × truncate)
Issue #2552 feat(typecheck/fiber): steal/densify joint OccurrenceGoal + type_dep freshness
Issue #2548 feat(typecheck): richer TIMEOUT repair surface (degree-ranked roots + reason tags)
Issue #2538 feat(orch): typed correlation for agent-ask/reply
Issue #2527 feat(mutate): add mutate:query-and-replace-batch sugar primitive
Issue #2516 feat(typecheck): single dirty txn order invalidate→reinfer→mirror
Issue #2514 feat(linear): unify linear_synth_hard_fail with MutationBoundary exit
Issue #2508 perf(typecheck): OccurrenceGoal reverify before anti-starve full solve
Issue #2348 feat(typecheck): bidirectional check-mode for ADT match + GuardShape
Issue #2311 fix(mutation/render): RenderFastExit must not skip linear / match-site hard-gate
Issue #2288 feat(adt/typecheck): selective ADT exhaustiveness on infer_flat_partial main path
Issue #2279 feat(security): lock Soft MutateTypeGate out of production binaries
```

---

## 2. Core Type (`src/core/type.ixx`)

### 2.1 Type 表示

```cpp
// src/core/type.ixx
namespace aura::core {

// TypeId = 唯一类型标识符
using TypeId = uint32_t;

// Type 种类
enum class TypeKind {
    TVar,         // Type variable (未解析)
    TCon,         // Type constructor (具体类型)
    TApp,         // Type application (TCon applied to args)
    TFun,         // Function type (args → ret)
    TForall,      // Polymorphic type (∀)
    TLinear,      // Linear type (linear X)
    TRecord,      // Record type
    TVariant,     // Variant/ADT type
};

struct Type {
    TypeKind kind;
    TypeId id;
    // type 内部:
    // - TCon: builtin (int, float, string, bool, char, etc.)
    // - TApp: (constructor, [arg0, arg1, ...])
    // - TFun: ([arg0, ...], ret)
    // - TForall: ([var0, ...], body)
    // - TLinear: wrapped type (X with linear info)
    // - TRecord: ({field_name, type}[])
    // - TVariant: ({constructor_name, [field_type]}[])
};

}  // namespace aura::core
```

### 2.2 TypeId 分配（Type Arena）

```cpp
// src/core/type_arena.ixx
class TypeArena {
public:
    // 分配新 TypeId
    TypeId alloc(TypeKind kind);
    // 释放
    void free(TypeId id);

    // Intern (deduplication)
    TypeId intern(const Type &t);

private:
    std::vector<Type> arena_;
    std::unordered_map<Type, TypeId> interner_;  // 内容哈希 → TypeId
};
```

### 2.3 内置 TypeCon

```cpp
// 基础类型
constexpr TypeId kTypeInt     = 1;
constexpr TypeId kTypeFloat   = 2;
constexpr TypeId kTypeString  = 3;
constexpr TypeId kTypeBool    = 4;
constexpr TypeId kTypeChar    = 5;
constexpr TypeId kTypeVoid    = 6;
constexpr TypeId kTypeSymbol  = 7;

// 复合类型构造函数
constexpr TypeId kConPair    = 100;
constexpr TypeId kConList    = 101;
constexpr TypeId kConVector  = 102;
constexpr TypeId kConMap     = 103;
```

---

## 3. Constraint System (type_checker_impl.cpp)

### 3.1 三阶段 type check

```cpp
// 阶段 1: collect constraints from AST
Constraints collect(const AST& ast);

// 阶段 2: unify (Hindley-Milner + linear extension)
Subst unify(const Constraints& c);

// 阶段 3: check + diagnostics + blame
Diags check(const Subst& s, const Constraints& c);
```

### 3.2 TypeEnv

```cpp
// type_checker_impl.cpp
class TypeEnv {
public:
    void push_scope();
    void pop_scope();
    void bind(std::string name, TypeId type);
    TypeId lookup(const std::string& name);
    bool is_bound(const std::string& name) const;
    void collect_names(std::vector<std::string>& out) const;

private:
    std::vector<std::unordered_map<std::string, TypeId>> scopes_;
};
```

### 3.3 ConstraintSystem 关键方法

```cpp
// type_checker_impl.cpp
class ConstraintSystem {
public:
    void add(Constraint c);
    void note_touched_var(TypeId id);
    void mark_touched_on_delta(TypeId var, bool occurrence_narrow);
    void note_occurrence_goal(TypeId var, TypeId refined, uint32_t pred, ...);
    void note_adt_match_goal(uint32_t match_node, uint32_t adt_type_id, ...);
    void absorb_pending_adt_reverify_roots() noexcept;
    void mark_let_poly_dirty(TypeId var);
    void update_blame_chain_completeness_rate() noexcept;
    void record_cross_delta_blame_hit();
    void record_truncated_partial_blame(size_t scanned, size_t candidates);
    void append_hygiene_blame_frame(uint32_t node_id, ...);
    int constraint_reverify_priority(size_t idx) const;
    bool constraint_references_touched(const Constraint& c) const;
    bool reverify_clean_constraints_for_touched();

private:
    std::vector<Constraint> constraints_;
    std::unordered_set<TypeId> touched_vars_;      // type_dep freshness
    std::unordered_map<TypeId, OccurrenceGoal> occurrence_goals_;
    std::unordered_map<uint32_t, AdtMatchGoal> adt_match_goals_;
    std::vector<HygieneBlameFrame> blame_chain_;    // Soft/Sampled blame
};
```

### 3.4 Hindley-Milner Unification

```cpp
// 经典的 Hindley-Milner 风格 unify
Subst unify(TypeId t1, TypeId t2, Subst s) {
    // 1. 应用 substitution
    t1 = apply(s, t1);
    t2 = apply(s, t2);
    
    // 2. 相同 type
    if (t1 == t2) return s;
    
    // 3. type variable
    if (is_var(t1)) return bind(t1, t2, s);
    if (is_var(t2)) return bind(t2, t1, s);
    
    // 4. constructor / app
    if (kind(t1) == kind(t2)) {
        auto s1 = s;
        for (args) {
            s1 = unify(arg1, arg2, s1);
        }
        return s1;
    }
    
    // 5. occurs check (避免循环)
    if (occurs_in(t1, t2)) throw UnifyError{};
    
    // 6. mismatch
    throw UnifyError{};
}
```

### 3.5 Linear Extension

```cpp
// Linear 类型约束
struct LinearConstraint {
    enum Kind {
        MOVE,           // t1 被消费,所有权转移
        BORROW,         // t1 被借用,使用后归还
        WRAP_LINEAR,    // 把 t1 包成 Linear<t1>
        DROP,           // t1 被丢弃(必须是 owned)
    };
    Kind kind;
    TypeId t1;
    SourceLocation loc;
};

// Check linear constraints
Diags check_linear(const std::vector<LinearConstraint>& cs, const Subst& s);
```

---

## 4. type_dep Freshness (Issue #2052 / #2552)

### 4.1 概念

```
每个 type variable (TVar) 带 "freshness" 标识:
  - Fresh:    未解析(unification 候选)
  - Bound:    绑定到具体类型
  - Touched:  delta 期间被触碰(需要 re-unify)
  - Stale:    touched 但没及时 re-unify → 错误
```

### 4.2 Steal/Densify Joint OccurrenceGoal (Issue #2552)

```cpp
// Issue #2552: feat(typecheck/fiber): steal/densify joint OccurrenceGoal + type_dep freshness
// Issue #2549: demote is_stealable to candidate; snapshot is sole steal gate

// 在 fiber steal 时:
void on_fiber_steal(Fiber* f) {
    // 1. snapshot 当前 fiber 的 type_dep state
    Snapshot s = type_checker_->snapshot();
    
    // 2. steal fiber
    
    // 3. resume 后:
    //    - OccurrenceGoal reverify (Issue #2508)
    //    - type_dep freshness check
    //    - 如果 Stale: invalidate + re-infer (Issue #2516)
}
```

### 4.3 Dirty Txn Order (#2516)

```
single dirty txn order:
  1. invalidate(type_var)        # 标记 stale
  2. reinfer(type_var)            # 重新 unify
  3. mirror(occur_goal)           # 更新 OccurrenceGoal

这三个操作必须严格顺序执行,
不能并发 (Issue #2516 single dirty txn order)。
```

### 4.4 Touched 追踪

```cpp
// 触碰 type variable 的事件:
// 1. add(Constraint)         (约束涉及此 var)
// 2. bind / lookup           (env 涉及)
// 3. mutate (Issue #1589)    (mutation 涉及)
// 4. fiber resume (Issue #2552)

void note_touched_var(TypeId id);
void mark_touched_on_delta(TypeId var, bool occurrence_narrow);
```

---

## 5. Denseness (Issue #2578 / #2582)

### 5.1 概念

```
Denseness = "type-dep graph 的局部密度"
  - 高 denseness → 大量 type vars 集中在小区域 → 重 unify 代价高
  - 低 denseness → 稀疏 → 增量更新便宜
  - densify (verb) = 主动压缩 / 重排 type-dep graph 降低局部密度
```

### 5.2 Host Residuals (Issue #2578)

```cpp
// Issue #2578: fix(denseness): host residuals for orch rebind + dotted-rest types
//
// 关键 insight: 在 orch rebind (orch rebind, dotted-rest types) 时,
// 残留的 type vars 不能简单丢弃 (会破坏 type soundness)
// → 必须 host (保留并 reuse)
```

### 5.3 stdlib Hot-Strategy (Issue #2582)

```cpp
// Issue #2582: feat(stdlib): pure-Aura hot-strategy surface for denseness
// stdlib 选 pure-Aura 实现 → 减少 host ↔ aura 跨界调用
// → 减少 type check 跨界 (host type vs aura type)
// → 提升 denseness 性能
```

---

## 6. Linear Types（接 #6 Fiber / MutationSafety）

### 6.1 Linear 4 操作 (Issue #1535 / #2563)

```cpp
// src/compiler/lowering_linear_types.ixx

enum class LinearOp {
    MOVE,         // x = move(y): y 被消费,x 获得所有权
    WRAP_LINEAR,  // wrap(x): x → Linear<x>
    BORROW,       // borrow(x): 借用 x,使用后归还
    DROP,         // drop(x): x 是 owned,丢弃释放
};

// AST 表示
struct MoveOp { Expr dst; Expr src; };
struct LinearWrapOp { Expr inner; };
struct BorrowOp { Expr src; uint64_t region_id; };
struct DropOp { Expr val; };
```

### 6.2 Cross-Closure Free-Capture (Issue #2563)

```cpp
// Issue #2563: safety(linear): cross-closure free-capture escape discovery + force authority
//
// 问题: closure A 捕获 linear X,closure B 也想 capture X
//       → 同一 linear X 在两个 closure 中
//       → 一个 closure 释放 X,另一个 closure 用 dangling X
//
// 解决: type check 时检查 free-capture escape
//       强制 authority: 只能一个 closure 拥有 X
```

### 6.3 Wire Inventory (Issue #2559)

```
Issue #2559: three-layer linear invariant wire inventory gate
  - Layer 1: type level (Linear<X> 类型)
  - Layer 2: runtime level (aura_evaluator_mutation_boundary_depth)
  - Layer 3: mailbox level (linear_check_violates on push)

三层共同保证 linear invariant,任一层失效 → wire check fail。
```

### 6.4 Unify Hard-Fail (Issue #2545 / #2514)

```cpp
// Issue #2545: feat(linear): unify hard-fail decision entry force_linear_rollback
// Issue #2514: feat(linear): unify linear_synth_hard_fail with MutationBoundary exit
//
// 决策树:
//   linear violation detected
//     ├─→ Soft policy: metric + warning
//     ├─→ Hard policy: panic
//     └─→ Guard live (Issue #2514): force-rollback
```

### 6.5 Lowering (lowering_linear_types.ixx)

```cpp
// src/compiler/lowering_linear_types.ixx
// 把 AST 上的 Linear 4 ops lower 到 IR + runtime calls
//
// MoveOp      →  IR Move + linear_check_release
// LinearWrap  →  IR Wrap + linear_mark_owned
// BorrowOp    →  IR Borrow + region_enter/exit
// DropOp      →  IR Drop + linear_drop_release

class LinearLowering {
public:
    IR lower(const Expr& e);
    // 检查 linear violations:
    // - borrow 不闭合
    // - move 后 use
    // - drop 未 owned
};
```

---

## 7. Soft / Sampled Blame Chain（Issue #2561）

### 7.1 Blame 概念

```
Blame = 当 type check 失败时,定位"哪里该负责"。

传统: 简单的 blame — error span 指向具体位置
Soft:  多 frame blame — 错误沿 type dep chain 传播,可分摊到多层
Sampled: 大代码库下,只 blame top-K 帧 (性能优化)
```

### 7.2 关键方法

```cpp
// ConstraintSystem (type_checker_impl.cpp)
void update_blame_chain_completeness_rate() noexcept;
void record_cross_delta_blame_hit();
void record_truncated_partial_blame(size_t scanned, size_t candidates);
void append_hygiene_blame_frame(uint32_t node_id, ...);
```

### 7.3 Recover + Miss Escalate (#2561)

```
Issue #2561: reliability(typecheck): Soft/Sampled blame chain recover + miss escalate
  1. Recover: blame chain 失败时,可恢复的错误尝试恢复
     - error span 收缩到具体帧
     - 重试 partial re-infer
  2. Miss escalate: recover 失败 → escalate
     - 升为 hard error
     - panic / abort
     - metric blame_chain_miss_total++
```

### 7.4 Partial Re-Infer (Issue #2560)

```cpp
// Issue #2560: perf(typecheck): partial re-infer cone soft/hard cap + type_dep fan-out
// 不全量 re-infer,只 re-infer touched type vars (fan-out 邻接)

// Step 1: 找到 touched vars (BFS from delta sources)
// Step 2: 邻接的 vars 是 fan-out
// Step 3: 只 re-infer (touched + fan-out)
// Step 4: 软上限 (cap) 防止 blast radius 过大
// Step 5: 硬上限 (hard cap) 触发 partial blame
```

---

## 8. ADT Exhaustiveness (Issue #2564)

### 8.1 ADT match 检查

```scheme
;; Aura source
(match x
  [(Some a) ...]
  [(None) ...]
  [(Some _) ...])  ; 第二 Some 分支不可达

;; type check 时检测:
;;   - 覆盖了所有 constructor → exhaustive
;;   - 漏了某个 → non-exhaustive (warning)
;;   - 不可达分支 → unreachable (error)
```

### 8.2 Goal Table (Issue #2564)

```cpp
// Issue #2564: feat(occurrence): ADT match exhaustiveness goal table + delta reverify roots
//
// Goal Table:
//   key:   (match_node_id, adt_type_id)
//   value: AdtMatchGoal {
//       covered_ctors:  std::set<CtorId>,   // 已覆盖
//       all_ctors:      std::set<CtorId>,   // ADT 全部
//       missing_ctors:  std::set<CtorId>,   // 未覆盖
//       unreachable_ctors: std::set<CtorId>, // 不可达
//   }

// 每次 ADT 定义变更 → 更新 goal table
// 每次 match 检查 → 增量更新 + detect mismatch
```

### 8.3 Delta Reverify Roots

```
delta reverify roots:
  - 只 reverify 受 delta 影响的 match 节点
  - 其他节点复用旧结果
  - 大幅提升 incremental compilation 性能
```

### 8.4 Bidirectional Check (#2348)

```cpp
// Issue #2348: feat(typecheck): bidirectional check-mode for ADT match + GuardShape
//
// 双向检查:
//   Forward:  ADT → match (从 ADT 看 match)
//   Backward: match → ADT (从 match 看 ADT)
//
// 双向收敛 = exhaustive + no unreachable + no dead branch
```

---

## 9. TransactionGuard (#2555)

### 9.1 概念

```
TransactionGuard = 真正的 type-erased host 事务边界
  - 类似 MutationBoundary (Issue #2188) 但 type-erased
  - 提供 isolation-level 字段 (Issue #2400)
  - 跨 fiber / cross-closure 安全
```

### 9.2 type-erased host

```cpp
// Issue #2555: feat(core): land real TransactionGuard (type-erased host)
class TransactionGuard {
public:
    TransactionGuard();   // 构造 = 进入事务
    ~TransactionGuard();  // 析构 = 退出事务(rollback if dirty)

    // 是否 dirty
    bool is_dirty() const;

    // type-erased host:
    //   不检查具体 type
    //   检查 linear violation
    //   检查 mutation boundary 嵌套深度
};
```

### 9.3 与 MutationBoundary 关系

```
MutationBoundary (Issue #2188):
  - 检查 type-dep + linear
  - forbid blocking recv / yield
  - 由 evaluator 管理

TransactionGuard (Issue #2555):
  - type-erased
  - 跨 fiber / cross-closure
  - 由 host 管理
  - 真实事务语义 (rollback on dirty)
```

### 9.4 Single Agent Commit-Readiness (Issue #2553)

```cpp
// Issue #2553: feat(audit): single Agent commit-readiness score (solve × linear × blame × truncate)
// 综合得分:
//   - solve: type check 是否 solve 成功
//   - linear: linear check 是否 pass
//   - blame: blame chain 是否完整
//   - truncate: 是否被 partial cap 截断
// → 4 个维度 × 4 个 metric → 单一 score (0-1)
//
// 用于 Agent 决策: 现在 commit 安全吗?
```

---

## 10. MutateTypeGate (#2527 / #2279)

### 10.1 mutate query-and-replace-batch (#2527)

```scheme
;; Issue #2527: feat(mutate): add mutate:query-and-replace-batch sugar primitive
;; 原 mutate:query-and-replace:
;;   (mutate:query-and-replace pred-fn new-fn list) ; 一次性 mutate 整个 list
;; 新 batch:
;;   (mutate:query-and-replace-batch pred-fn new-fn list-list) ; 多 batch mutate
```

### 10.2 Soft MutateTypeGate (#2279)

```cpp
// Issue #2279: feat(security): lock Soft MutateTypeGate out of production binaries
//
// Soft MutateTypeGate: 在 dev / test 中允许 mutate
// Production: 锁定 — 不允许 mutate (除非显式 opt-in)
```

---

## 11. 性能与代价

### 11.1 Type Check 性能

| 操作 | 复杂度 | 备注 |
|------|--------|------|
| collect constraints | O(N) | N = AST size |
| unify (Hindley-Milner) | O(N log N) | with union-find |
| linear check | O(M) | M = linear ops count |
| ADT exhaustiveness | O(C) | C = ADT ctor count |
| partial re-infer | O(K log K) | K = touched vars |

### 11.2 type_dep freshness 开销

```
每次 fiber resume:
  - snapshot type_dep state: ~1-10 ns
  - OccurrenceGoal reverify: ~10-100 ns
  - 如果 stale → re-infer: ~μs 级

整体: per-fiber 1-10 μs (negligible)
```

### 11.3 Blame chain 开销

```
完整 blame: ~100 ns (top-3 frame)
Sampled blame (100 frames): ~1 μs
Soft recover: ~10-100 μs (视 recover 复杂度)
Hard escalate: O(1) (直接 abort)
```

### 11.4 增量 type check 性能

```
全量 re-infer: O(N^2)
增量 (touched + fan-out): O(K^2), K << N
典型: N=10K, K=100 → 100x 加速
```

---

## 12. 调优 Checklist

```
□ type check 全量 / 增量?
  - 增量 compile 时 K 是否 < 1% N?
  - 监控 touched_vars + fan-out size

□ Linear check 性能?
  - soft check vs hard check 选择?
  - MutateTypeGate 是否锁住?

□ ADT exhaustiveness?
  - goal table 是否 delta 维护?
  - unreachable 是否能早发现?

□ Blame chain?
  - Soft recover 命中率?
  - Miss escalate 频率?

□ 增量 invalidate 顺序?
  - invalidate → reinfer → mirror 顺序不能乱 (#2516)
  - 并发访问需要 serial

□ Type arena 内存?
  - intern dedup 命中率?
  - freed TypeId 是否及时 reuse?

□ Performance?
  - large file type check 时间?
  - blame chain 是否截断过多?
  - partial re-infer cone cap 是否合理?
```

---

## 13. v2 subseries 收官回顾（aura v2 #7）

接续 #1-6 v2,本文聚焦 Type System。

```
aura v2 deep-dive 系列 (本篇为 #7):

#1 v2  Agent Orchestration (orch.ixx + agent_spawn.h + AgentScope) ✅
#2 v2  Build System (build.py + 9 gates + CMake + Sanitizer + PGO)  ✅
#3 v2  Parser (S-expression + Racket 兼容 + ABF)  ✅
#4 v2  Runtime (runtime.c + Pointer Tagging + AOT/JIT bridge + ABI)  ✅
#5 v2  Compiler (C++26 modules + AOT/JIT + Evaluator 8-TU P0 split)  ✅
#6 v2  Fiber System (concurrency + GC hooks + mutation safety)  ✅
#7 v2  Type System (Hindley-Milner + linear + type_dep + Soft/Sampled blame)  ← 本文
#8 v2  Module System (multi-define + require + free-vars)
#9 v2  JIT / AOT (aura_jit + hot-update + aot_mangle)
#10 v2 Self-Modification (代码自己进化的核心机制)
```

---

## 14. 下一篇预告

按 aura 主题自然顺序:

- **#8 v2 Module System** — multi-define + require + free-vars(接 #3 Parser + #5 Compiler)
- **#9 v2 JIT / AOT** — aura_jit + hot-update + aot_mangle(接 #4 Runtime + #5 Compiler)
- **#10 v2 Self-Modification** — 代码自己进化的核心机制(总结 + 终篇)

下一篇选哪个?

---

## 15. 参考(可执行的源码锚点)

- `~/code/aura/src/core/type.ixx` — Type 主定义
- `~/code/aura/src/core/type_arena.ixx` — Type arena 分配
- `~/code/aura/src/core/type_impl.cpp` — Type 实现
- `~/code/aura/src/compiler/type_checker.ixx` — C++20 module 接口
- `~/code/aura/src/compiler/type_checker_impl.cpp` — ConstraintSystem + TypeEnv 实现
- `~/code/aura/src/compiler/type_concepts.ixx` — Concept (类型类)
- `~/code/aura/src/compiler/type_concepts_impl.cpp`
- `~/code/aura/src/compiler/evaluator_typecheck.cpp` — Evaluator 集成
- `~/code/aura/src/compiler/evaluator_primitives_types.cpp` — primitives 类型
- `~/code/aura/src/compiler/lowering_linear_types.ixx` — Linear lowering
- `~/code/aura/src/compiler/lowering_linear_types_impl.cpp`
- `~/code/aura/src/compiler/typed_mutation_audit.h` — 类型化 mutation audit
- `~/code/aura/src/compiler/typed_mutation_audit_pass.ixx`
- `~/code/aura/src/compiler/typed_mutation_audit_hooks.cpp`
- `~/code/aura/src/compiler/linear_occurrence_mutate_stats.h` — linear 统计
- `~/code/aura/src/compiler/jit_typed_mutation_stats.h` — JIT typed mutation stats
- `~/code/aura/src/compiler/type_system_health.hh` — 类型系统健康
- `~/code/aura/src/compiler/mutate_type_gate.hh` — MutateTypeGate (Issue #2279 prod 锁)
- `~/code/aura/src/compiler/ownership_escape_lowering_gate.h` — Ownership escape gate (Issue #2263)
- `~/code/aura/src/compiler/coercion_map.ixx` — 类型 coercion (type_checker import)
- `~/code/aura/src/reflect/type_validate.hh` — reflection 类型校验
- `~/code/aura/src/compiler/observability_metrics.h` — g_partial_cs_* atomics (Issue #2262)

---

#7 v2 (aura) 完。