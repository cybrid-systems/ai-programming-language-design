# 135-cgroup-v1-v2 — 控制组深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/cgroup/cgroup.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**cgroup v1**（多树）和 **cgroup v2**（统一树）是 Linux 资源控制的两代架构。v1 每个控制器独立一棵树，v2 所有控制器在同一棵树中，支持协调的资源限制。

---

## 1. cgroup v1（多树模型）

### 1.1 控制器列表

```
cgroup v1 层级：

/sys/fs/cgroup/
  cpu/          ← CPU 控制器子树
  memory/       ← Memory 控制器子树
  blkio/        ← Block I/O 控制器子树
  cpuset/       ← CPU/内存节点分配
  net_cls/      ← 网络分类标记
  freezer/      ← 冻结进程组
  ...

问题：不同控制器的资源分配无法协调（如 CPU 和 Memory）
```

### 1.2 cgroupfs 挂载

```bash
# 分别挂载各控制器
mount -t cgroup -o cpu cpu /sys/fs/cgroup/cpu
mount -t cgroup -o memory memory /sys/fs/cgroup/memory

# 或一次性挂载所有
mount -t cgroup cgroup /sys/fs/cgroup
```

---

## 2. cgroup v2（统一树）

### 2.1 统一层级

```
cgroup v2 层级：

/sys/fs/cgroup/
  user/
    alice/         ← alice 的所有控制器（CPU + Memory + IO）
      app1/        ← 子 cgroup
    bob/           ← bob 的所有控制器
```

### 2.2 subtree_control — 子树控制

```c
// kernel/cgroup/cgroup.c — subtree_control
// 开启子树的控制器：
echo "+cpu +memory" > /sys/fs/cgroup/user/cgroup.subtree_control

// 效果：user 下的子 cgroup 共享 user 的 CPU 和内存资源
// 子 cgroup 不能独立管理这些资源（由 user 统一管理）
```

---

## 3. 核心数据结构

### 3.1 struct cgroup — 控制组

```c
// kernel/cgroup/cgroup.c — cgroup
struct cgroup {
    // 层级
    struct cgroup          *parent;          // 父 cgroup
    struct cgroup         *root;            // 根 cgroup

    // 子树
    unsigned long           subtree_control;    // 子树控制器掩码
    unsigned long           child_subtree_control; // 子孙可用控制器

    // 子 cgroup
    struct list_head        children;          // 子链表
    struct cgroup          *last_child;       // 最后一个子

    // 进程
    struct css_set         *cset;            // 关联的 css_set
    struct cgroup           *self;           // 指向自己的 cgroup

    // 控制器状态
    union {
        struct cgroup_id       id;            // cgroup ID
        unsigned long           dfl_datasize;
    };
};
```

### 3.2 struct css_set — cgroup 关联集

```c
// kernel/cgroup/cgroup.c — css_set
struct css_set {
    atomic_t                refcount;         // 引用计数
    struct hlist_node       hlist;            // 哈希表节点

    // 指向每个控制器的状态
    struct cgroup_subsys_state *subsys[CGROUP_SUBSYS_COUNT];
    //   cgroup v2 中只有一个（root），v1 中每个控制器一个

    // 进程链表
    struct list_head        tasks;            // 属于此 css_set 的进程
    struct list_head        mg_tasks;        // 正在迁移的进程
};
```

---

## 4. 进程到 cgroup 的映射

### 4.1 task_css_set — 获取进程的 cgroup

```c
// kernel/cgroup/cgroup.c — task_css_set
static inline struct css_set *task_css_set(struct task_struct *task)
{
    return rcu_dereference(task->cgroups);
}

// 进程在 cgroup 中的位置：
//   task_struct → cgroups (css_set*) → css_set.subsys[] → cgroup_subsys_state
//                                     → cgroup
```

---

## 5. 资源控制示例

### 5.1 memory cgroup（v1 & v2）

```bash
# v2：memory.max
echo "1G" > /sys/fs/cgroup/user/alice/memory.max
cat /sys/fs/cgroup/user/alice/memory.current  # 当前使用

# v2：CPU 权重
echo "100" > /sys/fs/cgroup/user/alice/cpu.weight
echo "1000" > /sys/fs/cgroup/user/bob/cpu.weight
# bob 的权重是 alice 的 10 倍，获得更多 CPU 时间

# v1：memory.limit_in_bytes
echo "1G" > /sys/fs/cgroup/memory/alice/memory.limit_in_bytes
```

---

## 6. v1 vs v2 对比

| 特性 | cgroup v1 | cgroup v2 |
|------|------------|------------|
| 树结构 | 多树（每控制器独立）| 统一树（所有控制器一树）|
| 资源协调 | 困难（跨控制器）| 容易（同一树下）|
| 线程模式 | 受限 | 支持（threaded cgroup）|
| 内存回收 | 分散 | 统一 |
| 容器支持 | 一般 | 更好 |

---

## 7. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/cgroup/cgroup.c` | `struct cgroup`、`struct css_set`、`task_css_set` |
| `kernel/cgroup/cgroup-v1.c` | v1 特定实现 |
| `kernel/cgroup/cgroup-internal.h` | 内部结构 |

---

## 8. 西游记类比

**cgroup v1/v2** 就像"天庭资源管理局的两种组织方式"——

> v1 像各个部委（CPU 部、内存部、IO 部）各自在不同的办公楼，各自管各自的资源。好处是专业分工，坏处是要协调跨部门资源很麻烦（比如 CPU 部和内存部都要配合才能限制一个进程组）。v2 像统一的资源管理局（统一树），所有资源在一个管理体系下，user 部门下的 alice 和 bob 在同一个大楼里分配 CPU、内存、IO 资源。subtree_control 就像资源的"授权额度"——user 把 CPU 和内存的管理权授给子部门，子部门可以在授权范围内自己分配。这就是容器（Docker/Kubernetes）能够精确控制进程组资源的底层机制。

---

## 9. 关联文章

- **cgroup v2**（article 27）：v2 的具体实现细节
- **namespace**（article 134）：cgroup 和 namespace 的配合（容器）