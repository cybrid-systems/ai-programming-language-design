# Aura — C++26 Modules 模块结构与构建配置

**版本**：v1.0
**定位**：Aura C++26 Compiler as a Service 的源代码模块结构。覆盖从底层内存管理到高层查询引擎的完整依赖链。

---

## 1. 设计原则

1. **单向依赖，无循环** — 下层模块不依赖上层模块
2. **细粒度模块** — 每个模块职责单一，只在必要时才对外暴露
3. **模块分区** — 使用 C++26 Modules（`.ixx`）替代头文件，精确控制符号可见性
4. **聚合导出** — 每个子目录有一个聚合模块（如 `aura.core`），上层只需 `import aura.core`

---

## 2. 整体分层

```
aura.core                ← 零依赖基础层
    ↑
aura.parser              ← 词法/语法层
    ↑
aura.compiler            ← 前端 + 中端 + 后端
    ↑
aura.runtime             ← 执行引擎 (VM / JIT / 解释器)
    ↑
aura.query               ← 查询引擎 (AuraQuery eDSL 执行)
```

---

## 3. 完整目录结构

```
aura/
├── CMakeLists.txt
├── src/
│   ├── core/
│   │   ├── arena.ixx                 # ASTArena 内存池
│   │   ├── arena_impl.cpp
│   │   ├── ast.ixx                   # Trees that Grow AST 节点
│   │   ├── ast_impl.cpp
│   │   ├── diagnostics.ixx           # 诊断/错误报告
│   │   ├── diagnostics_impl.cpp
│   │   ├── source_location.ixx       # 源位置跟踪
│   │   ├── source_location_impl.cpp
│   │   └── core.ixx                  # 聚合导出模块
│   ├── parser/
│   │   ├── lexer.ixx                 # 词法分析器
│   │   ├── lexer_impl.cpp
│   │   ├── parser.ixx                # 递归下降 / PEG 解析器
│   │   ├── parser_impl.cpp
│   │   └── parser.ixx                # 聚合
│   ├── compiler/
│   │   ├── frontend.ixx              # 语义分析 + 类型检查
│   │   ├── frontend_impl.cpp
│   │   ├── optimizer.ixx             # IR 优化 Pass
│   │   ├── optimizer_impl.cpp
│   │   ├── codegen.ixx               # 代码生成 (LLVM IR / 字节码)
│   │   ├── codegen_impl.cpp
│   │   ├── compiler_service.ixx      # 完整编译管线入口
│   │   └── compiler.ixx              # 聚合
│   ├── runtime/
│   │   ├── vm.ixx                    # 字节码虚拟机
│   │   ├── vm_impl.cpp
│   │   ├── jit.ixx                   # LLVM ORC JIT
│   │   ├── jit_impl.cpp
│   │   ├── interpreter.ixx           # 纯解释器
│   │   └── runtime.ixx               # 聚合
│   ├── query/
│   │   ├── query_engine.ixx          # 对外统一查询接口
│   │   ├── query_engine_impl.cpp
│   │   ├── planner.ixx               # 查询计划生成
│   │   ├── planner_impl.cpp
│   │   ├── executor.ixx              # 查询执行器
│   │   └── query.ixx                 # 聚合
│   └── main.cpp
└── build/
```

---

## 4. 模块职责与导出类型

| 模块路径 | 职责 | 关键导出类型 | 依赖模块 |
|---------------------------|-----------------------------------|-----------------------------|--------------------|
| `aura.core.arena` | 高性能 Arena 分配器 | `ASTArena`, `create<T>()`, `SlabPool`, `MultiSlabPool` | std |
| `aura.core.ast` | Trees that Grow AST | `Expr`, `NodeTag`, `ParsedPhase`, `TypedPhase`, `LocatedPhase`, `LiteralIntNode`, `CallNode`, `LambdaNode`, `make_expr()` | `aura.core.arena` |
| `aura.core.diagnostics` | 错误/警告/提示 | `Diagnostic`, `DiagnosticEngine`, `Severity` | `aura.core` |
| `aura.core.source_location` | 源位置管理 | `SourceRange`, `SourceManager` | — |
| `aura.parser.lexer` | 词法分析 | `Token`, `TokenKind`, `Lexer` | `aura.core` |
| `aura.parser.parser` | S 表达式解析 | `parse()`, `ParseResult`, `Parser` | `aura.parser.lexer` |
| `aura.compiler.frontend` | 语义分析 + 类型检查 | `SemanticAnalyzer` | `aura.parser` |
| `aura.compiler.optimizer` | IR 优化 (常量折叠、DCE) | `OptimizerPass`, `IRModule` | `aura.compiler.frontend` |
| `aura.compiler.codegen` | 代码生成 | `CodeGenerator`, `emit()` | `aura.compiler.optimizer` |
| `aura.compiler.compiler_service` | 完整编译管线入口 | `CompilerService::compile()` | 以上所有 |
| `aura.runtime.vm` | 字节码虚拟机 | `VM`, `execute()` | `aura.compiler.codegen` |
| `aura.runtime.jit` | LLVM ORC JIT | `JITCompiler` | `aura.runtime.vm` |
| `aura.runtime.interpreter` | 纯解释器 | `Interpreter` | `aura.compiler.frontend` |
| `aura.query.query_engine` | 对外统一查询接口 | `QueryEngine`, `QueryResult` | `aura.compiler`, `aura.runtime` |
| `aura.query.planner` | 查询计划生成 | `QueryPlan`, `LogicalPlan` | `aura.compiler` |
| `aura.query.executor` | 查询执行 | `QueryExecutor` | `aura.runtime` |

---

## 5. 聚合模块

每个子目录的聚合模块 `xxx.ixx` 重新导出内部所有模块。上层只需 `import aura.xxx` 即可获得该层全部能力。

### `src/core/core.ixx`

```cpp
export module aura.core;

export import aura.core.arena;
export import aura.core.ast;
export import aura.core.diagnostics;
export import aura.core.source_location;
```

### `src/parser/parser.ixx`

```cpp
export module aura.parser;

export import aura.parser.lexer;
export import aura.parser.parser;
```

### `src/compiler/compiler.ixx`

```cpp
export module aura.compiler;

export import aura.compiler.frontend;
export import aura.compiler.optimizer;
export import aura.compiler.codegen;
export import aura.compiler.compiler_service;
```

### `src/runtime/runtime.ixx`

```cpp
export module aura.runtime;

export import aura.runtime.vm;
export import aura.runtime.jit;
export import aura.runtime.interpreter;
```

### `src/query/query.ixx`

```cpp
export module aura.query;

export import aura.query.query_engine;
export import aura.query.planner;
export import aura.query.executor;
```

### 主程序中使用

```cpp
import aura.core;
import aura.compiler;
import aura.query;

int main() {
    aura::ast::ASTArena arena;
    aura::compiler::CompilerService service(arena);
    // ...
}
```

---

## 6. CMake 配置

### `CMakeLists.txt`

```cmake
cmake_minimum_required(VERSION 3.30)
project(aura LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 26)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPERIMENTAL_CXX_MODULE_CMAKE_API "2182bf5c-ef0d-489a-91da-49dbc3090d2a")

add_executable(aura)

# ─── 核心层 ───
target_sources(aura PRIVATE
    src/core/arena_impl.cpp
    src/core/ast_impl.cpp
    src/core/diagnostics_impl.cpp
    src/core/source_location_impl.cpp)
target_sources(aura PUBLIC FILE_SET CXX_MODULES BASE_DIRS src FILES
    src/core/arena.ixx
    src/core/ast.ixx
    src/core/diagnostics.ixx
    src/core/source_location.ixx
    src/core/core.ixx)

# ─── 解析层 ───
target_sources(aura PRIVATE
    src/parser/lexer_impl.cpp
    src/parser/parser_impl.cpp)
target_sources(aura PUBLIC FILE_SET CXX_MODULES BASE_DIRS src FILES
    src/parser/lexer.ixx
    src/parser/parser.ixx)

# ─── 编译层 ───
target_sources(aura PRIVATE
    src/compiler/frontend_impl.cpp
    src/compiler/optimizer_impl.cpp
    src/compiler/codegen_impl.cpp
    src/compiler/compiler_service_impl.cpp)
target_sources(aura PUBLIC FILE_SET CXX_MODULES BASE_DIRS src FILES
    src/compiler/frontend.ixx
    src/compiler/optimizer.ixx
    src/compiler/codegen.ixx
    src/compiler/compiler_service.ixx
    src/compiler/compiler.ixx)

# ─── 运行时 ───
target_sources(aura PRIVATE
    src/runtime/vm_impl.cpp
    src/runtime/jit_impl.cpp
    src/runtime/interpreter_impl.cpp)
target_sources(aura PUBLIC FILE_SET CXX_MODULES BASE_DIRS src FILES
    src/runtime/vm.ixx
    src/runtime/jit.ixx
    src/runtime/interpreter.ixx
    src/runtime/runtime.ixx)

# ─── 查询层 ───
target_sources(aura PRIVATE
    src/query/query_engine_impl.cpp
    src/query/planner_impl.cpp
    src/query/executor_impl.cpp)
target_sources(aura PUBLIC FILE_SET CXX_MODULES BASE_DIRS src FILES
    src/query/query_engine.ixx
    src/query/planner.ixx
    src/query/executor.ixx
    src/query/query.ixx)

target_sources(aura PRIVATE src/main.cpp)

target_compile_options(aura PRIVATE -fmodules -Wall -Wextra -Wpedantic -O2)
target_link_libraries(aura PRIVATE stdc++)
set_target_properties(aura PROPERTIES INTERPROCEDURAL_OPTIMIZATION TRUE)
```

---

## 7. 构建与验证

```bash
mkdir -p build && cd build
cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build . -j$(nproc)
./aura
```

---

## 8. 与设计文档的对应关系

| 设计文档 | 对应源代码模块 |
|----------|---------------|
| [ARCHITECTURE.md](./ARCHITECTURE.md) §3.1 Racket Frontend | — (Racket 端) |
| [ARCHITECTURE.md](./ARCHITECTURE.md) §3.2 ABF v2 | `aura.core.ast` + `aura.binary.*` |
| [ARCHITECTURE.md](./ARCHITECTURE.md) §3.3 AST 层 | `aura.core.ast` |
| [ARCHITECTURE.md](./ARCHITECTURE.md) §3.4 AuraIR 层 | `aura.compiler.optimizer` (IR 定义) |
| [ARCHITECTURE.md](./ARCHITECTURE.md) §3.5 AuraQueryEngine | `aura.query.*` |
| [ARCHITECTURE.md](./ARCHITECTURE.md) §3.6 Compiler as a Service | `aura.compiler.compiler_service` |
| [ARCHITECTURE.md](./ARCHITECTURE.md) §3.7 三层运行时 | `aura.runtime.*` |
| [SERIALIZATION.md](./SERIALIZATION.md) | `aura.core.ast` + `aura.binary.*` |
| [AURAQUERY.md](./AURAQUERY.md) | `aura.query.*` |

---

> **文件结构就是架构。**
> 从 `aura.core` 到 `aura.query` 的单向依赖链决定了编译器的增量编译边界，也决定了多 Agent 共享编译服务的模块隔离粒度。
>
> 实现仓库：[github.com/cybrid-systems/aura](https://github.com/cybrid-systems/aura)
