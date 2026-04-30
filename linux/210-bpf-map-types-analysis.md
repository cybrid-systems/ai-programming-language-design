# 210-bpf_map_types — BPF映射类型深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/bpf/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

BPF Maps 是内核-用户空间共享数据的高效数据结构，bpf() syscall 提供创建和操作的接口。

---

## 1. Map 类型

```
主要 BPF Map 类型：

HASH         — 通用哈希表
ARRAY        — 数组
PERCPU_HASH  — per-CPU 哈希
PERCPU_ARRAY — per-CPU 数组
STACK_TRACE  — 栈跟踪栈
SOCKMAP     — socket 映射（eBPF socket 重定向）
SK_STORAGE   — socket 本地存储
INODE_STORAGE — inode 存储
CSSETS       — cgroup sets
RINGBUF      — 高性能环形缓冲区
PROG_ARRAY   — 程序数组（tail call）
HASH_EM      — 哈希表（外部映射）
```

---

## 2. 创建/操作

```c
// 创建 map：
int map_fd = bpf(BPF_MAP_CREATE, &attr);
// attr.map_type = BPF_MAP_TYPE_HASH
// attr.max_entries = 1024

// 查找：
bpf(BPF_MAP_LOOKUP_ELEM, map_fd, &key, &value);

// 更新：
bpf(BPF_MAP_UPDATE_ELEM, map_fd, &key, &value, BPF_ANY);

// 删除：
bpf(BPF_MAP_DELETE_ELEM, map_fd, &key);
```

---

## 3. 西游记类喻

**BPF Maps** 就像"天庭的共享账本"——

> BPF Maps 像天庭和妖怪共享的账本（hash 表），天庭（内核 BPF 程序）和用户空间都可以读写。天庭往账本里记新发现，妖怪可以查账，也可以往账本里写新条目。RINGBUF 像高速直达通道，不用通过中转。

---

## 4. 关联文章

- **eBPF**（article 177）：BPF Maps 是 eBPF 的数据基础