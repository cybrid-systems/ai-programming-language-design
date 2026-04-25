# 实现路线图

> 基于双峰塔架构（Racket 前端 + C++/LLVM 后端）的语言工厂

---

## 阶段 0：奠基（当前优先级）

**目标**：把设计文档变成可运行的最小原型

### 0.1 IR 宪法规范 🔴 P0

**内容**：
- 定义 `CircuitIR` 数据结构：节点、元件、约束、证明义务
- 明确 Racket 前端 → IR 的翻译规则
- 明确 IR → C++ 后端的代码生成契约
- 约束表达式的语义模型（类型系统、证明逻辑）

**交付物**：
- `docs/ir-spec.md` — IR 规范文档
- `ir-types.rkt` — Racket 端的 IR 类型定义
- `ir-codegen.cpp` — C++ 端的 IR 消费模块

**时间**：2 周

---

### 0.2 CNL 约束自然语言 🔴 P0

**内容**：
- 将自然语言约束解析为 Rosette 可验证的约束表达式
- 支持的约束类型：KCL/KVL、参数范围、数值稳定性、非线性收敛
- LLM 辅助的意图理解 + 形式化规约双重校验

**交付物**：
- `cnl-parser.rkt` — CNL 解析器
- `cnl-rosette-bridge.rkt` — CNL → Rosette 转换
- `cnl-tests.rkt` — 约束测试套件

**时间**：2 周

---

### 0.3 电路 DSL 语法完善 🟡 P1

**内容**：
- 基于现有 `circuit-dsl-syntax-design.md`，补全元件库（二极管、MOSFET、运放）
- 子电路定义和实例化
- 参数化值和概率类型
- 分析类型扩展（AC、噪声、瞬态）

**交付物**：
- `circuit-dsl.rkt` — 完整 DSL 实现
- `basic-components-reference.md` 更新

**时间**：1 周

---

## 阶段 1：核心闭环

**目标**：打通"自然语言 → DSL → 形式验证 → C++ 输出"的完整流程

### 1.1 LLM → DSL 生成管道 🔴 P0

**内容**：
- 基于现有 `llm-integration-guide.md`，增强意图解析
- LLM 生成电路 DSL 代码
- 自动 AST 修复（缺失探测点、节点连续性检查）

**交付物**：
- `llm-circuit-generator.rkt` — 完整 LLM 集成
- 自然语言测试用例 ≥ 20 个

**时间**：1 周

---

### 1.2 Rosette 形式验证引擎 🔴 P0

**内容**：
- KCL/KVL 约束验证
- 参数范围验证（电阻 > 0、电容 > 0 等）
- 非线性收敛性证明（Newton-Raphson 迭代稳定性）
- 验证失败时的错误定位和约束追踪

**交付物**：
- `rosette-validator.rkt` — 验证引擎
- `rosette-kcl.rkt` — KCL/KVL 验证模块
- `rosette-nonlinear.rkt` — 非线性验证

**时间**：2 周

---

### 1.3 C++26 后端代码生成 🟡 P1

**内容**：
- 基于 `cpp26-daily-updates-2026-04*.md`，生成 C++26 仿真器代码
- std::meta 反射自动生成组件注册
- std::simd 加速（Newton-Raphson、矩阵运算）
- Contracts 运行时二次验证
- CMake 构建系统

**交付物**：
- `cpp-codegen.rkt` — C++ 代码生成器
- `cpp26-solver.cpp` — C++26 求解器模板
- `CMakeLists.txt` 模板

**时间**：2 周

---

### 1.4 Datalog 知识图谱 🟡 P1

**内容**：
- 意图历史存储（自然语言 → DSL → 验证结果）
- 约束来源追踪（哪个意图产生了哪个约束）
- 跨 Agent 协作支持（多 Agent 共享同一个图谱）
- 相似意图检索（避免重复设计）

**交付物**：
- `knowledge-graph.rkt` — Datalog 图谱实现
- `intent-store.rkt` — 意图存储和检索

**时间**：2 周

---

## 阶段 2：生产就绪

**目标**：把实验室原型变成可以部署的生产系统

### 2.1 Web Server + Middleware 🟢 P2

**内容**：
- 基于 `day-11-web-server-api.md` 和 `day-12-web-server-middleware-security.md`
- JWT 认证
- 请求级 Rosette 验证
- 结构化日志（JSON 格式）

**交付物**：
- `web-server.rkt` — 生产级 Web 服务
- `middleware/jwt-auth.rkt` — JWT 认证中间件
- `middleware/rosette-validate.rkt` — 请求验证中间件

**时间**：1 周

---

### 2.2 Places 分布式扩展 🟢 P2

**内容**：
- 基于 `day-08-racket-places-distributed.md`
- 多进程分布式电路仿真
- 跨 Place 共享 Datalog 图谱
- 负载均衡和故障恢复

**交付物**：
- `places-scheduler.rkt` — 分布式调度器
- `circuit-worker.rkt` — 工作进程实现

**时间**：2 周

---

### 2.3 Prometheus 可观测性 🟢 P2

**内容**：
- 基于 `day-13-logging-monitoring.md`
- `/metrics` 端点暴露
- 意图执行路径追踪
- 仿真性能指标（求解时间、收敛率）
- Grafana 仪表板配置

**交付物**：
- `metrics.rkt` — Prometheus 指标收集
- `tracing.rkt` — 链路追踪
- `grafana-dashboard.json` — 仪表板配置

**时间**：1 周

---

### 2.4 GPU 加速 🟢 P2

**内容**：
- 基于 `day-10-ffi-gpu-acceleration.md`
- FFI 调用 CUDA/ROCm
- 向量嵌入的语义搜索 GPU 加速
- 矩阵运算 SIMD + GPU 双通道

**交付物**：
- `gpu-ffi.rkt` — GPU FFI 接口
- `simd-matrix.cpp` — SIMD 矩阵运算
- `gpu-solver.cpp` — GPU 加速求解器

**时间**：2 周

---

## 阶段 3：进化

**目标**：为自举做准备，让语言有能力自己定义自己

### 3.1 IR 自描述（IR 自己用 DSL 定义） ⚠️ 中风险

**内容**：
- 用 Racket DSL 定义 IR 规范本身
- IR 的类型系统、约束规则都可以自描述
- 编译期自验证（IR 规范本身的一致性检查）

**触发条件**：IR 规范稳定后

**交付物**：
- `ir-dsl.rkt` — IR 自描述 DSL
- `ir-self-verify.rkt` — IR 规范自验证

**时间**：3 周

---

### 3.2 前端自举（用目标语言写前端） ⚠️ 高风险

**内容**：
- 用该语言自己实现的前端编译器，替换 Racket `#lang` 机制
- 卫生宏、多阶段编译必须完整迁移
- 前端自身的正确性用 Rosette 验证

**触发条件**：IR 自描述完成，且前端 DSL 稳定

**交付物**：
- `self-hosted-frontend/` — 自举前端实现

**时间**：4 周

---

### 3.3 后端自举（自研编译器替换 C++/LLVM） 🔴 高风险

**内容**：
- 前端 → IR → 自研后端 → 机器码
- 替代 LLVM 的优化通道、目标支持
- SMT 调用接口重新实现

**触发条件**：前端自举完成，且性能瓶颈无法绕过

**交付物**：
- `self-hosted-backend/` — 自研后端编译器

**时间**：6+ 周

---

## 里程碑时间线

```
Month 1-2: 阶段0（奠基）
├── IR 规范定义
├── CNL 约束解析
└── 电路 DSL 完善

Month 3-4: 阶段1（核心闭环）
├── LLM → DSL 管道
├── Rosette 形式验证
├── C++26 代码生成
└── Datalog 知识图谱

Month 5-6: 阶段2（生产就绪）
├── Web Server + JWT
├── Places 分布式
├── Prometheus 可观测性
└── GPU 加速

Month 7-9: 阶段3（进化）
├── IR 自描述
├── 前端自举
└── 后端自举（视情况）

总计：9+ 个月
```

---

## 优先级决策树

```
遇到技术难题时，优先级判断：

1. IR 规范不清楚？
   → 停所有其他工作，先定 IR

2. 形式验证失败？
   → 优先修复验证引擎，不是绕过验证

3. C++ 后端性能不达标？
   → 先看 Racket 前端是否引入了不必要的运行时开销

4. 多 Agent 协作出现语义不一致？
   → 检查 Datalog 图谱是否正确同步

5. 自举时机到了吗？
   → 按 BOOTSTRAP_SCENARIOS.md 的触发条件判断
```

---

## 关键依赖

```
IR 规范 ← 所有其他工作的基础
    ↓
CNL 约束 ← 依赖 IR 规范
    ↓
LLM 生成 ← 依赖 CNL 约束
    ↓
Rosette 验证 ← 依赖 CNL + IR
    ↓
C++ 后端 ← 依赖 IR + 验证通过
    ↓
自举 ← 依赖前端稳定 + IR 自描述
```

---

## 成功标准（每个阶段）

| 阶段 | 成功标准 |
|------|---------|
| **阶段0** | IR 规范可执行、CNL 约束可解析、DSL 语法覆盖 ≥ 80% 元件 |
| **阶段1** | 完整闭环可运行、≥ 20 个自然语言测试用例通过、形式验证覆盖率 ≥ 90% |
| **阶段2** | 生产环境可部署、响应时间 < 1s、分布式扩展性验证 |
| **阶段3** | IR 自描述通过自验证、前端自举正确性 ≥ 95%、后端自举性能不劣化 |

---

*本文档与 DESIGN_PHILOSOPHY.md、CORE_SERVICE_TARGET.md、TOP10_CORE_FEATURES.md 共同构成语言设计的核心文档。*
*最后更新：2026年4月25日*