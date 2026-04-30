# 27-cgroup_v2 — Cgroup v2 统一层级深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/cgroup/cgroup.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**cgroup v2（统一层级）** 是 Linux 控制组的最新版本，所有控制器在同一树中管理资源，替代了 v1 的多树模型。

---

## 1. cgroup v1 vs v2 对比

```
cgroup v1（多树）：
  /sys/fs/cgroup/
    cpu/           ← cpu 控制器子树
    memory/        ← memory 控制器子树（独立）
    blkio/         ← blkio 控制器子树（独立）
  问题：不同控制器的资源分配无法协调

cgroup v2（统一树）：
  /sys/fs/cgroup/
    user/          ← 所有控制器在同一树
      alice/       ← alice 的 cpu + memory + io 统一管理
      bob/         ← bob 的资源独立
```

---

## 2. 核心数据结构

### 2.1 cgroup_root — v2 根

```c
// kernel/cgroup/cgroup.c — cgroup_root
struct cgroup_root {
    struct cgroup        *cgrp;           // 根 cgroup
    unsigned long         subsys_mask;    // 启用的控制器掩码
    char                  name[CGROUP_NAMELEN]; // "cgroup2fs"
};
```

### 2.2 cgroup — 控制组

```c
// kernel/cgroup/cgroup.c — cgroup
struct cgroup {
    // 层级
    struct cgroup          *parent;        // 父 cgroup
    struct cgroup         *self;          // 指向自己的 cgroup_self
    struct cgroup_fs_context *ctx;        // 创建上下文

    // 子树控制
    unsigned long           subtree_control;  // 子树控制器掩码
    unsigned long           child_subtree_control; // 子孙可用的控制器

    // 控制器
    struct cgroup           *child;         // 第一个子 cgroup
    struct cgroup          *last_child;    // 最后一个子 cgroup
    struct cgroup          *children;       // 子 cgroup 链表

    // 资源
    struct cgroup_resources  resources;      // 资源状态
};
```

---

## 3. 子树控制

### 3.1 subtree_control

```c
// 开启子树的 cpu 控制器：
echo +cpu > /sys/fs/cgroup/user/cgroup.subtree_control

// 效果：user 下的所有子 cgroup 共享 user 的 cpu 资源
// 子 cgroup 不能单独管理 cpu（由 user 统一管理）
```

### 3.2 资源分配示例

```
/sys/fs/cgroup/user/alice/
  subtree_control = cpu,memory,io
  └─ alice/       ← 使用 cpu + memory + io（从 user 继承）
      └─ alice/app1/ ← 子 cgroup，共享 alice 的资源
```

---

## 4. 线程模式（Threaded Mode）

```c
// 线程模式允许同一进程树的线程在不同 cgroup：
echo threaded > /sys/fs/cgroup/user/alice/cgroup.type

// 线程模式下，线程可以在同属一个 cgroup 的不同子 cgroup 之间移动
```

---

## 5. 内存控制器

### 5.1 memory.max — 内存限制

```c
// 写入限制：
echo 1G > /sys/fs/cgroup/user/alice/memory.max

// 读取当前使用：
cat /sys/fs/cgroup/user/alice/memory.current

// 如果超过限制：
//   进程被移到 memory.repriority 或触发 OOM
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/cgroup/cgroup.c` | `struct cgroup_root`、`struct cgroup` |

---

## 7. 西游记类比

**cgroup v2** 就像"天庭的资源管理局"——

> 以前每个部门（v1 多树）独立管理自己的资源，玉帝（root）要协调跨部门资源分配很麻烦。cgroup v2 统一树就像把所有部门合并成一个大的资源管理局（统一层级），每个子部门（子 cgroup）在父部门的统一领导下分配资源。如果 user 下有 alice 和 bob 两个徒弟，他们共享 user 的 cpu 和 memory，但各自内部可以再细分。这就是 subtree_control 的意义——父部门统一管理，子部门按需分配。

---

## 8. 关联文章

- **cgroup v1**（article 94）：v1 的多树模型