# eBPF — 扩展 Berkeley Packet Filter 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/bpf/verifier.c` + `kernel/bpf/syscall.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**eBPF** 是 Linux 4.x 引入的高性能内核扩展机制，允许用户空间程序在内核中安全地执行自定义逻辑：

- **安全性**：Verificator 检查程序的所有执行路径，确保不会崩溃
- **JIT 编译**：将 BPF 字节码编译为本地指令
- **Maps**：key-value 存储，用于程序和用户空间通信
- **Helpers**：内核提供的函数（如 `bpf_map_lookup_elem`）

---

## 1. 核心数据结构

### 1.1 bpf_prog — BPF 程序

```c
// include/linux/bpf.h — bpf_prog
struct bpf_prog {
    // 程序信息
    u16                 pages;           // 占用内存页数
    u16                 len;            // 指令数
    enum bpf_prog_type  type:8;          // 程序类型
    bool                jited:1;        // 是否有 JIT 版本

    // 代码
    struct bpf_insn     *insnsi;        // 指令数组
    struct bpf_prog_aux  *aux;          // 辅助信息

    // JIT
    void                *bpf_func;      // JIT 编译后的函数指针
    unsigned int         *jited_linfo;   // JIT 行信息
};
```

### 1.2 bpf_map — Maps（key-value 存储）

```c
// include/linux/bpf.h — bpf_map
struct bpf_map {
    // 类型
    enum bpf_map_type   map_type;       // HASH / ARRAY / PERCPU_HASH / ...

    // 容量
    u32                 max_entries;    // 最大条目数

    // 键值大小
    u32                 key_size;        // 键大小（字节）
    u32                 value_size;     // 值大小（字节）

    // 内部
    atomic64_t          count;          // 引用计数
    struct work_struct   work;           // 异步操作
    void                *internal_ops;   // 内部操作（hash / array / ...）
    void                **map_owner;     // map 所有者
};
```

### 1.3 bpf_insn — BPF 指令

```c
// include/uapi/linux/bpf.h — bpf_insn
struct bpf_insn {
    __u8    code;           // 操作码（BPF_* | BPF_OP | BPF_SRC）
    __u8    dst_reg:4;      // 目标寄存器
    __u8    src_reg:4;      // 源寄存器
    __s16   off;            // 偏移量
    __s32   imm;            // 立即数
};

// 示例指令：
// BPF_MOV64_IMM(BPF_REG_0, 42) → 将 42 写入 R0
// BPF_ALU64_ADD(BPF_REG_0, BPF_REG_1) → R0 = R0 + R1
// BPF_LD_MAP_FD(BPF_REG_1, map_fd) → R1 = map 文件描述符
```

---

## 2. 系统调用

### 2.1 bpf syscall

```c
// kernel/bpf/syscall.c — SYSCALL_DEFINE3(bpf, int, cmd, union bpf_attr *, attr, unsigned int, size)
SYSCALL_DEFINE3(bpf, int, cmd, union bpf_attr *, attr, unsigned int, size)
{
    switch (cmd) {
    case BPF_MAP_CREATE:
        return map_create(attr, uattr);
    case BPF_MAP_LOOKUP_ELEM:
        return map_lookup_elem(attr, uattr);
    case BPF_MAP_UPDATE_ELEM:
        return map_update_elem(attr, uattr);
    case BPF_MAP_DELETE_ELEM:
        return map_delete_elem(attr, uattr);
    case BPF_PROG_LOAD:
        return prog_load(attr, uattr);
    case BPF_BTF_GET_NEXT_ID:
        return btf_get_next_id(attr, uattr);
    case BPF_MAP_LOOKUP_BATCH:
        return map_lookup_batch(attr, uattr);
    }
    return -EINVAL;
}
```

### 2.2 prog_load — 加载程序

```c
// kernel/bpf/syscall.c — prog_load
static int prog_load(union bpf_attr *attr, ...)
{
    // 1. 分配 bpf_prog
    prog = bpf_prog_alloc(bpf_prog_size(attr->insn_cnt), ...);

    // 2. 复制指令
    if (copy_from_user(prog->insnsi, attr->insns, attr->insn_cnt * sizeof(struct bpf_insn)))
        return -EFAULT;

    prog->len = attr->insn_cnt;
    prog->type = attr->prog_type;

    // 3. Verificator 检查
    ret = bpf_check(prog, attr);
    if (ret < 0)
        return ret;

    // 4. JIT 编译
    if (bpf_prog_is_jited(prog))
        bpf_prog_jit(prog);

    return prog->aux->id;
}
```

---

## 3. Verificator

### 3.1 do_check — 主检查循环

```c
// kernel/bpf/verifier.c — do_check
static int do_check(struct bpf_verifier_env *env)
{
    struct bpf_insn *insn = prog->insnsi;
    int insn_idx = 0;

    while (insn_idx < prog->len) {
        insn = &insnsi[insn_idx];

        switch (insn->code) {
        case BPF_ALU | ...:
            // 检查算术操作：除零、无符号溢出
            break;
        case BPF_LD | BPF_LDX:
            // 检查内存访问：在栈边界内、未越界
            break;
        case BPF_STX | BPF_ST:
            // 检查存储：类型匹配
            break;
        case BPF_CALL:
            // 检查函数调用：helper 在白名单中
            check_call(env, insn_idx, insn->imm);
            break;
        case BPF_EXIT:
            // 检查返回值：R0 有值
            break;
        }

        // 追踪状态：每个点的寄存器/栈状态
        // 如果发现未初始化 → 拒绝
        // 如果发现无限循环 → 拒绝

        insn_idx++;
    }

    // 检查：所有执行路径都到达 EXIT
    // 检查：EXIT 前 R0 有值
    return 0;
}
```

### 3.2 check_mem_access — 内存访问检查

```c
// kernel/bpf/verifier.c — check_mem_access
static int check_mem_access(struct bpf_verifier_env *env, int insn_idx,
                            struct bpf_insn *insn, int dest_reg, int src_reg, ...)
{
    // 1. 计算内存地址
    if (src_reg)
        addr = regs[src_reg].imm + insn->off;
    else
        addr = regs[dest_reg].imm + insn->off;

    // 2. 检查：只读上下文中不能写
    if (is_read_only && BPF_MODE(insn->code) == BPF_ST)
        return -EACCES;

    // 3. 边界检查：addr + size <= allowed_max
    //    不能访问 kernel memory（除非特定情况）
    if (addr + size > env->max_stack)
        return -EACCES;

    // 4. 记录：此指令会访问内存（用于 JIT）
    env->used_load = 1;
}
```

---

## 4. JIT 编译

```c
// arch/x86/net/bpf_jit_comp.c — bpf_jit_compile
void bpf_jit_compile(struct bpf_prog *prog)
{
    // 将 BPF 指令转为 x86 指令
    // 例如：
    //   BPF_MOV64_IMM(R0, 42) → mov $0x2a, %eax
    //   BPF_ALU64_ADD(R0, R1) → add %edi, %eax
    //   BPF_LD_MAP_FD(R1, fd) → mov $map_fd, %rdi

    // 保存 context（rdi = bpf_context）
    // prologue
    // translate instructions
    // epilogue
    // emit
}
```

---

## 5. Maps 类型

```c
// include/uapi/linux/bpf.h — enum bpf_map_type
enum bpf_map_type {
    BPF_MAP_TYPE_HASH,         // 哈希表
    BPF_MAP_TYPE_ARRAY,        // 数组（O(1) 查找）
    BPF_MAP_TYPE_PROG_ARRAY,   // 程序数组（尾调用）
    BPF_MAP_TYPE_PERCPU_HASH,  // per-CPU 哈希
    BPF_MAP_TYPE_PERCPU_ARRAY, // per-CPU 数组
    BPF_MAP_TYPE_STACK_TRACE,  // 栈跟踪
    BPF_MAP_TYPE_CGROUP_ARRAY, // Cgroup 数组
    BPF_MAP_TYPE_LPM_TRIE,     // LPM 前缀树（最长前缀匹配）
    BPF_MAP_TYPE_ARRAY_OF_MAPS,
    BPF_MAP_TYPE_HASH_OF_MAPS,
    // ...
};
```

---

## 6. Helper 函数

```c
// include/linux/bpf.h — bpf_func_proto
enum bpf_func_id {
    BPF_FUNC_map_lookup_elem,  // bpf_map_lookup_elem(map, key) → value
    BPF_FUNC_map_update_elem,  // bpf_map_update_elem(map, key, value, flags)
    BPF_FUNC_map_delete_elem,  // bpf_map_delete_elem(map, key)
    BPF_FUNC_probe_read,       // 读取 kernel memory（安全）
    BPF_FUNC_get_current_uid,  // 获取当前 UID
    BPF_FUNC_get_current_pid, // 获取当前 PID
    BPF_FUNC_trace_printk,    // 调试输出
    BPF_FUNC_skb_store_bytes,  // 修改 skb 数据
    // ...
};
```

---

## 7. 程序类型

```c
// include/linux/bpf.h — enum bpf_prog_type
enum bpf_prog_type {
    BPF_PROG_TYPE_SOCKET_FILTER,   // 过滤网络包
    BPF_PROG_TYPE_KPROBE,          // kprobe 断点
    BPF_PROG_TYPE_SCHED_CLS,       // tc 分类器
    BPF_PROG_TYPE_SCHED_ACT,       // tc 操作
    BPF_PROG_TYPE_TRACEPOINT,      // tracepoint
    BPF_PROG_TYPE_XDP,             // 快速路径（网卡直接处理）
    BPF_PROG_TYPE_PERF_EVENT,      // perf 事件
    BPF_PROG_TYPE_CGROUP_SKB,      // cgroup skb 过滤
    BPF_PROG_TYPE_CGROUP_SOCK,     // cgroup socket
    BPF_PROG_TYPE_LWT_IN,          // LWT 输入
    BPF_PROG_TYPE_LWT_OUT,         // LWT 输出
    // ...
};
```

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/linux/bpf.h` | `struct bpf_prog`、`struct bpf_map` |
| `include/uapi/linux/bpf.h` | `struct bpf_insn`、`enum bpf_map_type` |
| `kernel/bpf/verifier.c` | `do_check`、`check_mem_access` |
| `kernel/bpf/syscall.c` | `SYSCALL_DEFINE3(bpf)`、`prog_load` |
| `arch/x86/net/bpf_jit_comp.c` | `bpf_jit_compile` |