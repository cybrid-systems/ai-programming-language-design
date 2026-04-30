# Linux Kernel cgroup v1 vs v2 深度对比分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/cgroup/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：层级控制、控制器、cgroup v1 多树、v2 单一树

---

## 1. cgroup v1 — 多树架构

```
/sys/fs/cgroup/
├── cpu/           ← cpu 控制器
│   ├── docker/    ← container
│   └── system/    ← system slice
├── memory/        ← memory 控制器
│   └── docker/    ← container
└── freezer/      ← freezer 控制器
```

每个控制器独立树，进程可属于不同树的多个 cgroup。

---

## 2. cgroup v2 — 单一树架构

```
/sys/fs/cgroup/
├── cgroup.controllers        ← 可用控制器列表
├── cgroup.max.depth          ← 最大深度
├── cgroup.stat              ← 统计
├── docker/                 ← container（所有控制器共享）
│   ├── cgroup.controllers   ← 继承的控制器
│   ├── cgroup.max.descendants
│   ├── cgroup.procs
│   ├── cpu.pressure
│   ├── memory.pressure
│   └── io.pressure
└── system/
    ├── cpu.pressure
    └── memory.pressure
```

所有控制器在同一棵树，子 cgroup 继承父 cgroup 的控制器。

---

## 3. 关键差异

| 特性 | v1 | v2 |
|------|----|----|
| 树结构 | 每个控制器独立树 | 单一统一树 |
| 控制器传播 | 可选（cgroup.clone_children）| 强制继承 |
| 子树委派 | 复杂 | 简化（通过 cgroup.controllers）|
| 线程模式 | 进程级别 | 支持线程级别（cgroup.type）|
| 锁竞争 | 严重 | 改善（per-domain 锁）|

---

## 4. cgroup v2 资源控制

```c
// CPU：
cgroup.controllers = cpu cpuacct

// Memory：
memory.max = 1073741824        # 1GB 限制
memory.high = 805306368        # 高水位线

// I/O：
io.max = "8:0 rbps=104857600"  # 100MB/s 读限制

// CPU 压力：
cpu.pressure = "50 1000 10"    # 50% 利用率，1000ms 延迟
```

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `kernel/cgroup/cgroup.c` | cgroup v1+v2 核心 |
| `kernel/cgroup/cgroup-v2.c` | cgroup v2 实现 |
