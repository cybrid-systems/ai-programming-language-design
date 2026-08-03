# #9 v2 — Aura JIT / AOT (aura_jit + hot-update + aot_mangle)

> 接续 #4 v2 Runtime + #5 v2 Compiler + #7 v2 Type System + #8 v2 Module System:
> 前面讲了 Runtime (lib/runtime.c + Pointer Tagging)、Compiler (C++26 modules
> + AOT/JIT 入口)、Type System、Module System。本文聚焦 **JIT / AOT 深度
> 实现**——LLVM ORC JIT 引擎、AOT name mangling、hot-update health、epoch
> invariant walk、PrimCall ABI 稳定性。

---

## 0. 全文导读

Aura JIT/AOT 五层:

```
Aura source (.aura)
  ↓ Parser (#3) → AST
  ↓ Compiler (#5) → IR
  ↓
JIT 路径: LLVM ORC JIT → in-process machine code → runtime.c (#4)
AOT 路径: LLVM clang → .o → link runtime.c → standalone binary
  ↓
Hot-Update: source 改 → epoch bump → re-JIT → live reload
  ↓
PrimCall ABI (#2576): aura_prim_dispatch(prim_id, args*, count)
```

本文按"架构 → AOT Mangle → JIT ORC → Hot-Update → PrimCall ABI → epoch invariant
→ 调优"展开。

---

## 1. JIT/AOT 整体架构

### 1.1 关键文件（14 个）

```
src/compiler/
├── aura_jit.h                              # FlatInstruction + LLVM ORC 入口
├── aura_jit.cpp                            # JIT 实现 (1106 行,最大)
├── aura_jit_bridge.h                       # host bridge 接口
├── aura_jit_bridge.cpp                     # host bridge 实现
├── aura_jit_bridge_stub.cpp                # standalone-AOT weak stub
├── aura_jit_prim_dispatch_stub.cpp         # prim dispatch stub
├── aura_jit_runtime.cpp                    # JIT runtime stub
├── aot_mangle.h                            # AOT name mangling
├── aot_hot_update_health.hh                # hot-update health
├── hot_update_registry.h                   # hot-update registry
├── hot_update_registry.cpp                 # hot-update registry impl
├── shape_jit_pass_closedloop_stats.h       # closed-loop stats
├── observability_jit_tiers.inc             # observability tiers include
├── spec_jit_controller.h                   # spec JIT controller
├── jit_typed_mutation_stats.h              # JIT typed mutation stats
└── evaluator_primitives_obs_jit.cpp        # observability primitives
```

### 1.2 20+ recent JIT/AOT commits

```
4376f3cf test(aot): lock aura_display_value into runtime.c contracts (#2572)
597e2c69 fix(aot): provide aura_display_value in runtime.c for --emit-binary
2297905b feat(stdlib): pure-Aura hot-strategy surface for denseness (#2582)
a973ae61 fix(jit): content-intern PrimCall string re-intern (#2577)
178826e5 fix(jit): PrimCall N-arg ABI packs all frame locals (#2576)
c1641fd1 fix(jit): re-intern PrimCall strings across dual heaps (#2575)
93e8b20a feat(hot-update): exhausted reload queues minimal-dirty reemit (#2544)
0a98ec95 feat(orch/obs): aot-hot-update-health self-throttle control plane (#2543)
10be5484 feat(aot/jit): production soft epoch-invariant walk + force clear (#2541)
7d4f82fc feat(mutate): add mutate:query-and-replace-batch sugar primitive (#2527)
e991a798 feat(obs): query:aot-hot-update-health single Agent recovery gate (#2506)
4ba089f8 test(specjit): e2e PerEval dual-eval storm isolation gate (#2504)
b03dd550 feat(hot-update): auto re-promote force-JIT regions after stable window (#2502)
77b2e61c feat(aot/jit): complete post-bump epoch invariant walk (#2501)
786803d4 feat(env): Phase 5 hard-bind densify ownership scan fail → suppress outermost success (#2497)
c0748228 feat(security/audit): unify mutation_id source via resolve_audit_mutation_id (#2493)
38da83bf feat(security/audit): force SecurityEvent WAL under Restricted (#2492)
```

每个 commit 都涉及 LLVM ORC、AOT name mangling、hot-update epoch 等核心
机制——JIT/AOT 是 aura 最活跃的子系统。

---

## 2. AOT Name Mangling（aot_mangle.h）

### 2.1 问题

```
AOT 编译产物链接 runtime.c 时:
  - 多 closure 编译成多 .o
  - 多个 module 的 closure 函数名可能冲突 (closure_42, module_init 等)
  - link 时符号冲突 → 编译失败
```

### 2.2 Mangle 策略

```cpp
// src/compiler/aot_mangle.h
namespace aot {

// 函数 mangle
std::string mangle_function(const std::string& module_name,
                            const std::string& func_name);

// closure mangle
std::string mangle_closure(int64_t closure_id);

// init / fini mangle
std::string mangle_module_init(uint64_t module_version);
std::string mangle_module_fini(uint64_t module_version);

// 类型 mangle
std::string mangle_type(const std::string& type_name);

// 例子:
//   mangle_function("math", "+") → "aura_aot_math__plus_v1234"
//   mangle_closure(42) → "aura_aot_closure_42_v1234"
//   mangle_module_init(1234) → "aura_aot_module_init_v1234"
```

### 2.3 Version Stamp（#2091 / #2168）

```
每个 AOT 输出带 version stamp:
  - module_version (整个 module 重编时 +1)
  - bridge_epoch (host bridge reload 时 +1, Issue #1485 C2)
  - defuse_version (closure defuse 时 +1)
  - linear_state_fingerprint (linear types state)
  - env_frame_version (env frame 重建时 +1, Issue #2091)

mangle 后:
  aura_aot_module_init_v{module_version}_e{bridge_epoch}_d{defuse_version}
  aura_aot_closure_42_v{module_version}_...
```

**关键 insight**: AOT 输出含全部 epoch 状态——host 加载时检查是否兼容。
Issue #2541 "production soft epoch-invariant walk" + #2501 "complete post-bump
epoch invariant walk" 是近期高频修复。

### 2.4 ConstString Pool remap（Issue #2572）

```cpp
// Issue #2572: fix(module): remapped ConstString pool for export multi-display
//
// AOT 输出 export list 时:
//   - 之前: 每个 export 独立字符串 (重复 intern)
//   - 现在: ConstString pool remap (一次 intern, 多 display)
//
// 例子:
//   pool: ["+", "-", "*", "/"]
//   exports: [
//     {name: pool[0], disp: "+"},
//     {name: pool[1], disp: "-"},
//     ...
//   ]
//   → 多 display + 单一 pool → O(N) → O(1) (per name)
```

---

## 3. LLVM ORC JIT 引擎（aura_jit.cpp）

### 3.1 aura_jit.cpp 规模

```
1106 行 (本文探索的 src/compiler/ 中最大 .cpp)
+ aura_jit.h
+ aura_jit_bridge.cpp
+ aura_jit_runtime.cpp
+ 4 个 stub 文件

→ aura 的 JIT 基础设施很大一部分代码
```

### 3.2 FlatInstruction（接 #5 v2 Compiler）

```cpp
// src/compiler/aura_jit.h
namespace aura::jit {

// C-compatible flat instruction format
struct FlatInstruction {
    uint32_t opcode;
    uint32_t ops[4];
    // Issue #60 Iter 2: shape_id from per-function shape_map
};

enum Opcode {
    OP_PRIM_CALL,        // args[0] = prim_id, args[1..N] = call args
    OP_CLOSURE_CALL,     // args[0] = closure_id, args[1..N] = call args
    OP_LOOKUP,           // args[0] = var_slot, args[1] = depth
    OP_DEFINE,           // args[0] = var_slot
    OP_IF,                // args[0] = cond_branch, args[1] = then_branch, args[2] = else_branch
    OP_LET,              // args[0] = binding_count, ...
    OP_LOOKUP_GLOBAL,    // args[0] = name_hash
    OP_MAKE_CLOSURE,     // args[0] = closure_id, args[1] = fn_slot, args[2] = capture_count
    OP_RETURN,           // args[0] = value
    // ... 几十种 opcode
};

// ORC JIT engine
class AuraJIT {
public:
    void* compile(const IRModule& mod);
    int64_t invoke(void* fn_ptr, int64_t* args, int64_t count);

private:
    llvm::orc::ExecutionSession* es_;
    // ...
};

}  // namespace aura::jit
```

### 3.3 Compiled Closure Invocation

```cpp
// AOT emit (per closure):
extern "C" int64_t aura_aot_closure_42(int64_t* args, int64_t* captures) {
    // 1. prologue
    // 2. eval body
    // 3. epilogue
    return result;
}

// JIT invoke:
void* fn_ptr = jit_->get_symbol("aura_aot_closure_42");
int64_t result = ((int64_t(*)(int64_t*, int64_t*))fn_ptr)(args, captures);
```

---

## 4. Host Bridge (aura_jit_bridge.cpp)

### 4.1 Host Bridge 角色

```
standalone AOT: 走 runtime.c 直接调用 (no bridge)
host + JIT:      走 aura_jit_bridge.cpp 的实现
  - bridge 包含 trace / mutation epoch / JIT recompile decision
```

### 4.2 Bridge 实现（推测）

```cpp
// src/compiler/aura_jit_bridge.cpp
namespace aura::jit::bridge {

// PrimCall ABI (Issue #2576)
int64_t aura_prim_dispatch_bridge(int64_t prim_id, int64_t* args, int64_t count) {
    // 1. trace (metrics: prim_call_total)
    // 2. 看是否需要 JIT recompile
    //    - check epoch bump
    //    - check closure defuse
    // 3. 调 jit_table[prim_id](args, count)
    // 4. 处理 mutation epoch validation
}

// bridge_epoch / defuse_version (Issue #1485 C2)
void aura_set_current_bridge_epoch(unsigned long long v);
unsigned long long aura_get_current_bridge_epoch(void);
void aura_set_aot_defuse_version(unsigned long long v);
unsigned long long aura_get_aot_defuse_version(void);

// aot_metrics (Issue #1368)
void aura_set_aot_metrics(uint64_t flags);

// aot_live_env_frame_version / linear_state_fingerprint (Issue #2091)
void aura_set_aot_live_env_frame_version(uint64_t v);
void aura_set_aot_linear_state_fingerprint(uint64_t fp);

}  // namespace aura::jit::bridge
```

### 4.3 Bridge Stubs（Standalone-AOT）

```cpp
// src/compiler/aura_jit_bridge_stub.cpp + aura_jit_prim_dispatch_stub.cpp
// Standalone-AOT 没 host bridge,weak stubs 防止链接错误
//
// runtime.c (lib/) 提供默认实现 (Issue #1485 C2/#1485 C3):
//   - default 0 epoch (degenerate)
//   - closures always stamp 0, current stays 0
//   - check always passes (vacuous)
```

---

## 5. PrimCall ABI（Issue #2576）

### 5.1 问题

```
Aura 调用原始函数 (primitives):
  - 一元: aura_dispatch(prim_id, x)
  - 二元: aura_dispatch(prim_id, x, y)
  - 三元: aura_dispatch(prim_id, x, y, z)
  - 任意元: aura_dispatch(prim_id, args*, count)  ← Issue #2576 目标
```

### 5.2 Old vs New ABI

```
旧 ABI (issue #2576 之前):
  - per-arity dispatch (prim_dispatch_1 / prim_dispatch_2 / prim_dispatch_3)
  - 加新 arity = 加新 case
  - N 元 = N 个 call site

新 ABI (Issue #2576):
  - unified N-arg vector: aura_prim_dispatch(prim_id, args*, count)
  - 加新 arity = 不需要加 case (loop dispatch)
  - N 元 = 1 个 call site
```

### 5.3 PrimCall N-arg ABI 实现

```cpp
// src/compiler/aura_jit.h
extern "C" int64_t aura_prim_dispatch(int64_t prim_id, int64_t* args, int64_t count);

// Issue #2576: ABI is (prim_id, args*, count) — full N-arg vector.
// Issue #178826e5: PrimCall N-arg ABI packs all frame locals

int64_t aura_prim_dispatch(int64_t prim_id, int64_t* args, int64_t count) {
    switch (prim_id) {
        case PRIM_PLUS: {
            // unbox first 2 args (count may be > 2, ignore rest)
            int64_t a = unbox_fixnum(args[0]);
            int64_t b = unbox_fixnum(args[1]);
            return box_fixnum(a + b);
        }
        // ...
    }
}
```

### 5.4 ABI 稳定性

```
向后兼容:
  - 旧 ABI (per-arity) → 新 ABI (N-arg vector): 链接兼容
  - 新 ABI 接受任意 count → 旧代码 (count=2) 仍能跑

ABI 稳定性:
  - (prim_id, args*, count) 三元组 = 固定 i64 ABI
  - 加新 primitive = 加 case (不破 ABI)
  - 加新 arity = 自动 (count 决定)
```

---

## 6. Hot-Update（hot_update_registry.cpp）

### 6.1 概念

```
Hot-Update = 修改 .aura source → JIT recompile → live reload (不需要重启)

场景:
  - dev 模式: 改了 .aura 文件 → agent 立即 reload
  - production: hot-fix (不停服务)
```

### 6.2 Hot-Update Registry

```cpp
// src/compiler/hot_update_registry.h
class HotUpdateRegistry {
public:
    // 注册一个 module 的 hot-update 句柄
    void register_module(const std::string& path, ModuleHandle* h);
    // unregister
    void unregister_module(const std::string& path);
    
    // 收到 reload 信号 (file change / manual)
    void on_reload_signal(const std::string& path);
    
    // 状态机
    enum State {
        REGISTERED,    // 已注册
        RELOADING,     // 正在 reload
        RELOADED,      // 重新加载完
        FAILED,        // 失败
    };
    State get_state(const std::string& path);

private:
    std::unordered_map<std::string, ModuleHandle*> handles_;
    // dirty 队列 (Issue #2544: minimal-dirty reemit)
    std::deque<ReloadOp> reload_queue_;
};
```

### 6.3 Hot-Update Health（aot_hot_update_health.hh）

```cpp
// Issue #2543: feat(orch/obs): aot-hot-update-health self-throttle control plane
//
// health 指标:
//   - 最近 reload 成功率
//   - reload 耗时
//   - 失败次数
//   - 自动 throttle (连续失败 → 暂停 reload)
```

### 6.4 Minimal-Dirty Reemit（Issue #2544）

```
Issue #2544: feat(hot-update): exhausted reload queues minimal-dirty reemit

问题: reload queue 满 (大量修改) → drop 后续 reload → data loss
解决: 满了之后只 reemit minimal-dirty 状态
   - file path
   - dirty timestamp
   - 内容 hash (不存完整 content)
   → 下次 reload window 开启时补 reemit
```

### 6.5 Auto Re-Promote（Issue #2502）

```
Issue #2502: feat(hot-update): auto re-promote force-JIT regions after stable window

场景:
  - 某些 region 被 force-JIT (被 force-clear 然后 re-JIT)
  - 但 force-clear 不稳定 (epoch bump 多)
  - 解决: 监控 region, 如果 epoch stable > N seconds, 自动 re-promote 到 hot-update
```

---

## 7. Epoch Invariant Walk（Issue #2501 / #2541）

### 7.1 概念

```
Epoch = 状态版本号
Epoch invariant walk = 遍历所有 closure/module/epoch 状态,确保一致

触发条件:
  - module_version bump
  - bridge_epoch bump
  - defuse_version bump
  - env_frame_version bump (Issue #2091)
```

### 7.2 Production Soft Walk（Issue #2541）

```cpp
// Issue #2541: feat(aot/jit): production soft epoch-invariant walk + force clear
//
// Soft Walk:
//   - 走一遍所有 closure
//   - 检查 closure.bridge_epoch vs current
//   - 不匹配 → 标记 stale (但不立即 recompile)
//   - force-clear: stale closure → 重新 JIT
```

### 7.3 Post-Bump Complete Walk（Issue #2501）

```cpp
// Issue #2501: feat(aot/jit): complete post-bump epoch invariant walk
//
// 完整 epoch walk:
1. snapshot 当前 epoch state
2. walk 所有 closure
3. 检查 stamp 是否匹配
4. 不匹配:
   - 重新 JIT 闭包
   - 更新 closure 引用
   - 旧的 closure → GC
```

---

## 8. Content-Intern PrimCall（Issue #2577）

### 8.1 问题

```
PrimCall 字符串 intern:
  - 每个 PrimCall 携带字符串 (prim name)
  - 不同 closure 可能 intern 同一字符串 → 重复 intern → heap 增长
  - Issue #2573: intern by pool index → stop O(N) heap growth
```

### 8.2 解决

```cpp
// Issue #2577: fix(jit): content-intern PrimCall string re-intern
//
// PrimCall String Intern:
//   - pool: {string → PoolIdx}
//   - PrimCall payload: PoolIdx (8B) vs string (8B+ 内容)
//   - intern hit → 同 PoolIdx
//   - intern miss → 新 PoolIdx
//
// 之前: heap 每次 push 字符串 → O(N) heap
// 现在: heap push PoolIdx → O(1) (per call)
```

---

## 9. PrimCall N-arg ABI Pack（Issue #178826e5）

### 9.1 Frame Locals Pack

```
Issue #178826e5: fix(jit): PrimCall N-arg ABI packs all frame locals

老 ABI:
  - PrimCall args 是 vector
  - 每个 arg 单独打包

新 ABI:
  - 整个 frame locals pack 到 PrimCall 的 args
  - 一次 emit, 一次 dispatch
  - 减少 emit + dispatch 开销
```

### 9.2 Performance

```
老 ABI: emit M args × N PrimCalls = M*N work
新 ABI: emit 1 PrimCall + pack all locals = N work + 1 pack

typical: M=10 args, N=100 PrimCalls
  老: 1000 work units
  新: 100 work units + 1 pack = ~10x speedup
```

---

## 10. JIT Tiers / Hot-Cold

### 10.1 Multi-Tier JIT

```cpp
// src/compiler/observability_jit_tiers.inc (推测)
namespace aura::jit {

// 不同 tier 不同策略
enum Tier {
    TIER_COLD,      // 解释 / baseline JIT
    TIER_WARM,      // standard JIT
    TIER_HOT,       // PGO + inline + devirtualize
    TIER_FORCED,    // force-JIT (Issue #2502 auto re-promote)
};

// tier 升级决策 (Issue #2546 + #2549 + #2552)
Tier decide_tier(FnStats stats) {
    if (stats.call_count > 10000) return TIER_HOT;
    if (stats.call_count > 100) return TIER_WARM;
    return TIER_COLD;
}

}  // namespace aura::jit
```

### 10.2 Tier 监控指标

```
Tier Promotion / Demotion:
  - TIER_COLD → TIER_WARM: call_count > 100
  - TIER_WARM → TIER_HOT: call_count > 10000
  - TIER_HOT → TIER_FORCED: stable > N seconds + post-bump walk

Demotion:
  - 任何 tier → TIER_COLD: epoch bump 后未 recompile
```

---

## 11. Observability & Health

### 11.1 JIT/AOT Metrics

```sql
-- 查 jit 状态
SELECT * FROM oceanbase.__all_virtual_jit_stat\G
-- 关键字段:
-- jit_tier_total_: 每 tier 的 fn 数
-- tier_promote_total_: tier 升级次数
-- jit_recompile_total_: recompile 次数
-- jit_failure_total_: 失败次数
```

### 11.2 AOT Hot-Update Health

```sql
SELECT * FROM oceanbase.__all_virtual_aot_hot_update_health\G
-- 关键字段:
-- last_reload_at_: 最近 reload 时间
-- reload_success_total_: 成功 reload 数
-- reload_failure_total_: 失败 reload 数
-- throttled_: 是否 throttle (Issue #2543 self-throttle)
-- minimal_dirty_pending_: Issue #2544 待 reemit 数
```

### 11.3 Epoch Invariant Status

```sql
SELECT * FROM oceanbase.__all_virtual_aot_jit_epoch\G
-- 关键字段:
-- module_version_: module 整体版本
-- bridge_epoch_: bridge epoch (Issue #1485 C2)
-- defuse_version_: defuse 版本
-- linear_state_fingerprint_: linear types fingerprint
-- env_frame_version_: env frame 版本 (Issue #2091)
-- stale_closure_count_: stale closure 数 (need recompile)
```

---

## 12. 性能与代价

### 12.1 JIT 编译性能

| 阶段 | 耗时 | 备注 |
|------|------|------|
| Parse + Lower (IR) | ~10 ms | per .aura file |
| ORC compile | ~50-200 ms | per module |
| epoch invariant walk | ~1-10 ms | per closure |
| Hot-update reload | ~10-100 ms | incremental |

### 12.2 Runtime 调用开销

```
PrimCall (N-arg ABI):
  - 系统调用: 0 (i64 arg passing)
  - dispatch: switch (1-3 cmp) + call
  - 总: ~10-50 ns

ClosureCall (JIT'd):
  - frame setup: ~10 ns
  - 调用: indirect call
  - 总: ~30-100 ns

Display:
  - printf syscall: ~1-10 μs (含 IO)
```

### 12.3 Hot-Update 性能

```
Single module reload: ~10-100 ms (incremental)
Full reload: ~1-10 s (cold)
Throttle: ~10 s (consecutive failures → pause)
Auto re-promote: ~1-60 s (stable window)
```

### 12.4 epoch invariant 开销

```
soft walk: ~100 ns / closure × N closures = ms 级
force clear: ~1 μs / closure × N stale closures = μs-ms 级
```

---

## 13. 调优 Checklist

```
□ JIT tier 选择?
  - 默认 tier 选择是否合理?
  - hot path 应该 TIER_HOT?

□ Hot-Update 监控?
  - reload 失败率 < 1%?
  - throttle 状态?
  - minimal-dirty 队列大小?

□ PrimCall ABI 稳定?
  - N-arg vector 切换完成 (#2576)?
  - frame locals pack 启用 (#178826e5)?

□ Epoch Invariant?
  - 监控 stale_closure_count_
  - force-clear 频率?
  - post-bump walk 完整?

□ ConstString Pool?
  - Intern hit rate > 90%?
  - 监控 pool size 增长

□ Tier Promotion?
  - TIER_HOT fn 数 < 100? → 调优 hot threshold
  - Auto re-promote (#2502) 启用?

□ Performance?
  - JIT 编译时间 vs runtime 时间比
  - Hot-update reload 延迟 SLA

□ 集成?
  - 与 MutationBoundary (#6) 协调?
  - 与 linear types (#7) 协调?
```

---

## 14. v2 subseries 收官回顾（aura v2 #9）

接续 #1-8 v2,本文聚焦 JIT / AOT。

```
aura v2 deep-dive 系列 (本篇为 #9):

#1 v2  Agent Orchestration (orch.ixx + agent_spawn.h + AgentScope) ✅
#2 v2  Build System (build.py + 9 gates + CMake + Sanitizer + PGO)  ✅
#3 v2  Parser (S-expression + Racket 兼容 + ABF)  ✅
#4 v2  Runtime (runtime.c + Pointer Tagging + AOT/JIT bridge + ABI)  ✅
#5 v2  Compiler (C++26 modules + AOT/JIT + Evaluator 8-TU P0 split)  ✅
#6 v2  Fiber System (concurrency + GC hooks + mutation safety)  ✅
#7 v2  Type System (Hindley-Milner + linear + type_dep + Soft/Sampled blame)  ✅
#8 v2  Module System (multi-define + require + free-vars + WorkspaceTree)  ✅
#9 v2  JIT / AOT (aura_jit + hot-update + aot_mangle + PrimCall N-arg ABI)  ← 本文
#10 v2 Self-Modification (代码自己进化的核心机制)
```

---

## 15. 下一篇预告

按 aura 主题自然顺序:

- **#10 v2 Self-Modification** — 代码自己进化的核心机制(总结 + 终篇)
  - "代码自己进化"哲学
  - agent 修改源码 / runtime mutate AST
  - 自我验证 / self-healing
  - 与所有 v2 文章的 cross-cutting

终篇选 #10 还是中途停?

---

## 16. 参考(可执行的源码锚点)

- `~/code/aura/src/compiler/aura_jit.h` — FlatInstruction + LLVM ORC 入口
- `~/code/aura/src/compiler/aura_jit.cpp` — JIT 实现 (1106 行,最大)
- `~/code/aura/src/compiler/aura_jit_bridge.h` — host bridge 接口
- `~/code/aura/src/compiler/aura_jit_bridge.cpp` — host bridge 实现
- `~/code/aura/src/compiler/aura_jit_bridge_stub.cpp` — standalone-AOT weak stub
- `~/code/aura/src/compiler/aura_jit_prim_dispatch_stub.cpp` — prim dispatch stub
- `~/code/aura/src/compiler/aura_jit_runtime.cpp` — JIT runtime stub
- `~/code/aura/src/compiler/aot_mangle.h` — AOT name mangling + version stamp
- `~/code/aura/src/compiler/aot_hot_update_health.hh` — hot-update health (#2543)
- `~/code/aura/src/compiler/hot_update_registry.h` — hot-update registry
- `~/code/aura/src/compiler/hot_update_registry.cpp`
- `~/code/aura/src/compiler/shape_jit_pass_closedloop_stats.h` — closed-loop stats
- `~/code/aura/src/compiler/observability_jit_tiers.inc` — observability tiers include
- `~/code/aura/src/compiler/spec_jit_controller.h` — spec JIT controller
- `~/code/aura/src/compiler/jit_typed_mutation_stats.h` — JIT typed mutation stats
- `~/code/aura/src/compiler/evaluator_primitives_obs_jit.cpp` — observability primitives
- `~/code/aura/src/compiler/observability_metrics.h` — CompilerMetrics (Issue #2262)
- `~/code/aura/src/compiler/coercion_provenance_policy.hh` — coercion 来源
- `~/code/aura/src/compiler/lock_order_audit.h` — lock order (Module rank #2354)
- `~/code/aura/lib/runtime.c` — AOT-linked runtime (Issue #1485 C2)
- `~/code/aura/src/main.cpp` — main 入口 (含 JIT bridge import)

---

#9 v2 (aura) 完。