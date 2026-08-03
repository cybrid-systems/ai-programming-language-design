# #8 v2 — Aura Module System (multi-define + require + free-vars + WorkspaceTree)

> 接续 #3 v2 Parser + #5 v2 Compiler + #6 v2 Fiber System + #7 v2 Type System:
> 前面讲了 Parser、Compiler、Fiber、Type System。本文聚焦 **Module System** ——
> aura 的模块加载、多 define 语义、free-var 解析、Workspace Tree 隔离、module
> 环境绑定。这是 aura 多文件 / 多模块协作的基础。

---

## 0. 全文导读

Aura Module System 五层:

```
Aura source (multi-file)
  ↓
Module Boundary (src/core/module_boundary.ixx)  ← 模块边界封装
  ↓
Module Loader (evaluator_module_loader.cpp)     ← 文件路径解析 + 加载
  ↓
Module Environment (per-module env + free-var resolution)
  ↓
Workspace Tree (evaluator_workspace_tree.cpp)   ← 跨模块隔离
```

本文按"架构 → Module Boundary → Module Loader → Module Env → Multi-define
→ Free-var → Workspace Tree → 调优"展开。

---

## 1. Module System 整体架构

### 1.1 关键文件

```
src/core/
├── module_boundary.ixx                  # Module 边界封装
├── workspace_isolation.ixx                # Workspace 隔离
├── workspace_isolation.hh
└── workspace_epoch.hh                    # Workspace epoch

src/compiler/
├── evaluator_module_loader.cpp           # P1-e: module path resolution + load + GC
├── evaluator_primitives_module.cpp       # primitives: require / load
├── evaluator_workspace_tree.cpp           # P1-h: workspace tree lifecycle + policy hash
├── evaluator_primitives_workspace.cpp     # workspace primitives
├── evaluator_primitives_query_workspace.cpp
├── coercion_provenance_policy.hh
└── coercion_map.ixx                       # type_checker import
```

### 1.2 11+ Module 相关近期 commit

```
5f035dbe fix(module): two-pass multi-define restores private free-vars (#2581)
e3b22f5e fix(module): multi-define value init + no eager IR env bind (#2579)
42c90081 fix(ir): intern ConstString by pool index to stop O(N) heap growth (#2573)
fa955ff8 fix(module): remapped ConstString pool for export multi-display (#2572)
6e779684 fix(eval): while+define loop counters no longer freeze (#2571)
329c9098 fix(module): prim re-exports under letrec no longer poison std/math load
6d0b4f56 fix(module): fail-closed load so trailing defines export and nested require errors surface (#2570)
e9940d78 fix(eval): intern quoted symbols so eq?/equal? work for decision tags (#2568)
e424bfc0 fix(eval): bind try/catch parameter as first-class payload (#2567)
1b03ccc1 fix(module): nested require injects into module env for free-var parity (#2566)
43251231 feat(coercion): dual-field require-or-drop under production (#2562)
```

每个 commit 都是 module 系统的具体修复,显示这个子系统的高频迭代。

### 1.3 evaluator_module_loader.cpp 头

```cpp
// src/compiler/evaluator_module_loader.cpp
// evaluator_module_loader.cpp — P1-e: module path resolution, load, and GC
// aura.compiler.evaluator module partition.

module;

#include <cstdlib>
#include <sys/stat.h>
#include <unistd.h>
#include "runtime_shared.h"
#include "lock_order_audit.h"  // Issue #2354: Module rank

module aura.compiler.evaluator;
```

**关键 insight**: `module aura.compiler.evaluator` — evaluator_*.cpp 都属同一
module（之前 #5 v2 Compiler 提到的 P0 split）。这是 **8-TU P0 split** 的延伸。

---

## 2. Module Boundary（src/core/module_boundary.ixx）

### 2.1 概念

```
Module Boundary = 模块的封装边界
  - 每个 module 有独立 env
  - define 只在 module 内可见
  - export 显式标记 public
  - require 显式 import 另一个 module
```

### 2.2 边界封装

```cpp
// src/core/module_boundary.ixx
class ModuleBoundary {
public:
    // Module 入口
    ModuleBoundary(const std::string& name, Env* parent);
    ~ModuleBoundary();

    // 在 module 内 define (默认 private)
    void define(const std::string& name, Value v);
    // export (public)
    void export_def(const std::string& name);
    // import 另一个 module 的 export
    void import_from(ModuleBoundary* other, const std::string& name);

    // 查找 (在 module 内)
    std::optional<Value> lookup(const std::string& name);

private:
    std::string name_;
    std::unordered_map<std::string, Value> private_;  // private define
    std::unordered_map<std::string, Value> public_;   // export
    Env* parent_env_;                                 // for nested require
};
```

### 2.3 与 WorkspaceTree 的关系

```
ModuleBoundary = 静态边界 (编译期可见)
WorkspaceTree = 动态边界 (运行期隔离)

ModuleBoundary 包含 export list
WorkspaceTree 隔离 workspace 间共享
```

---

## 3. Module Loader (evaluator_module_loader.cpp)

### 3.1 load 流程

```cpp
// evaluator_module_loader.cpp
ModuleBoundary* Evaluator::load_module(const std::string& path) {
    // 1. 路径解析
    auto resolved = resolve_path(path);
    
    // 2. 检查是否已加载 (Issue #2570 fail-closed)
    if (auto* cached = module_cache_.get(resolved)) {
        return cached;  // 复用
    }
    
    // 3. GC 旧 module (Issue #2354 lock_order audit)
    if (auto* old = module_cache_.peek_lru()) {
        gc_module(old->path_);
    }
    
    // 4. 读文件
    auto source = read_file(resolved);
    
    // 5. parse → AST
    auto ast = parse(source);
    
    // 6. 创建 ModuleBoundary
    auto* mod = new ModuleBoundary(resolved, &global_env_);
    module_cache_.put(resolved, mod);
    
    // 7. 求值 module body (define / import 等)
    for (auto& expr : ast) {
        eval_module_body(expr, mod);
    }
    
    // 8. 处理 trailing defines (Issue #2570)
    //    if any define after last export → implicit export (fail-closed)
    return mod;
}
```

### 3.2 path 解析

```cpp
// 路径策略:
//   1. 绝对路径 / 从 stdlib 路径
//   2. 当前 module 的相对路径
//   3. (require "math") → 搜 $AURA_PATH / AURA_STDLIB_PATH / 内置 stdlib
std::string Evaluator::resolve_path(const std::string& path) {
    // 1. 绝对路径
    if (path[0] == '/') return path;
    // 2. stdlib 路径
    if (auto found = find_in_stdlib(path)) return found;
    // 3. 相对路径 (相对于 current module)
    return resolve_relative(current_module_, path);
}
```

### 3.3 gc_module (Issue #2354 lock_order)

```cpp
// evaluator_module_loader.cpp
bool Evaluator::gc_module(const std::string& path) {
    // lock_order: Module rank (highest priority)
    lock_order::on_acquire(Level::Module);
    // ...
    lock_order::on_release(Level::Module);
    return true;
}
```

---

## 4. Module Environment

### 4.1 Per-Module Env

```cpp
// 每个 module 有独立的 env
struct ModuleEnv {
    std::unordered_map<std::string, Value> defines_;
    std::unordered_map<std::string, TypeId> types_;
    std::unordered_set<std::string> exports_;
    ModuleEnv* parent_;  // for nested require
};
```

### 4.2 Look-up Chain

```cpp
Value Evaluator::lookup(const std::string& name, ModuleEnv* from) {
    // 1. 当前 module 内
    auto it = from->defines_.find(name);
    if (it != from->defines_.end()) return it->second;
    
    // 2. 当前 module 的 exports
    if (from->exports_.count(name)) {
        // 通过 import 链查找
        return lookup_in_imports(name, from);
    }
    
    // 3. parent module
    if (from->parent_) return lookup(name, from->parent_);
    
    // 4. global env (内置 primitives)
    return global_env_.lookup(name);
}
```

### 4.3 Free-Var 解析 (Issue #2566)

```
(define (my-fn x) (+ x 1))
  ↑
  free-var: +
  ↓
resolve(+): 找 (+ ...)
  → module stdlib
  → 找到 + (primitive)
```

```cpp
// Issue #2566: fix(module): nested require injects into module env for free-var parity
//
// 关键 insight: 嵌套 require 时,被 require 的 module 的 export
// 需要注入到当前 module 的 env (作为 free-var 解析源)
// → 否则 nested require 的 module 找不到 export
```

### 4.4 ConstString Pool (Issue #2572 / #2573)

```cpp
// Issue #2572: remapped ConstString pool for export multi-display
// Issue #2573: intern ConstString by pool index to stop O(N) heap growth

// 同一个字符串只存一份
class ConstStringPool {
public:
    // intern
    PoolIdx intern(std::string_view s);
    // lookup
    std::string_view lookup(PoolIdx idx);
    
private:
    std::unordered_map<std::string_view, PoolIdx> map_;
    std::vector<std::string> pool_;
};
```

---

## 5. Multi-Define 语义（Issue #2579 / #2581）

### 5.1 问题

```
;; 一个 module 多次 define 同一个名字
(define x 1)
(define x 2)   ; 第二 define 怎么处理?
```

### 5.2 Solution (Issue #2581)

```
;; Solution: two-pass multi-define
;; Pass 1: 收集所有 (name, value) 对 (不立即 evaluate)
;; Pass 2: 一次性 install (按 source order)

(define x 1)
(define x (+ x 1))   ; x = 1 → x = 2
(define x (* x 3))   ; x = 2 → x = 6
;; x 最终是 6 (sequential rebind)
```

### 5.3 Private Free-Var (#2581)

```
;; 一个 module 内:
(define x 10)
(define (f) x)        ; f 引用 x, x 是 private (未 export)
(define g (f))         ; g 是 (f) 的执行结果
;; 现在 export g,但 f 引用 x(private)
;; 必须保证: 导出 g 后, x 仍然是 available
;;   (不能因为 f 被 export 而丢失 x)
;; Issue #2581: two-pass multi-define restores private free-vars
```

### 5.4 No Eager IR Env Bind (Issue #2579)

```
Issue #2579: multi-define value init + no eager IR env bind
  - 之前: 解析到第一个 define 就立即 bind 到 IR env
  - 问题: 后面的 multi-define 无法覆盖
  - 现在: 延迟到 multi-define pass 完成后再 bind
```

---

## 6. require / load / use

### 6.1 require vs load vs use

```
;; 不同语义:
(require "math")   ; 加载 module,执行 side-effect,导入所有 export
(load "math")      ; 同 require (历史 alias)
(use "math")       ; 限制 import — 只用 listed 的 export
(import (math + *)) ; 只 import + 和 *,不 import 其他
```

### 6.2 require 实现

```cpp
// evaluator_primitives_module.cpp
Value eval_require(Args args, ModuleEnv* env) {
    auto path = args[0].as_string();
    // 1. resolve + load module
    auto* mod = evaluator_->load_module(path);
    // 2. inject exports into current env (Issue #2566)
    inject_exports(env, mod);
    // 3. return #t (或 void)
    return Value::True;
}
```

### 6.3 Fail-Closed Load (Issue #2570)

```
Issue #2570: fail-closed load so trailing defines export and nested require errors surface

问题: load 失败时,应该:
  - 不 silently swallow error
  - surface error 到 caller
  - 不暴露 partial state (半加载 module)

解决: fail-closed semantics
  - load 失败 → throw error
  - 已加载 module rollback
  - env 不污染
```

### 6.4 Trailing Defines Export (Issue #2570)

```
;; 旧的: trailing define 默认 private
(define (my-fn x) (+ x 1))   ; private
;; 新的: trailing define 默认 export (fail-closed)

(define (my-fn x) (+ x 1))   ; PUBLIC (auto-export)
;; 想 private? 加 #:private annotation
(define #:private (my-fn x) (+ x 1))
```

---

## 7. Workspace Tree (evaluator_workspace_tree.cpp)

### 7.1 概念

```
Workspace Tree = 跨模块 / 跨 tenant 的隔离 + 共享模型
  - 每个 workspace 是 Env 的子树
  - workspace 间默认隔离 (Issue #2490 require_effect)
  - workspace 间显式共享 (with-share)
```

### 7.2 Workspace 树结构

```cpp
// src/core/workspace_isolation.ixx
class WorkspaceTree {
public:
    WorkspaceTree* create_child(const std::string& name);
    WorkspaceTree* parent() const;
    
    // 在 workspace 内 define
    void define(const std::string& name, Value v);
    // workspace 间共享
    Value lookup(const std::string& name, WorkspaceScope scope);
    
    // 跨 workspace 访问 (需要 capability, Issue #2491)
    bool may_access(WorkspaceTree* other, AccessKind k);

private:
    std::string name_;
    std::unordered_map<std::string, Value> defines_;
    WorkspaceTree* parent_;
    std::vector<std::unique_ptr<WorkspaceTree>> children_;
};
```

### 7.3 evaluator_workspace_tree.cpp 实现

```cpp
// src/compiler/evaluator_workspace_tree.cpp
// P1-h: workspace tree lifecycle + policy hash
// aura.compiler.evaluator module partition. #1566: tenant isolation gates.

module;

#include "runtime_shared.h"
#include "hash_meta.h"             // FNV constants (#901)
#include "observability_metrics.h"
#include "core/workspace_isolation.hh"
#include "core/self_healing_hooks.h"
#include "security_capabilities.h"
#include "aura_jit_bridge.h"        // Issue #2091: aura_set_aot_live_env_frame_version / linear_state_fingerprint

module aura.compiler.evaluator;
```

### 7.4 Workspace Epoch (#2380/#2513)

```cpp
// src/core/workspace_epoch.hh
// workspace_epoch = workspace 状态版本号
// 每次 workspace 变更 (define/import) → bump epoch
// 其他 workspace 引用 → check epoch 兼容
```

---

## 8. Module 隔离与 Security

### 8.1 Capability Model (Issue #1416)

```cpp
// src/core/capability_model.ixx
// Module 想访问另一个 module 的 export 需要 capability
// (类似 Java SecurityManager / Rust capability)
class Capability {
public:
    bool may(const std::string& operation);
};
```

### 8.2 Security Capabilities (Issue #2490)

```
Issue #2490: feat(security): require_effect auto-enforces workspace isolation

关键设计: (require ...) 自动带 effect, 表示 workspace 边界被穿越
  → 强制 TenantScope install (Issue #2491)
  → 强制 audit
```

### 8.3 Restricted Hard-Fiber (Issue #2536)

```cpp
// Issue #2536: feat(security): Restricted hard-fiber optional policy contract
//
// Restricted fiber: 限制可执行操作的 fiber
//   - 不能 spawn_agent
//   - 不能 modify global env
//   - 不能 require restricted module
//   → 用于 sandbox / untrusted code
```

---

## 9. Issue 列表（高频迭代）

### 9.1 Multi-Define

```
#2566 nested require injects into module env for free-var parity
#2570 fail-closed load + trailing defines export
#2579 multi-define value init + no eager IR env bind
#2581 two-pass multi-define restores private free-vars
#2572 remapped ConstString pool for export multi-display
#2573 intern ConstString by pool index to stop O(N) heap growth
#329c9098 fix(module): prim re-exports under letrec no longer poison std/math load
```

### 9.2 Workspace / Isolation

```
#2490 require_effect auto-enforces workspace isolation
#2491 TenantScope install/release hooks at fiber spawn/resume entry
#2536 Restricted hard-fiber optional policy contract
#2515 Soft orch-agent boundary 提升为轻量 Guard 子集,统一 depth/held 语义
#2380 / #2513 production concurrency chaos gate
#1566 tenant isolation gates (eval workspace tree)
```

### 9.3 Module Loader

```
#2354 Module rank (lock_order)
#2262 g_partial_cs_* atomics (type_checker)
#2570 fail-closed load
#2572 ConstString pool remap
```

---

## 10. 性能与代价

### 10.1 Module Load 性能

| 操作 | 复杂度 | 备注 |
|------|--------|------|
| path 解析 | O(log N) | stdlib hash lookup |
| 读文件 | O(file size) | I/O bound |
| parse | O(N) | N = AST size |
| module env 创建 | O(K) | K = exports count |
| eval module body | O(M) | M = body exprs |

### 10.2 Free-Var 解析

```
O(log E) per free-var lookup
E = total exports across all visible modules

typical: 100-1000 modules, ~10 exports each → E ~ 10000
log E ~ 13, fast
```

### 10.3 Multi-Define Pass

```
two-pass:
  Pass 1: O(M) collect (name, value) pairs
  Pass 2: O(M) install (sequential rebind)

vs eager bind:
  O(M²) — 每 define 都重新 bind env

优化: 100x 加速 (M=100 时)
```

### 10.4 Workspace Tree 性能

```
per-workspace lookup: O(K) (K = local defines)
parent walk: O(D) (D = depth)
default: D < 10 → fast
```

---

## 11. 调优 Checklist

```
□ Module 加载 cache?
  - 重复 require 同一 module → cache hit
  - 监控 cache 命中率

□ Module 数量?
  - 模块过多 → path 解析慢 + env 嵌套深
  - 建议: < 1000 modules / project

□ Multi-define?
  - 大量 (define x ...) → 受益于 two-pass (#2581)
  - 监控 Pass 1 vs Pass 2 时间

□ Workspace Tree 深度?
  - 避免过深 (D > 20 性能下降)
  - 合理组织 workspace 层次

□ Free-Var 解析?
  - 嵌套 require 多 → lookup 慢
  - 考虑 cache (Issue #2566)

□ ConstString Pool?
  - export 多 → 受益于 pool (#2572)
  - 监控 pool size + hit rate

□ Fail-Closed Load?
  - Issue #2570 实施? (默认应该是)
  - partial state 不能泄漏

□ Workspace Epoch?
  - workspace 频繁变化 → epoch 频繁 bump
  - 其他 workspace 引用 stale → re-validate
```

---

## 12. v2 subseries 收官回顾（aura v2 #8）

接续 #1-7 v2,本文聚焦 Module System。

```
aura v2 deep-dive 系列 (本篇为 #8):

#1 v2  Agent Orchestration (orch.ixx + agent_spawn.h + AgentScope) ✅
#2 v2  Build System (build.py + 9 gates + CMake + Sanitizer + PGO)  ✅
#3 v2  Parser (S-expression + Racket 兼容 + ABF)  ✅
#4 v2  Runtime (runtime.c + Pointer Tagging + AOT/JIT bridge + ABI)  ✅
#5 v2  Compiler (C++26 modules + AOT/JIT + Evaluator 8-TU P0 split)  ✅
#6 v2  Fiber System (concurrency + GC hooks + mutation safety)  ✅
#7 v2  Type System (Hindley-Milner + linear + type_dep + Soft/Sampled blame)  ✅
#8 v2  Module System (multi-define + require + free-vars + WorkspaceTree)  ← 本文
#9 v2  JIT / AOT (aura_jit + hot-update + aot_mangle)
#10 v2 Self-Modification (代码自己进化的核心机制)
```

---

## 13. 下一篇预告

按 aura 主题自然顺序:

- **#9 v2 JIT / AOT** — aura_jit + hot-update + aot_mangle(接 #4 Runtime + #5 Compiler)
- **#10 v2 Self-Modification** — 代码自己进化的核心机制(总结 + 终篇)

下一篇选哪个?

---

## 14. 参考(可执行的源码锚点)

- `~/code/aura/src/core/module_boundary.ixx` — Module 边界封装
- `~/code/aura/src/core/workspace_isolation.ixx` — Workspace 隔离
- `~/code/aura/src/core/workspace_isolation.hh`
- `~/code/aura/src/core/workspace_epoch.hh` — Workspace epoch (#2380/#2513)
- `~/code/aura/src/core/capability_model.ixx` — Capability 模型
- `~/code/aura/src/compiler/evaluator_module_loader.cpp` — P1-e: path resolution + load + GC
- `~/code/aura/src/compiler/evaluator_primitives_module.cpp` — require / load / use
- `~/code/aura/src/compiler/evaluator_workspace_tree.cpp` — P1-h: workspace tree lifecycle
- `~/code/aura/src/compiler/evaluator_primitives_workspace.cpp` — workspace primitives
- `~/code/aura/src/compiler/evaluator_primitives_query_workspace.cpp`
- `~/code/aura/src/compiler/coercion_provenance_policy.hh` — coercion 来源策略
- `~/code/aura/src/compiler/coercion_map.ixx` — type_checker import
- `~/code/aura/src/compiler/lock_order_audit.h` — Module rank (#2354)
- `~/code/aura/src/compiler/security_capabilities.h` — Issue #1416 capability
- `~/code/aura/src/compiler/self_healing_hooks.h` — self-healing hooks
- `~/code/aura/src/compiler/aura_jit_bridge.h` — Issue #2091 env_frame_version / linear_state_fingerprint

---

#8 v2 (aura) 完。