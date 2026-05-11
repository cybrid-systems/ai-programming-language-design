# Aura — Compiler as a Service 集成方案

**版本**：v1.0
**对应**：M1 Phase 1 (C++26 Compiler Service)
**定位**：定义 CompilerService 的接口、生命周期、内存管理策略，支撑 AI Agent 实时变异 + 增量编译场景。

---

## 1. 为什么需要 Compiler as a Service？

传统编译器是**一次性的批处理工具**：

```
输入文件 → 编译 → 输出二进制 → 进程退出
```

对 AI Agent 场景，这个模式有根本性问题：

| 问题 | 影响 |
|------|------|
| 每次调用加载/卸载所有状态 | 启动延迟 ~100ms+ |
| AST 重建代价高 | 每次从零解析、分配 |
| 无法保留环境 | 环境/闭包/符号表全部丢失 |
| 无法增量 | 改一行也需全量编译 |

**Compiler as a Service** 将编译器变为**常驻进程**：

```
Agent ──request──→ CompilerService ──response──→ Agent
                   ↺ 保持状态
                   ↺ arena 复用
                   ↺ 环境持久化
```

---

## 2. CompilerService 接口设计

```cpp
class CompilerService {
public:
    // ==== 生命周期 ====
    CompilerService();                   // 初始化 arena + 求值环境
    void reset();                        // 回收 AST 内存（保留环境/闭包）

    // ==== 求值入口 ====
    EvalResult eval(std::string_view input);        // 树遍历器路径
    EvalResult eval_ir(std::string_view input);     // IR 管线路径

    // ==== 访问器 ====
    ASTArena& arena()；        // AST 内存池
    Evaluator& evaluator();    // 求值器（含环境、闭包）
    Parser& parser();          // 解析器（引用 arena）
};
```

### 请求生命周期

```
Time ──────────────────────────────────────────────────────→

      Request 1              Request 2              Request 3
┌───────────────┐     ┌───────────────┐     ┌───────────────┐
│ reset()       │     │ reset()       │     │ reset()       │
│ parse(...)    │     │ parse(...)    │     │ parse(...)    │
│ eval(...)     │     │ eval_ir(...)  │     │ eval(...)     │
│ return result │     │ return result │     │ return result │
└───────────────┘     └───────────────┘     └───────────────┘
       │                      │                      │
       └──────────────────────┴──────────────────────┘
         Arena 复用了 3 次，零堆分配（buffer 已存在）
         环境（闭包/define）跨请求持久化
```

---

## 3. 内存管理策略

### 3.1 默认模式：单 arena 复用

最适合 REPL / pipe / 单请求场景：

```cpp
CompilerService cs；
cs.eval("(define x 42)")；   // arena 分配 AST + 求值
cs.reset()；                    // AST 回收，x 保留在 eval 环境
cs.eval("(* x 2)")；           // 可引用上一次的绑定
```

### 3.2 多 arena 模式（增量编译）

每模块独立 arena，模块 A 的 reset 不影响模块 B：

```cpp
class ModuleArenaManager {
    std::pmr::unordered_map<std::string, ASTArena> modules;

    void compile_module(const std::string& name, string_view source) {
        auto& arena = modules[name]；
        arena.reset()；
        auto* ast = arena.create<Expr>(...)；
        // ... lower, compile, link
    }

    void unload_module(const std::string& name) {
        modules.erase(name)；  // arena 析构，整块释放
    }
};
```

### 3.3 跨请求持久化数据

某些数据需要 `reset()` 后仍然存活：

| 数据 | 存储位置 | 生命周期 |
|------|----------|----------|
| AST 节点 | Arena | reset 即失效 |
| 环境绑定 | Evaluator::Env | 进程生命周期 |
| 闭包表 | Evaluator::closures_ | 进程生命周期 |
| IRModule | 栈/vector | 每次 eval_ir 重新创建 |
| 诊断信息 | 栈/string | 请求结束时消费 |

---

## 4. 编译管线集成

```
CompilerService::eval_ir(input)
│
├─ 1. cs.reset()                          // 回收前次 AST
│
├─ 2. Parser::parse(input)                // 在当前 arena 分配 AST
│   └─ ASTArena::create<Expr>(...)         // bump 分配，~3ns
│
├─ 3. LoweringPass::lower(ast)            // Expr → IRModule
│   └─ 生成 IRFunction[]，存入栈 vector
│
├─ 4. ComputeKindAnalysis::analyze(func)  // Known/Unknown 标记
│
├─ 5. ArityChecker::check(module)         // 参数数量校验
│   ├─ 通过 → 继续
│   └─ 失败 → 返回诊断错误
│
├─ 6. IRInterpreter::execute()            // 执行 IR
│   └─ Result<int64>
│
└─ 7. Return EvalResult                   // arena 待回收
```

---

## 5. AI Agent 调用模式

### 5.1 Pipe 模式（最简单）

```cpp
// Agent 侧（Python/pseudo）
proc = subprocess.Popen(["./aura", "--serve"],
                        stdin=PIPE, stdout=PIPE)

while True:
    code = agent.generate_code()
    proc.stdin.write(code + "\n")
    proc.stdin.flush()
    result = proc.stdout.readline()
    agent.observe(result)  // Agent 观察结果，自我修正
```

### 5.2 UDS 模式（生产级）

```cpp
// --bind /tmp/aura.sock 模式
// Agent 通过 unix domain socket 发送请求
// CompilerService 常驻，接受多个 Agent 同时连接
```

### 5.3 自适应变异循环

```
Agent: (let ((x 1)) (+ x 1))  →  2
Agent: 改为 (let ((x "hello")) (+ x 1))
  CaaS: 类型错误 (如果加类型检查)
Agent: 修复为 (string-append x " world")
  CaaS: "hello world"
```

核心：CompilerService 的 `reset()` 仅回收内存，变异体在 arena 上快速重建，AI Agent 的每次尝试都在~1ms 内获得反馈。

---

## 6. 与现有架构的关系

```
aura_architecture.md 中的 "Compiler Service (C++26)" 框
         │
         ▼
  CompilerService          ← 本文档定义
  ├─ ASTArena              ← aura_memory_pool.md 定义
  ├─ Parser
  ├─ Evaluator (tree-walk)
  ├─ LoweringPass → IR
  ├─ ComputeKindAnalysis
  └─ ArityChecker
```

现有架构中的"AST Layer"、"AuraIR Layer"、"AuraQueryEngine"、"增量优化 Pass Chain"都将通过 CompilerService 统一入口暴露给 AI Agent。

---

## 7. 实现状态

| 组件 | 实现 | 位置 |
|------|------|------|
| ASTArena (pmr) | ✅ v1 | `src/core/arena.ixx` |
| CompilerService | ✅ v1 | `src/compiler/service.ixx` |
| eval() 路径 | ✅ | `service.ixx` |
| eval_ir() 路径 | ✅ | `service.ixx` |
| REPL 集成 | ✅ | `src/main.cpp` |
| pipe 模式集成 | ✅ | `src/main.cpp` |
| `--serve` 模式 | ⬜ | 后续 |
| 多 arena 管理器 | ⬜ | 后续 |
| ABF 集成至 service | ⬜ | 后续 |

---

## 引用

- 内存池设计：[aura_memory_pool.md](./aura_memory_pool.md)
- 架构总览：[aura_architecture.md](./aura_architecture.md)
- 实现代码：`aura/src/compiler/service.ixx`
