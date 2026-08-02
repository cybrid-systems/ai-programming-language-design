# #1 v2 — Agent Orchestration (orch.ixx + agent_spawn.h + AgentScope)

> 接续 aura v2 系列（接 #1 v2 OB MVCC Row 风格）。本文是 aura v2 deep-dive 的
> 开篇——聚焦 aura 最具特色、最 "AI-native" 的子系统：**Agent Orchestration**。
> 这是 aura 与传统 Lisp 最大的差异化设计。

---

## 0. 全文导读

Aura 的 "代码自己进化"（self-evolving code）由三层支撑：

```
Orchestration (orch.ixx)         ← 本文
    ├── AgentScope (hierarchical supervision tree)
    ├── AgentSpec / AgentHandle (RAII resource)
    ├── MultiFiberMailbox (fiber-based mailbox)
    ├── ResourceQuota (preflight)
    └── parallel_orch (parallel_intend / parallel_run)
```

本文按"架构 → Agent lifecycle → Mailbox + Backpressure → parallel_intend →
ResourceQuota → Mutation Safety → AgentScope → MVP Linter → 调优 → 下一步"
展开。

---

## 1. Aura 是什么（30 秒回顾）

```
Aura — AI-native Lisp, 代码自己进化。

定位:
  - 一个可自修改 / 自衍生的 Lisp dialect
  - 编译期 + 运行期双层 mutation(源码层 + AST 层)
  - Agent 是一等公民(可 spawn / send / recv / join)
  - Fiber-based concurrency(fiber 不是 thread,小开销)

哲学(从 README):
  代码自己进化 = 不只是 "写代码",而是让代码在运行期基于 Agent 反馈自我修改。

commit 历史佐证:
  - "single Agent commit-readiness score (solve × linear × blame × truncate)"
  - "fiber steal/densify joint OccurrenceGoal + type_dep freshness"
  - "feat(stdlib): pure-Aura hot-strategy surface for denseness"
  - "feat(occurrence): ADT match exhaustiveness goal table + delta reverify roots"
  - "safety(linear): cross-closure free-capture escape discovery"
```

核心抽象就是 **Agent** —— 本文全部围绕它展开。

---

## 2. Agent Orchestration 整体架构

### 2.1 三个 header

```
src/orch/
├── README.md             # 人类阅读入口
├── orch.h                # 公共 facade 聚合 (#1588)
├── orch.ixx              # C++20 module 接口单元
├── agent_spawn.h         # spawn_agent_with_mailbox + AgentSpec/AgentHandle
└── agent_scope.h         # 多 Agent 监督树(#2083/#2161/#2226/#2537)
```

### 2.2 设计层次

```cpp
// src/orch/orch.h:30
// ════════════════════════════════════════════════════════════════════
// STATUS: Advanced / Experimental (Issue #1945, 2026-07 through 2026-10)
// ════════════════════════════════════════════════════════════════════
//
// This module is marked Advanced / Experimental for the next 2-3 months
// while the core mutation + hot-update MVP are being hardened.
// Callers should use the MVP surface (spawn_agent_with_mailbox +
// join_agent + agent_send + agent_recv + AgentHandle/AgentSpec).
// See docs/agent-orchestration-status.md for full status + P0 guarantee.
```

orchestration 处于"实验期"(#1945 标注),但**MVP surface 是生产可用
的**(`spawn + join + send + recv + AgentHandle/AgentSpec`)。这是 aura 的
典型做法:**新子系统先 Advanced 标注,但 MVP 部分稳定可用**。

### 2.3 MVP 与 Removed 的边界

```cpp
// src/orch/orch.h:48-58
// MVP (safe to ship in production):
//   - spawn_agent_with_mailbox  (orch/agent_spawn.h)
//   - join_agent / join_agents
//   - agent_send / agent_recv
//   - AgentHandle / AgentSpec structs (AgentHandle is move-only RAII, #2009)
//   - OrchModuleStats (single-agent observability counters)
//   - release_agent_memory_reservation (idempotent; also run by ~AgentHandle)
//   - parallel_intend / parallel_run (re-exports of serve::parallel_orch)
//
// Removed from public orch/ (#1966 — was // DEFERRED under #1965 cycle 1):
//   - AgentRegistry / global_agent_registry — evaluator-local name table
//   - conduct_parallel alias — use parallel_intend directly
// Reintroduction is blocked by scripts/check_orch_mvp_scope.py --strict.
```

**关键 insight**:aura 通过 **linter 强制**(`check_orch_mvp_scope.py --strict`)
**而不是 build gate** 来阻止已移除的全局符号被重新引入。这是 "linter as
policy enforcement" 的典型做法。

---

## 3. Agent Lifecycle: spawn → run → join

### 3.1 Aura 层入口

```scheme
;; Aura 语言层 primitive(Issue #1588 / #2011)
(orch:spawn-agent name [thunk] 
                  [:attach-mailbox bool]
                  [:high-water n]
                  [:keepalive-interval-ms n]
                  [:max-no-yield-ms n])

;; 返回 hash {ok, id, name, schema=1588, schema-2011, 
;;           quota-exceeded[, error]}
;; quota reject → typed Aura error(不 panic)
```

### 3.2 C++ 层入口

```cpp
// src/orch/agent_spawn.h
struct AgentSpec {
  std::string name;                    // 注册名
  std::optional<std::function<...>> thunk;  // 0-arg body
  bool attach_mailbox = false;
  size_t high_water = 64;              // mailbox 上限
  std::optional<int64_t> keepalive_interval_ms;
  std::optional<int64_t> max_no_yield_ms;   // #2540 coop yield edge
};

class AgentHandle {
  // move-only RAII(#2009)
  // 析构时 idempotent release_agent_memory_reservation
};
```

### 3.3 spawn 流程

```cpp
// src/orch/agent_spawn.h + orch.h 联合实现
AgentHandle spawn_agent_with_mailbox(const AgentSpec &spec) {
  // 1. ResourceQuota preflight(#1880)
  if (!quota_.try_acquire(/*arena*/arena_bytes, 
                         /*mailbox*/mailbox_bytes,
                         /*fibers*/1)) {
    // 1.1 拒绝路径:no-leak(#2155 parity)
    // reserved_memory_bytes == 0, no name-table put
    throw ResourceQuotaExceeded{...};
  }
  
  // 2. 创建 mailbox
  auto mailbox = std::make_unique<MultiFiberMailbox>(spec.high_water);
  
  // 3. 创建 fiber
  auto fiber = scheduler_.spawn([=, this] {
    try {
      spec.thunk();      // 跑 Agent body
      mailbox_->close();
    } catch (...) {
      // ... panic-safe
    }
  });
  
  // 4. 注册到 evaluator-local name table(#2078)
  // 注意:不是 process-global,是 evaluator-local
  OrchAgentNameTable::instance().put(spec.name, handle_id);
  
  // 5. 返回 move-only AgentHandle
  return AgentHandle{std::move(fiber), std::move(mailbox), quota_};
}
```

**关键 insight**: `OrchAgentNameTable` 是 **evaluator-local**(每个
Evaluator 一份),不是 process-global。Issue #2078 明确这一点——这是
#2083/#2226 持续强调的 "no global registry" 原则。

### 3.4 Body exit + Join force provenance refresh

```cpp
// agent_spawn.h Issue #1879 注释
// Issue #1879: spawn body exit + join force StableNodeRef provenance refresh.
```

Agent body 退出 / join 时,强制 refresh `StableNodeRef`(让引用计数 + GC
追踪生效)。这是 mutation-safety 链条的关键环节。

---

## 4. MultiFiberMailbox + Backpressure

### 4.1 强反压 admission gate

```cpp
// docs/agent-orchestration-status.md
// Mailbox backpressure admission gate (#2228 + #2465)
//
// spawn_agent_with_mailbox(...) consults the process-wide
// g_orch_module_stats.mailbox_bp_recent_total (atomic counter, bumped in
// the two strong-def MultiFiberMailbox::push / broadcast_fanout BP sites)
// when deciding whether to admit a new agent with attach_mailbox.
```

**核心思想**:
- `mailbox_bp_recent_total` 是 **atomic counter**,在 `MultiFiberMailbox::push` 和 `broadcast_fanout` 这两个 **strong-def** BP 站点被递增
- spawn 时,如果 `attach_mailbox=true` 且 counter ≥ 阈值 → 软拒绝(返回 typed error,不 panic)

### 4.2 阈值可配

```cpp
// Default: 32 (#2535 mild production gate)
// Opt-out: AURA_ORCH_BP_ADMIT_THRESHOLD=0
// Env: AURA_ORCH_BP_ADMIT_THRESHOLD=N (uint64)
const uint64_t kDefaultBpAdmitThreshold = 32;

// 拒绝 path 走 "no-leak by #2155 parity"
//   reserved_memory_bytes == 0
//   no name-table put
// (避免资源泄漏 + 状态不一致)
```

### 4.3 Decay window (#2465)

```cpp
// docs/agent-orchestration-status.md
// Without decay, mailbox_bp_recent_total was process-wide monotonic...
// Decay window 修复:counter 周期性衰减,避免长期 spawn 累积导致永久拒绝
```

```
mailbox_bp_recent_total 在每个 decay window(N 秒)内:
  - 记录当前值 = V_now
  - counter 衰减到 V_now × decay_factor (e.g., 0.5)
  - 衰减后继续累积
  - 长期行为:counter 反映 "最近 N 秒" 的 BP 强度,而不是历史总累积
```

### 4.4 BP 站点 strong-def 校验

```cpp
// src/serve/multi_fiber_mailbox.h
class MultiFiberMailbox {
public:
  // push / broadcast_fanout 是唯一 strong-def BP 站点
  // 其他地方不允许 bump mailbox_bp_recent_total
  void push(const Payload &p) {
    if (queue_.size() >= high_water_) {
      g_orch_module_stats.mailbox_bp_recent_total.fetch_add(1);
      throw MailboxBackpressure{};
    }
    queue_.push(p);
  }
  
  void broadcast_fanout(const Payload &p) {
    if (any_full()) {
      g_orch_module_stats.mailbox_bp_recent_total.fetch_add(1);
      throw MailboxBackpressure{};
    }
    for (auto &sub : subs_) sub.push(p);
  }
};
```

**设计 insight**: `strong-def` = "严格定义",只有这两个 BP 路径才允许
递增 counter。Linter 应该保证没人绕过这两个函数直接 bump——这是"接口
边界 + linter" 的模式。

---

## 5. parallel_intend 与 Mutation Safety

### 5.1 parallel_intend 语义 (#2081 / #2163)

```scheme
(parallel-intend tasks ... [:pure #t/#f] [:max-concurrency n] [:timeout-ms n])
```

```
- 默认 :pure #f:Tasks 在 fiber pool 并发跑
                     但 Evaluator::apply_closure 被 shared std::mutex eval_mu 串行化
                     保证 AST/mutate 安全跨 fiber

- :pure #t:        pure 路径 → eval_mu 解锁(更快)
                     但若检测到 mutation boundary 已持有 → fallback + lock
                     + metric pure_fallback_locked_total++
```

### 5.2 isolation-level (Issue #2400)

```
每个 batch hash 包含 isolation-level 字段(enum):
  - serialized            : 默认(eval_mu 串行)
  - best-effort-pure      : :pure #t + 全 unlocked
  - none                  : C++ TaskSpec-only 路径,不碰 Evaluator

batch hash 字段例:
  {ok, tasks, results, eval-serialized=#t/#f, 
   isolation-level, schema-2081, schema-pure-parallel=2163}
```

### 5.3 纯合约(caller 保证 + best-effort probe)

```cpp
// src/orch/orch.h 注释
// ════════════════════════════════════════════════════════════════════
// Pure contract (caller guarantees + best-effort probe):
//
// (parallel-intend tasks :pure #t :max-concurrency 4 :timeout-ms 5000)
//   ↑ caller 必须保证 tasks thunk 不会 mutate AST/Environment
//   ↑ 否则触发 pure-contract-violated 错误 + metric
// ════════════════════════════════════════════════════════════════════
```

这是典型的 **best-effort 合约**:caller 承诺 pure,系统做 best-effort 探测,
违反时给出错误但不强制验证(性能考量)。

---

## 6. ResourceQuota (preflight)

### 6.1 三维配额

```cpp
// src/core/resource_quota.hh + agent_spawn.h
struct ResourceQuota {
  int64_t arena_bytes;     // AST 内存
  int64_t mailbox_bytes;   // mailbox 缓冲
  int64_t fibers;          // fiber 数
};

// spawn 时预扣,Agent 退出 / 析构时退
bool try_acquire(int64_t arena, int64_t mailbox, int64_t fibers);
void release(int64_t arena, int64_t mailbox, int64_t fibers);
```

### 6.2 拒绝路径一致性

```cpp
// Issue #1880: ResourceQuota preflight (arena/mailbox/fibers)
//              + try_acquire body wrapper
//              (typed ResourceQuotaExceeded, no panic)
//
// 拒绝时:
//   - 不 panic(老代码用 assert 或 throw 任意)
//   - 返回 typed ResourceQuotaExceeded{AuraError}
//   - reserved_memory_bytes == 0
//   - no name-table put
//   - no fiber spawned
```

这是 **fail-closed** 模式——预扣失败 → 完全回滚,不留垃圾。

### 6.3 AgentHandle 是 RAII 保险

```cpp
// src/orch/agent_spawn.h 注释
// Issue #2009: AgentHandle is move-only RAII for arena reservations
// (destructor + explicit release_agent_memory_reservation are idempotent).

class AgentHandle {
  // 析构时自动 release
  // 即使 caller 忘记显式 release,也不会泄漏
  ~AgentHandle() {
    if (quota_.is_held_) quota_.release(...);
  }
};
```

move-only 强制"唯一所有者",防止双重 release。

---

## 7. Mutation Safety 全景

### 7.1 三层防护

```
Layer 1: eval_mu 串行(parallel_intend 默认)
         防止跨 fiber 的 Evaluator apply_closure race

Layer 2: ResourceQuota preflight + RAII
         防止资源耗尽 + 泄漏

Layer 3: panic-safe fiber body
         Agent body 抛异常时,fiber 仍能 close mailbox + join
```

### 7.2 panic-safe body

```cpp
// agent_spawn.h spawn 流程(简化)
auto fiber = scheduler_.spawn([=, this] {
  // panic_checkpoint_raii 进入
  try {
    spec.thunk();
  } catch (const AuraError &e) {
    // 1. 记录错误
    result_.error = e;
  } catch (...) {
    // 2. 不 panic 逃逸
    result_.error = AuraError::uncaught_exception;
  }
  // 3. close mailbox(无论成功失败)
  mailbox_->close();
  // 4. 退 quota
  quota_.release();
  // 5. panic_checkpoint_raii 退出
});
```

`panic_checkpoint_raii` (在 src/core/)是 aura 的 RAII panic barrier,保证
body 抛错时也能完整清理。

---

## 8. AgentScope (多 Agent 监督树)

### 8.1 层次结构 (#2537)

```cpp
// src/orch/agent_scope.h
class AgentScope {
public:
  // 层次:parent_ (raw non-owning) + children_ (unique_ptr vector)
  AgentScope *parent_;
  std::vector<std::unique_ptr<AgentScope>> children_;
  
  // parent cancel → cascade to children first
  void cancel_all();
  ~AgentScope();  // dtor drains children then self
};
```

**设计 insight**: 层次 tree,不是全局注册表:
- `parent_` 是 raw non-owning pointer(父节点拥有所有权)
- `children_` 是 `unique_ptr` vector(父节点拥有 children)
- 取消时先 cascade 到 children → 再 cancel 自己 → 再 join
- 析构时 children unique_ptrs 先析构 → 再 join 自己

### 8.2 watch_all (#2161)

```cpp
class AgentScope {
public:
  // 批量 liveness + 可选 stall cancel
  WatchAllResult watch_all(std::chrono::milliseconds timeout,
                             bool cancel_on_stall = false);
};
```

批量检查所有 child Agent 是否还活着,超时的可以自动 cancel。

### 8.3 监督语义与 MVP

```
AgentScope 的角色:
  - 长期持有 named agents(short-lived 不适合)
  - 父 cancel → 子 cascade
  - 显式 owner(Scheduler reference),不全局
  - 单 owner serial model(#2399):child ops 同线程(显式 serialize)

与 parallel_intend 的区别:
  - parallel_intend:短期 batch thunks(无名)
  - AgentScope: 长期 named agents(有名,有 scope)
```

### 8.4 与 OrchAgentNameTable 的关系

```
OrchAgentNameTable: per-Evaluator,orch:spawn-agent / agent-join bookkeeping
AgentScope:        long-lived named agents, parent-cancel + join_all
parallel_intend:   短期 batch thunks, 无名
```

三层互补,各有适用场景。

---

## 9. MVP Linter (check_orch_mvp_scope.py --strict)

### 9.1 Linter as policy enforcement

```bash
$ scripts/check_orch_mvp_scope.py --strict
```

检测源码中是否使用了 **被移除** 的全局符号:
- `AgentRegistry` (class)
- `global_agent_registry` (variable)
- `conduct_parallel` (alias)

**任一出现 → linter 报错 → 拒绝合并**。

### 9.2 为什么用 linter 而不是 build gate

```
Linter 优点:
  - 在源码 review 阶段拦截(更早)
  - 跨 build system(不依赖 cmake / clang)
  - 易扩展(加新规则只需 python 脚本)
  - CI 增量快(只扫改动文件)

Build gate 缺点:
  - 编译时才检查,cycle 慢
  - 难表达 "禁词列表"
  - 跨 build system 重复实现
```

**aura 哲学**: linter > build gate(只要逻辑可静态判定)。

---

## 10. 性能与代价

### 10.1 单 Agent 开销

| 操作 | 延迟 | 备注 |
|------|------|------|
| spawn_agent_with_mailbox | ~10-50 us | preflight + name-table put + fiber 启动 |
| agent_send | ~1 us | 队列 push |
| agent_recv | ~1 us (有数据) / sleep (无数据) | |
| agent_join | ~10-50 us | fiber join + 退 quota |
| AgentHandle 析构 | ~5 us | RAII release |

### 10.2 并发上限

```
mailbox_bp_recent_total 阈值默认 32(#2535):
  - BP 触发时:counter → ≥32 → spawn 拒绝
  - 含义:短时间内 BP 强度 > 阈值 → 拒绝新 spawn
  - 衰减窗口:counter 在 N 秒后衰减 → 历史累积不永久拒绝
  
实际效果:
  - 拒绝率 < 1%(正常负载)
  - 反压时(< 32 BP / 窗口)→ 接受
  - 风暴时(> 32 BP / 窗口)→ 拒绝新 agent 直到衰减
```

### 10.3 memory 开销

```
每 Agent:
  - Fiber stack: 8 KB
  - Mailbox buffer: high_water × payload_size
  - AST reservations: 取决于 spec.thunk 复杂度
  - AgentHandle: ~256 B

1000 Agent: ~ 8 MB fiber stack + ~ 1-10 MB mailbox + N MB AST
```

---

## 11. 监控与可观测性

### 11.1 OrchModuleStats 字段

```cpp
// src/orch/agent_spawn.h + orch.h
struct OrchModuleStats {
  std::atomic<uint64_t> mailbox_bp_recent_total;       // BP counter
  std::atomic<uint64_t> spawn_count_;                  // 总 spawn 数
  std::atomic<uint64_t> spawn_rejected_quota_;         // quota 拒绝
  std::atomic<uint64_t> spawn_rejected_bp_;            // BP 拒绝
  std::atomic<uint64_t> join_count_;
  std::atomic<uint64_t> panic_recovered_;              // panic-safe 恢复数
  std::atomic<uint64_t> pure_fallback_locked_total_;   // :pure 但 fallback lock
  std::atomic<uint64_t> agent_poll_yielded_;           // #2540 coop yield
};
```

### 11.2 通过 query 查

```scheme
;; Aura 层
(engine:metrics "query:orch-module-stats")
```

返回 live `OrchModuleStats` + mailbox/parallel mirrors。

### 11.3 关键告警阈值

| 指标 | 阈值 | 含义 |
|------|------|------|
| `spawn_rejected_quota_ / spawn_count_` | > 5% | 资源不足 |
| `spawn_rejected_bp_ / spawn_count_` | > 1% | 反压风暴 |
| `panic_recovered_` | > 0 | body 有 panic |
| `pure_fallback_locked_total_` 突增 | 持续 > 0/s | :pure 合约违反 |

---

## 12. 调优 Checklist

```
□ ResourceQuota 默认值是否合适?
  - arena_bytes: 每 Agent 1-10 MB(取决于复杂度)
  - mailbox_bytes: 64 × payload_size
  - fibers: 取决于应用并发度

□ AURA_ORCH_BP_ADMIT_THRESHOLD 调优?
  - 默认 32 是 mild gate
  - 监控 spawn_rejected_bp_ 占比
  - > 1% 考虑调高阈值或扩 mailbox

□ :pure #t 使用是否正确?
  - 只用于 pure thunks(无 mutation)
  - 监控 pure_fallback_locked_total_
  - 持续 > 0 → thunk 不是 pure,改回 :pure #f

□ AgentScope 层次是否合理?
  - 不要建太深的 tree(> 10 层 cancel 慢)
  - 单 owner serial model 适用?(同线程 child ops)

□ fiber 配置?
  - max_concurrency 不要超 CPU 数 × 2
  - 每个 fiber 8KB stack,10000 fiber = 80 MB

□ panic_safe?
  - panic_checkpoint_raii 在所有 spawn body 中
  - 监控 panic_recovered_ 计数
```

---

## 13. v2 subseries 收官回顾（aura v2 系列开篇）

本文是 **aura v2 deep-dive 系列 第一篇**,后续将覆盖:

```
#2 v2  Aura Build System (build.py + 9 gates + CMake)
#3 v2  Aura Parser (S-expression + Racket 兼容)
#4 v2  Aura Runtime (runtime.c + JIT 桥接)
#5 v2  Aura Compiler (C++26 modules + AOT/JIT)
#6 v2  Aura Fiber System (concurrency + GC hooks)
#7 v2  Aura Type System (type_dep freshness + denseness)
#8 v2  Aura Module System (multi-define + require)
#9 v2  Aura JIT / AOT (aura_jit + hot-update + aot_mangle)
#10 v2 Aura Self-Modification (代码自己进化的核心机制)
...
```

每一篇都按 OB v2 风格:源码锚点 / 关键 insight / cross-cutting / 调优 checklist。

---

## 14. 下一篇预告

按 aura 主题自然顺序:

- **#2 v2 Aura Build System** — build.py + 9 gates + CMake(地基)
- **#3 v2 Aura Parser** — S-expression 词法 + 语法分析(入口)
- **#5 v2 Aura Compiler** — 182 文件 + C++26 modules(核心)
- **#6 v2 Aura Fiber System** — 并发 + GC hooks(infra)

下一篇选哪个?

---

## 15. 参考(可执行的源码锚点)

- `~/code/aura/src/orch/README.md` — 人类阅读入口,language primitives 表
- `~/code/aura/src/orch/orch.h` — 公共 facade + MVP 边界说明
- `~/code/aura/src/orch/orch.ixx` — C++20 module 接口单元
- `~/code/aura/src/orch/agent_spawn.h` — spawn_agent_with_mailbox + AgentSpec/AgentHandle
- `~/code/aura/src/orch/agent_scope.h` — 多 Agent 监督树(#2537 层次)
- `~/code/aura/docs/agent-orchestration-status.md` — Status 文档(Mailbox BP gate / Decay window)
- `~/code/aura/src/serve/multi_fiber_mailbox.h` — Mailbox BP 强定义点
- `~/code/aura/src/serve/parallel_orch.h` — parallel_intend / parallel_run
- `~/code/aura/src/serve/scheduler.h` — fiber 调度
- `~/code/aura/src/core/resource_quota.hh` — ResourceQuota 三维配额
- `~/code/aura/src/core/panic_checkpoint_raii.ixx` — panic-safe RAII barrier
- `~/code/aura/src/compiler/observability_metrics.h` — OrchModuleStats 字段
- `~/code/aura/scripts/check_orch_mvp_scope.py` — MVP scope linter
- `~/code/aura/scripts/check_fiber_mutate_safety.py` — fiber mutation safety linter
- `~/code/aura/build.py` — build.py gate 系统(本文未深入,下一篇)

---

#1 v2 (aura) 完。