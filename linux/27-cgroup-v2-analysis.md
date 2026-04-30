# cgroup v2 — 控制组统一层级深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/cgroup/cgroup.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**cgroup v2** 是 Linux 4.5+ 引入的统一控制组，与 v1 的区别：
- **单一树**：所有控制器在同一树中
- **强制继承**：子 cgroup 继承父 cgroup 的控制器
- **线程模式**：支持线程级别的 cgroup

---

## 1. 核心数据结构

### 1.1 cgroup — cgroup 描述符

```c
// kernel/cgroup/cgroup.h — cgroup
struct cgroup {
    // ID 和名称
    struct cgroup_id        id;             // 全局唯一 ID
    const char              *name;           // cgroup 名称
    struct cgroup          *parent;         // 父 cgroup
    struct list_head        children;        // 子 cgroup 链表

    // 子系统状态
    struct cgroup_subsys_state *subsys[CGROUP_SUBSYS_COUNT]; // 各控制器状态
    unsigned long           subtree_control;  // 启用的控制器
    unsigned long           subtree_ss_mask;   // 显式启用的控制器

    // 资源限制
    struct cgroup_files     *cftypes;       // cgroupfs 文件类型
    struct cgroup_fs_context *ctx;          // cgroupfs 上下文

    // 线程模式
    enum cgroup_thread_tag  thread_tag;      // 线程标签
    struct cgroup           *dom_cgrp;       // 域 cgroup（线程模式）
    struct list_head        threaded_cpusets; // 线程 cgroup 链表

    // 统计
    struct cgroup_base_stat base_cst;       // 基础统计
};
```

### 1.2 cgroup_subsys_state — 子系统状态

```c
// kernel/cgroup/cgroup.h — cgroup_subsys_state
struct cgroup_subsys_state {
    struct cgroup           *cgroup;          // 所属 cgroup
    struct cgroup_subsys   *ss;              // 控制器
    unsigned long           flags;            // CSS_* 标志

    // 层级统计
    struct css_refcount     refcnt;         // 引用计数

    // 各控制器特定
    union {
        struct cgroup_cpu    cpu;       // CPU 控制器
        struct cgroup_memory  memory;     // 内存控制器
        // ...
    };
};
```

### 1.3 cgroup_controller — 控制器

```c
// kernel/cgroup/cgroup.h — cgroup_controller
struct cgroup_controller {
    struct cgroup_subsys   *ss;          // 控制器
    unsigned long           cftypes;       // 文件类型
    struct cgroup          *cgrp;         // 所属 cgroup
};
```

---

## 2. cgroup 文件系统接口

### 2.1 cgroupfs 文件

```
/sys/fs/cgroup/
├── cgroup.controllers      ← 可用控制器列表
├── cgroup.max.depth        ← 最大深度
├── cgroup.stat             ← 统计
├── cgroup.subtree_control  ← 子 cgroup 启用的控制器
├── cgroup.procs            ← 进程列表
├── cpu.pressure            ← CPU 压力
├── memory.pressure         ← 内存压力
├── io.pressure             ← I/O 压力
└── <cgroup>/
```

### 2.2 资源限制

```c
// CPU 限制
cpu.max = "100000 1000000"     // 10% CPU
cpu.weight = 100               // 权重（权重比例）

// 内存限制
memory.max = 1073741824       // 1GB
memory.high = 805306368        // 高水位线（触发回收）
memory.low = 268435456         // 低水位线（触发预回收）

// I/O 限制
io.max = "8:0 rbps=104857600"  // 100MB/s
io.weight = 100                 // 权重
```

---

## 3. 线程模式（Threaded Cgroup）

```c
// cgroup v2 线程模式允许进程中的线程属于不同子 cgroup
// 子 cgroup 的线程被标记为 threaded
// 父 cgroup 被称为 domain cgroup

dom_cgrp                    ← 域 cgroup
├── threaded_cpusets[]     ← 线程 cgroup
│   ├── t1                 ← 线程 cgroup（共享父的资源控制）
│   └── t2
└── processes              ← 进程
```

---

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/cgroup/cgroup.h` | `struct cgroup`、`struct cgroup_subsys_state` |
| `kernel/cgroup/cgroup.c` | `cgroup_create`、`cgroup_apply_control` |
| `kernel/cgroup/cgroup-v2.c` | cgroup v2 特定实现 |