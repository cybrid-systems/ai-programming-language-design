# Linux Kernel cgroup v1 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/cgroup/cgroup.c`）

---

## 0. cgroup v1 vs v2

| 特性 | v1 | v2 |
|------|----|----|
| 层次结构 | 每个控制器独立树 | 单一统一树 |
| 控制器数量 | 多树可重叠 | 所有控制器在同一树 |
| 子树传播 | mount 后固定 | 可动态切换 |
| 性能 | 好 | 更好（锁竞争少）|

---

## 1. cgroup v1 控制器

```
/sys/fs/cgroup/
├── cpu/           ← cpu 控制器
│   ├── docker/    ← container
│   └── system/    ← system slice
├── memory/        ← memory 控制器
│   └── docker/    ← container
└── freezer/      ← freezer 控制器
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `kernel/cgroup/cgroup.c` | cgroup v1 核心 |
| `kernel/cgroup/cgroup-v1.c` | cgroup v1 接口 |
