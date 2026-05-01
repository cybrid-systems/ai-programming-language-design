# eBPF 虚拟机与程序加载机制深度分析

> 基于 Linux 7.0-rc1 内核源码
> 分析文件：kernel/bpf/syscall.c、verifier.c、core.c、arraymap.c、hashtab.c

---

## 1. 概述：什么是 eBPF？

eBPF（extended Berkeley Packet Filter）是 Linux 内核中的一个轻量级虚拟机，设计初衷是允许用户态程序在安全沙箱中运行并拦截/处理内核事件。其演进路径：

```
Classic BPF (cBPF)          eBPF
─────────────────          ──────────────────────
1992 年 BSDfilter      →   2014 年 Linux 3.18+
仅网络过滤器             内核函数调用、Map、尾调用
无 verifier            sandbox verifier
无 JIT（少数架构）       所有主流架构 JIT
```

eBPF 程序被编译为字节码，由内核 verifier 验证安全性后，由 JIT 编译器转换为机器码执行。

---

## 2. 程序加载完整路径

### 2.1 用户态到内核的入口：sys_bpf()

```
用户空间                          内核
──────────────────────────────────────────────────────────────
bpf(BPF_PROG_LOAD, attr, size)
      │
      │  copy_from_user(attr)
      ▼
SYSCALL_DEFINE3(bpf)
    │
    ├── cmd == BPF_PROG_LOAD?
    │   └── goto bpf_prog_load()
    │
    ├── cmd == BPF_MAP_CREATE?
    │   └── goto bpf_map_create()
    │
    ├── cmd == BPF_MAP_LOOKUP_ELEM?
    │   └── ...
    ▼
```

`SYSCALL_DEFINE3(bpf)` 是所有 BPF 命令的统一入口（kernel/bpf/syscall.c:2586）：

```c
SYSCALL_DEFINE3(bpf, int, cmd, union bpf_attr __user *, uattr, unsigned int, size)
{
    // 权限检查
    // 根据 cmd 分发到具体处理函数
    switch (cmd) {
    case BPF_PROG_LOAD:
        return bpf_prog_load(&attr, uattr, size);
    case BPF_MAP_CREATE:
        return bpf_map_create(&attr, uattr, size);
    // ... 其他 cmd
    }
}
```

### 2.2 bpf_prog_load() 详解（syscall.c:2864）

**Step 1: 属性合法性检查**

```c
if (CHECK_ATTR(BPF_PROG_LOAD))          // 检查 usersize <= sizeof(attr)
    return -EINVAL;

// 允许的 flags 检查
if (attr->prog_flags & ~(BPF_F_STRICT_ALIGNMENT |
                          BPF_F_ANY_ALIGNMENT |
                          BPF_F_TEST_STATE_FREQ |
                          BPF_F_SLEEPABLE |
                          BPF_F_TEST_RND_HI32 |
                          BPF_F_XDP_HAS_FRAGS |
                          BPF_F_XDP_DEV_BOUND_ONLY |
                          BPF_F_TEST_REG_INVARIANTS |
                          BPF_F_TOKEN_FD))
    return -EINVAL;
```

**Step 2: Token 处理（BPF_F_TOKEN_FD）**

若指定了 `BPF_F_TOKEN_FD`，通过 `bpf_token_get_from_fd()` 获取 token，token 携带细粒度权限。

```c
if (attr->prog_flags & BPF_F_TOKEN_FD) {
    token = bpf_token_get_from_fd(attr->prog_token_fd);
    if (!bpf_token_allow_cmd(token, BPF_PROG_LOAD) ||
        !bpf_token_allow_prog_type(token, attr->prog_type,
                                   attr->expected_attach_type))
        token = NULL;  // fallback 到全局 capabilities 检查
}
```

**Step 3: 指令数量限制**

```c
if (attr->insn_cnt == 0 ||
    attr->insn_cnt > (bpf_cap ? BPF_COMPLEXITY_LIMIT_INSNS : BPF_MAXINSNS))
    return -E2BIG;
```

有 CAP_BPF 时最多 100 万条指令（BPF_COMPLEXITY_LIMIT_INSNS），普通用户最多 BPF_MAXINSNS (= 4096)。

**Step 4: 类型检查 + 权限检查**

```c
if (type != BPF_PROG_TYPE_SOCKET_FILTER &&
    type != BPF_PROG_TYPE_CGROUP_SKB &&
    !bpf_cap)               // 非 SOCKET_FILTER/CGROUP_SKB 必须有 CAP_BPF
    goto put_token;

if (is_net_admin_prog_type(type) && !bpf_token_capable(token, CAP_NET_ADMIN))
    goto put_token;
if (is_perfmon_prog_type(type) && !bpf_token_capable(token, CAP_PERFMON))
    goto put_token;
```

**Step 5: 解析 attach target**

```c
if (attr->attach_prog_fd) {
    // attach 到另一个 BPF 程序 或 vmlinux BTF
    dst_prog = bpf_prog_get(attr->attach_prog_fd);  // 获取目标 prog
    if (IS_ERR(dst_prog))
        attach_btf = btf_get_by_fd(attr->attach_btf_obj_fd);  // 或获取 BTF
} else if (attr->attach_btf_id) {
    attach_btf = bpf_get_btf_vmlinux();  // 回退到内核 BTF
}
```

**Step 6: prog 类型确定**

```c
bpf_prog_load_check_attach(type, expected_attach_type, attach_btf, attach_btf_id, dst_prog);
find_prog_type(type, prog);  // 在 prog_types 链表中匹配，填充 prog->ops
```

**Step 7: 程序体复制**

```c
prog = bpf_prog_alloc(bpf_prog_size(attr->insn_cnt), GFP_USER);
copy_from_bpfptr(prog->insns, make_bpfptr(attr->insns, uattr.is_kernel),
                 bpf_prog_insn_size(prog));

strncpy_from_bpfptr(license, make_bpfptr(attr->license, ...), sizeof(license)-1);
prog->gpl_compatible = license_is_gpl_compatible(license);
```

**Step 8: 签名验证（如需要）**

```c
if (attr->signature) {
    err = bpf_prog_verify_signature(prog, attr, uattr.is_kernel);
    if (err) goto free_prog;
}
```

**Step 9: security_bpf_prog_load()（SELinux/AppArmor hook）**

```c
err = security_bpf_prog_load(prog, attr, token, uattr.is_kernel);
```

**Step 10: bpf_check() — 核心 verifier 调用**

```c
err = bpf_check(&prog, attr, uattr, uattr_size);  // verifier 是最大的一道关
```

**Step 11: JIT 编译 + fd 创建**

```c
bpf_prog_select_interpreter(fp);      // 选择 interpreter 或 JIT
bpf_jit_compile(prog);               // JIT 编译（如启用）

bpf_prog_alloc_id(prog);             // 分配全局唯一 ID
bpf_prog_kallsyms_add(prog);         // 添加到 kallsyms（用于 introspection）
perf_event_bpf_event(prog, ...);     // 通知 perf 事件
bpf_audit_prog(prog, ...);
bpf_prog_new_fd(prog);               // 分配 fd，返回给用户态
```

### 2.3 完整加载流程 ASCII 图

```
用户态 bpf(BPF_PROG_LOAD, ...)
          │
          ▼
┌─────────────────────────────────────────────────────────┐
│  SYSCALL_DEFINE3(bpf)                                    │
│    └── bpf_prog_load()                                   │
│         │                                                │
│         ├─ [1] attr合法性检查 (CHECK_ATTR)               │
│         ├─ [2] token处理 (BPF_F_TOKEN_FD)                │
│         ├─ [3] insn_cnt 限制检查 (0, MAXINSNS)           │
│         ├─ [4] 类型+权限检查 (CAP_BPF/CAP_NET_ADMIN)     │
│         ├─ [5] attach_target 解析 (prog fd 或 BTF)       │
│         ├─ [6] find_prog_type() → 填充 prog->ops        │
│         │                                                │
│         ├─ [7] bpf_prog_alloc() + copy_from_user(insns)  │
│         ├─ [8] license 复制 + GPL 兼容性检查              │
│         ├─ [9] signature 验证 (optional)                  │
│         ├─ [10] security_bpf_prog_load() (LSM hook)      │
│         │                                                │
│         ▼                                                │
│  ┌─────────────────────────────────────────┐              │
│  │  bpf_check(&prog, ...)                 │ ← VERIFIER   │
│  │    ├── bpf_check_cfg()                 │   字节码验证 │
│  │    ├── add_subprog_and_kfunc()         │              │
│  │    ├── do_check_main()                 │ 状态机模拟  │
│  │    └── do_check_subprogs()             │ 执行路径    │
│  └─────────────────────────────────────────┘              │
│         │                                                │
│         ├─ [11] bpf_prog_mark_insn_arrays_ready()       │
│         ├─ [12] bpf_prog_alloc_id() → 全局唯一 ID        │
│         ├─ [13] bpf_prog_kallsyms_add()                 │
│         ├─ [14] perf_event_bpf_event()                  │
│         └─ [15] bpf_prog_new_fd() → 返回用户态 fd        │
│                                                         │
└─────────────────────────────────────────────────────────┘
          │
          ▼
用户态收到 fd = open("/sys/fs/bpf/...", O_RDWR)
          程序已在内核中驻留，可通过 fd 操作
```

---

## 3. Verifier 逻辑深度分析

### 3.1 bpf_check() 概览（verifier.c:19900）

```c
int bpf_check(struct bpf_prog **prog, union bpf_attr *attr,
              bpfptr_t uattr, __u32 uattr_size)
{
    env = kvzalloc_obj(struct bpf_verifier_env, GFP_KERNEL_ACCOUNT);
    env->insn_aux_data = vzalloc(array_size(sizeof(struct bpf_insn_aux_data), len));

    env->prog = *prog;
    env->ops = bpf_verifier_ops[env->prog->type];  // 类型特定的 verifier ops

    env->allow_ptr_leaks = bpf_allow_ptr_leaks(env->prog->aux->token);
    env->strict_alignment = !(attr->prog_flags & BPF_F_ANY_ALIGNMENT);

    // --- 核心验证流程 ---
    mark_verifier_state_clean(env);

    ret = bpf_check_cfg(env);          // CFG 验证（循环检测）
    ret = add_subprog_and_kfunc(env);   // 解析子程序和内联函数
    ret = check_subprogs(env);          // 子程序完整性
    ret = bpf_check_btf_info(env, ...); // BTF info 验证
    ret = check_and_resolve_insns(env); // 指令解析/重定位
    ret = do_check_main(env);           // 主验证：状态机模拟 ← 最关键
    ret = do_check_subprogs(env);       // 子程序验证

    // JIT 后处理
    if (prog->jited) {
        bpf_jit_prog_release_other(prog, orig_prog);
    }
}
```

### 3.2 Verifier 的核心职责

Verifier 防止恶意/错误的 BPF 程序导致：
1. **内核崩溃** — 越界内存访问、空指针解引用
2. **死循环** — 无界循环、无法收敛的跳转
3. **特权提升** — 未授权访问敏感内核结构
4. **信息泄露** — 通过寄存器/栈泄漏内核地址

### 3.3 Verifier 状态机

```
寄存器类型 (enum bpf_reg_type):
  NOT_INIT  ← 未初始化寄存器，不可读
  SCALAR_VALUE ← 标量值（整数）
  PTR_TO_CTX ← 指向 ctx（如 sk_buff）的指针
  PTR_TO_STACK ← 指向栈帧的指针
  PTR_TO_MAP_VALUE ← 指向 map 元素的指针
  PTR_TO_SOCKET ← socket 指针
  CONST_PTR_TO_MAP ← 指向 map 的常量指针
  PTR_TO_BTF_ID ← 指向 BTF 描述的内核对象的指针
  PTR_TO_MEM ← 通用可访问内存区域
  PTR_TO_FUNC ← 函数指针（用于 bpf-to-bpf 调用）
```

**每条指令的验证状态**：

```c
struct bpf_verifier_state {
    struct bpf_reg_state regs[MAX_BPF_REG];  // 10 个寄存器状态
    u64 stack[MAX_BPF_STACK / 8];            // 512/8=64 slot 栈帧
    u32 insn_idx;                             // 当前指令指针
    struct bpf_verifier_state *parent;        // 前驱状态（用于回溯）
};
```

### 3.4 状态机执行示例：一条指针解引用

假设程序执行：
```asm
R1 = ctx（已知类型为 PTR_TO_CTX）
R2 = R1 + 8        ; 从 ctx 偏移 8 字节
WIDTH = 4          ; 读取 4 字节
OFF = 0            ; 无额外偏移
```

Verifier 处理：

```
insn_idx=5: BPF_LDX | BPF_MEM | BPF_B
  ├─ 检查 R2 类型 == PTR_TO_CTX
  ├─ 检查 R2.offset + 4 <= ctx_size   ← 边界检查
  ├─ 检查 memory 类型允许读取
  └─ R0 = SCALAR_VALUE (加载的标量)

insn_idx=10: BPF_STX | BPF_MEM | BPF_B  (R0 → *(R2+0))
  ├─ 检查 R2 类型 == PTR_TO_CTX
  ├─ 检查 R0 类型 == SCALAR_VALUE     ← 必须已初始化
  └─ *(R2+0) = R0
```

### 3.5 什么程序会被拒绝？

**拒绝案例 1: 未初始化寄存器**

```c
// 用户代码（会被拒绝）
r0 = *(u32 *)(r1 + 100)   // r1 未检查是否为 NULL 或类型错误
```

**拒绝案例 2: 越界栈访问**

```c
// 512 字节栈，最大偏移 504（8字节访问）
*(r10 - 600) = r0    // r10 是栈帧指针，r10-600 超界
→ REJECT:赔
```

**拒绝案例 3: 无界循环**

```c
// verifier 检测到循环无法达到 EXIT
backward_jump:
  goto backward_jump   // 无法确定循环出口
→ REJECT: loop detected
```

**拒绝案例 4: 不允许的 helper 调用**

```c
// tracing prog 试图调用 bpf_map_lookup_elem（需要 CAP_MAP_READ）
// 但 prog 的 allowed_helpers 限制中不含此函数
→ REJECT: invalid function call
```

**拒绝案例 5: 指针泄漏**

```c
r0 = r1              // 将 ctx 指针直接返回给用户
// verifier 发现 R0 是 PTR_TO_CTX 类型未转 scalar
→ REJECT: ptr type leak
```

### 3.6 Verifier 状态机 ASCII 图

```
              ┌──────────────┐
              │  START STATE │
              │ insn_idx=0   │
              │ R0=NONE      │
              │ R1=PTR_TO_CTX│
              └──────┬───────┘
                     ▼
     ┌────────────────────────────────────┐
     │   do_check_main(env)               │
     │   while (env->insn_idx < prog->len)│
     │                                     │
     │   pop state from stack              │
     │       │                              │
     │       ▼                              │
     │   ┌────────────────────────┐         │
     │   │ inspect_insn(state)   │         │
     │   │  - reg_type 检查       │         │
     │   │  - bounds 检查         │         │
     │   │  - stack 类型检查       │         │
     │   └──────────┬─────────────┘         │
     │              │                        │
     │    branch?   │                        │
     │   ┌──────────┴───────────┐            │
     │   ▼                      ▼            │
     │ [T] 新状态           [F] 新状态       │
     │ (reg/imm 比较结果)        │            │
     │   │                      │            │
     │   ▼                      ▼            │
     │ ┌──────────┐  ┌───────────────┐       │
     │ │ push state│  │ push state    │       │
     │ │ to stack │  │ to stack     │       │
     │ └────┬─────┘  └───────┬───────┘       │
     └──────┼────────────────┼────────────────┘
            │                │
            └───────┬────────┘
                    ▼
        ┌─────────────────────────┐
        │ state merging/pruning   │ ← 相同状态合并，加速
        └─────────────────────────┘
                    │
                    ▼
         ┌─────────────────────┐
         │ reach EXIT insn?    │ ← 验证至少有一条路径到达 BPF_EXIT
         │  yes → ACCEPT       │
         │  no  → REJECT       │
         └─────────────────────┘
```

### 3.7 复杂度限制

Verifier 对状态数量有严格限制，防止验证本身超时：

```c
env->max_states_per_insn = 1024;   // 每条指令最多保留 1024 个状态
env->total_states++;              // 总状态数超限则拒绝
if (env->total_states > 16 * 1024 * 1024)
    return -EMFILE;  // 超过 16M 状态，拒绝
```

---

## 4. JIT 编译

### 4.1 编译流程

```c
// core.c:2535
static struct bpf_prog *bpf_prog_jit_compile(struct bpf_verifier_env *env,
                                             struct bpf_prog *prog)
{
#ifdef CONFIG_BPF_JIT
    if (!bpf_prog_need_blind(prog))
        return bpf_int_jit_compile(env, prog);  // 标准 JIT

    // blinding 模式：混淆常量，防止 exploit
    prog = bpf_jit_blind_constants(env, prog);
    prog = bpf_int_jit_compile(env, prog);       // JIT 后 blinded 版本
    if (prog->jited)
        bpf_jit_prog_release_other(prog, orig_prog);
#endif
}
```

### 4.2 JIT 与 interpreter 的关系

```
用户 bpf(BPF_PROG_LOAD)
         │
         ▼
┌─────────────────────┐
│ bpf_check()         │ ← 总是执行，不依赖 JIT 开关
└──────────┬──────────┘
           ▼
┌──────────────────────────────────────────┐
│ bpf_prog_select_interpreter(fp)           │
│                                          │
│ if (CONFIG_BPF_JIT_ALWAYS_ON) {          │
│     fp->bpf_func = __bpf_prog_ret0_warn  │ ← JIT always 模式：不需要 interpreter
│ } else {                                 │
│     stack_depth → select interpreter     │ ← 非 JIT always：选择合适大小的 interpreter
│ }                                        │
└──────────────────┬───────────────────────┘
                   ▼
┌──────────────────────────────────────────┐
│ bpf_jit_compile(prog)                    │ ← JIT 编译（如果有 JIT）
│   └── arch-specific: x86_bpf_jit_compile│
│       or arm64_bpf_jit_compile           │
│       or s390_bpf_jit_compile           │
│       ...                                │
└──────────────────┬───────────────────────┘
                   ▼
            prog->jited = 1
            prog->jited_len = 机器码字节数
            prog->bpf_func 指向 JIT 代码
```

### 4.3 支持 JIT 的架构

| 架构 | JIT 文件 | 说明 |
|------|----------|------|
| x86_64 | arch/x86/net/bpf_jit_comp.c | 完整 eBPF JIT |
| arm64 | arch/arm64/net/bpf_jit_comp.c | 完整 eBPF JIT |
| s390 | arch/s390/net/bpf_jit_comp.c | 完整 eBPF JIT |
| powerpc | arch/powerpc/net/bpf_jit_comp64.c | 64-bit JIT |
| riscv | arch/riscv/net/bpf_jit_comp64.c | 64-bit JIT |
| mips | arch/mips/net/bpf_jit_comp64.c | 64-bit JIT |
| loongarch | arch/loongarch/net/bpf_jit.c | eBPF JIT |
| sparc | arch/sparc/net/bpf_jit_comp_64.c | 64-bit JIT |
| parisc | arch/parisc/net/bpf_jit_comp64.c | 64-bit JIT |

无 JIT 的架构使用 interpreter（`___bpf_prog_run()`）。

### 4.4 JIT 的角色

```
Interpreter (JIT off):
  ┌────────────────────────┐
  │ for (insn = prog->insns) │
  │     switch(opcode)      │
  │         execute         │  ← 每次运行都要解释执行
  └────────────────────────┘

JIT (JIT on):
  ┌────────────────────────┐
  │ prog->bpf_func ==       │
  │   x86_code_sequence    │  ← 直接执行机器码，无解释开销
  └────────────────────────┘
```

### 4.5 bpf_int_jit_compile() 的步骤

```c
// arch/x86/net/bpf_jit_comp.c
struct bpf_prog *bpf_int_jit_compile(struct bpf_prog *prog)
{
    // 1. 计算 JIT 代码大小（用于分配内存）
    int proglen = bpf_jit_prologue_len(prog);
    for (each insn)
        proglen += bpf_jit_insn_size(insn);

    // 2. 分配可执行内存（使用 bpf_prog_pack）
    exec_mem = bpf_prog_pack_alloc(prog->size, bpf_fill_ill_insns);

    // 3. 逐条翻译 eBPF 字节码 → 机器指令
    for (each bpf_insn) {
        emit_prologue();      // push rbp; mov rbp, rsp
        emit_body(insn);      // 翻译每条指令
        emit_epilogue();      // pop rbp; ret
    }

    // 4. 绑定辅助函数调用（BPF_FUNC_* → 真实内核函数地址）
    for (each BPF_CALL insn)
        fill_call_handler(prog, imm);

    prog->bpf_func = (void *)exec_mem;
    prog->jited = 1;
    prog->jited_len = proglen;
}
```

---

## 5. Map 数据结构

### 5.1 bpf_map 核心结构（bpf.h:296）

```c
struct bpf_map {
    u8                  sha[SHA256_DIGEST_SIZE];  // 地图唯一标识
    const struct bpf_map_ops *ops;                // 类型特定操作集
    enum bpf_map_type   map_type;                 // HASH / ARRAY / ...
    u32                 key_size;                 // 键字节数
    u32                 value_size;               // 值字节数
    u32                 max_entries;              // 最大元素数
    u32                 map_flags;                // 标志（原子性等）
    u32                 id;                       // 全局唯一 ID
    struct btf *        btf;                      // BTF 类型信息
    char                name[BPF_OBJ_NAME_LEN];
    atomic64_t          refcnt;                   // 引用计数
    atomic64_t          usercnt;                 // 用户态引用计数
    ...
};
```

### 5.2 Map 操作 ops

```c
struct bpf_map_ops {
    int    (*map_alloc_check)(union bpf_attr *attr);
    int    (*map_alloc)(union bpf_attr *attr);
    void   (*map_release)(struct bpf_map *map, struct file *map_file);
    int    (*map_lookup_elem)(struct bpf_map *map, void *key, void *value);
    int    (*map_update_elem)(struct bpf_map *map, void *key, void *value, u64 flags);
    int    (*map_delete_elem)(struct bpf_map *map, void *key);
    int    (*map_get_next_key)(struct bpf_map *map, void *key, void *next_key);
    ...
};
```

### 5.3 BPF_MAP_TYPE_ARRAY

实现文件：`kernel/bpf/arraymap.c`

```
struct bpf_array {
    struct bpf_map map;
    u32 elem_size;         // 单元素字节数
    u32 max_entries;       // 最大条目数
    char value[];          // 实际数据区域
};

查找 (map_lookup_elem):
  index = *(u32 *)key
  if (index >= max_entries) return -ENOENT
  value_ptr = &array->value[index * elem_size]
  copy_to_user(value, value_ptr, elem_size)

更新 (map_update_elem):
  index = *(u32 *)key
  value = src
  array->value[index * elem_size] = value
```

**Per-CPU Array** (`BPF_MAP_TYPE_PERCPU_ARRAY`)：每个 CPU 独立数据，避免竞争。

```c
struct bpf_array {
    struct bpf_map map;
    u32 elem_size;
    u32 max_entries;
    char __percpu *value[];  // per-CPU 独立副本
};

// lookup 时：copy_from_cpu(local_cpu_value)
```

### 5.4 BPF_MAP_TYPE_HASH

实现文件：`kernel/bpf/hashtab.c`（通过 `kernel/bpf/hashtab.c` 中的 `hlist` 实现）

```
Bucket 数组 (hashmap with chaining):
  ┌──────────────────────────────────────┐
  │ bpf_htab (struct)                   │
  │   num_bucket 个 bucket               │
  │   每个 bucket → hlist_head          │
  │       → hlist_node (hash entry)     │
  │           → key + value             │
  └──────────────────────────────────────┘

查找：
  hash = jhash(key, key_size) % num_bucket
  for each hlist_node in bucket[hash]:
      if (key_match(node, key)):
          return node->value

更新：
  if (key exists): update value
  else: insert new node
  if (count > max_entries): evict (LRU 或随机)

删除：
  hash = jhash(key, ...) % num_bucket
  remove from hlist
```

### 5.5 原子性保证

```c
// arraymap.c
int array_map_update_elem(struct bpf_map *map, void *key, void *value, u64 flags)
{
    // 数组下标操作本身是原子的（对固定偏移的写）
    // 内核使用 spinlock 保护全局结构
    unsigned long flags;
    spin_lock_irqsave(&array->lock, flags);
    array->values[index] = *value;
    spin_unlock_irqrestore(&array->lock, flags);
}

// hashtab.c 使用 per-bucket spinlock
// 允许高度并发的读（RCU） + 串行化的写
```

### 5.6 Map 查找/更新调用链

```
BPF 程序中:
  r0 = bpf_map_lookup_elem(map_fd, &key)
         │
         ▼
    ──────────────────────────────────────────────
    运行时: 解释器或 JIT 调用:
      prog->bpf_func(ctx, prog->insnsi)
         │
         ▼
    BPF_CALL 指令
      → helpers.c 中的 bpf_map_lookup_elem()
         │
         ▼
    map->ops->map_lookup_elem(map, key, &value)
         │
         ├── ARRAY:  O(1) 直接索引
         ├── HASH:   O(n) hash 查找
         └── ...
```

---

## 6. BPF Prog Types 与 Attach 机制

### 6.1 Prog Type 注册

```c
// kernel/bpf/syscall.c
static const struct bpf_prog_ops *prog_types[] = {
    [BPF_PROG_TYPE_SOCKET_FILTER] = &socket_filter_prog_ops,
    [BPF_PROG_TYPE_SCHED_CLS]    = &sched_cls_prog_ops,
    [BPF_PROG_TYPE_XDP]           = &xdp_prog_ops,
    [BPF_PROG_TYPE_KPROBE]       = &kprobe_prog_ops,
    [BPF_PROG_TYPE_TRACEPOINT]    = &tracepoint_prog_ops,
    [BPF_PROG_TYPE_PERF_EVENT]   = &perf_event_prog_ops,
    ...
};

static int find_prog_type(enum bpf_prog_type type, struct bpf_prog *prog)
{
    if (type >= ARRAY_SIZE(prog_types) || !prog_types[type])
        return -EINVAL;
    prog->ops = prog_types[type];
    return 0;
}
```

### 6.2 各类 Prog 的 Attach 点

| Prog Type | Attach 方式 | 调用位置 |
|-----------|-------------|---------|
| `SOCKET_FILTER` | `setsockopt(fd, SOL_SOCKET, SO_ATTACH_BPF, &prog_fd)` | `sk->sk_prot->setsockopt` → `sock_bindtoindex()` |
| `SCHED_CLS` | `tc qdisc add dev eth0 cls_act bpf ...` 或 `tc filter add dev eth0 ingress bpf ...` | `sch_handle_egress()` / `sch_handle_ingress()` |
| `XDP` | `ip link set dev eth0 xdp obj bpf_prog.o section xdp` | `netif_receive_skb()` 早期，在分配 skb 之前 |
| `KPROBE` | `echo 'p:my_kprobe do_sys_open' > /sys/kernel/debug/tracing/kprobe_events` | `kprobe_handler()` → `optimize_kprobe()` |
| `TRACEPOINT` | `perf probe event` + `perf stat -e trace:sys_enter_openat` | `tracepoint_preamble()` |
| `CGROUP_SKB` | `bpf_link_create(cgroup_fd, ..., BPF_CGROUP_INET_INGRESS, prog_fd)` | `cgroup_bpf_inherit()` 在数据包入口调用 |
| `LSM` | `bpf_attach_bpf(BPF_LSM_CGROUP_INET4_BIND, ...)` | 安全模块 hook |

### 6.3 XDP 程序执行路径

```
网卡收到数据包
     │
     ▼
┌──────────────────────────────────────────────────┐
│ netif_receive_skb()                             │
│     │                                            │
│     ├── skb = alloc_skb()                       │
│     │                                            │
│     ├── rcu_read_lock()                         │
│     │                                            │
│     └── if (xdp_prog) {                         │
│            XDP prog 执行（可能 drop/replace）   │
│            return XDP_PASS / XDP_DROP / ...     │
│         }                                       │
│                                                    │
│  // XDP 在 skb 分配之前运行，性能极高            │
└──────────────────────────────────────────────────┘
```

### 6.4 Sched_cls 程序执行路径

```
TC (Traffic Control) 入口
     │
     ▼
┌──────────────────────────────────────┐
│ sch_handle_ingress() / sch_handle_egress()
│     │
│     ├── tcf_result 结构
│     │
│     ├── tc_classify() 遍历所有过滤器
│     │     │
│     │     └── BPF_PROG_TYPE_SCHED_CLS
│     │           │
│     │           └── prog->bpf_func(skb)
│     │               │
│     │               return TC_ACT_OK / SHOT / ...
│     │
└──────────────────────────────────────┘
```

---

## 7. Tail Call vs BPF-to-BPF Call

### 7.1 概念对比

```
BPF-to-BPF Call（函数调用）:
  在编译时确定目标子程序（通过 BTF）
  共享同一个栈帧（调用者/被调用者同一上下文）
  最大嵌套 BPF_MAX_SUBPROGS (= 256)
  编译时内联优化（JIT 时合并）

Tail Call（尾调用）:
  在运行时通过 BPF_MAP_TYPE_PROG_ARRAY 选择目标
  替换当前程序（goto 到另一个 prog，不返回）
  独立栈帧（旧 prog 被替换）
  最大深度 33（MAX_TAIL_CALL_CALLS）
  用于插件链、分层处理
```

### 7.2 BPF-to-BPF Call 详解

```asm
; 主程序
call subprog_1        ; R0 = subprog_1(R1, R2)
add R0, 1
exit

; subprog_1 (编译时由 verifier 分析，共享栈)
subprog_1:
  mov R0, R1
  add R0, R2
  exit
```

JIT 后，BPF_CALL 变成 `call target_subprog_offset`（同一代码区域内的相对调用）。

```c
// verifier.c:do_check_main() 处理 BPF_CALL
// 不跳转到新 prog，而是模拟执行子程序入口
// 子程序有自己的 insn_idx 范围，但共享寄存器状态
```

### 7.3 Tail Call 详解

```c
// Tail call 需要一个 PROG_ARRAY map
struct bpf_map *prog_array = bpf_map_lookup_elem(map_fd, &index);
// prog_array[0] = prog_A, prog_array[1] = prog_B, ...

// 程序中：
bpf_tail_call(ctx, prog_array, index);
```

**执行流程**：

```c
// core.c:bpf_check_tail_call() 编译时检查
// 只允许 tail_call 到 prog_array 中的 prog
static int bpf_check_tail_call(const struct bpf_prog *fp)
{
    for (each map in used_maps) {
        if (map_type_contains_progs(map))  // PROG_ARRAY / DEVMAP / CPUMAP
            if (!__bpf_prog_map_compatible(map, fp))
                return -EINVAL;  // 必须兼容
    }
}

// core.c:___bpf_prog_run() 运行时
case BPF_JMP | BPF_TAIL_CALL:
    array = map->ops->map_lookup_elem(map, (void *)regs[BPF_REG_3]);
    if (!array) goto out;
    prog = array[index];
    if (!prog) goto out;
    // 替换当前 prog context，执行新 prog
    // 不返回到调用者（尾调用语义）
    ((void **)regs)[BPF_REG_0] = NULL;
    goto *(prog->bpf_func);
```

### 7.4 两者对比图

```
BPF-to-BPF Call（函数调用）:
┌────────────────────────────────────────┐
│  main prog                             │
│    call subprog_1                      │
│    R0 = subprog_1(R1)   ← 等待返回值  │
│    ...                                 │
└────────────────────────────────────────┘
         │ call
         ▼
┌────────────────────────────────────────┐
│  subprog_1                             │
│    (同一栈帧，共享寄存器)              │
│    R0 = R1 + 1                         │
│    exit        ← 返回到 main           │
└────────────────────────────────────────┘

Tail Call（尾调用）:
┌────────────────────────────────────────┐
│  prog_A                                │
│    bpf_tail_call(ctx, array, 0)        │
│    (永不返回)                          │
└────────────────────────────────────────┘
         │ 替换当前执行上下文
         ▼
┌────────────────────────────────────────┐
│  prog_B (不同的栈帧)                    │
│    (prog_A 已退出，无返回点)           │
│    ...                                 │
│    bpf_tail_call(ctx, array, 1)        │
└────────────────────────────────────────┘
         │ 继续替换
         ▼
┌────────────────────────────────────────┐
│  prog_C (深度限制: MAX_TAIL_CALL=33)   │
│    exit                                │
└────────────────────────────────────────┘
```

---

## 8. 安全边界：eBPF Capabilities

### 8.1 eBPF 与 Capabilities

eBPF 在 Linux 中有两个主要安全机制：

**机制 1: unprivileged_bpf_disabled sysctl**

```c
// sysctl: kernel/unprivileged_bpf_disabled
// 0 = 所有人都能用（默认）
// 1 = 非 root 需要 CAP_BPF
// 2 = 彻底禁用
if (sysctl_unprivileged_bpf_disabled && !bpf_cap)
    return -EPERM;
```

**机制 2: Capability 检查**

```c
// CAP_BPF: 基础 BPF 操作（程序加载、Map 创建）
// CAP_NET_ADMIN: 网络相关 prog（SCHED_CLS, XDP, ...）
// CAP_PERFMON: 性能监控相关（KPROBE, TRACEPOINT, ...）
// CAP_SYS_ADMIN: 最高权限（内核参数修改等）

if (is_net_admin_prog_type(type) && !bpf_token_capable(token, CAP_NET_ADMIN))
    goto put_token;
if (is_perfmon_prog_type(type) && !bpf_token_capable(token, CAP_PERFMON))
    goto put_token;
```

### 8.2 Root 为什么也可以用 eBPF 做坏事？

```c
// 即使有 CAP_SYS_ADMIN，root 也不能绕过 verifier：
// 1. verifier 检查所有内存访问，即使 root 也要通过
// 2. 但 root 可以:
//    a) 加载任何类型的 prog（包括 perfmon、tracepoint）
//    b) 访问/修改任何 map
//    c) 通过 bpf_probe_read_user() 读取任意用户态内存
//    d) 通过 bpf_probe_read_kernel() 读取内核内存（如果允许）

// seccomp 与 eBPF 的关系：
// seccomp 策略可以限制哪些 syscall 可用
// 但 BPF_PROG_TYPE_SYSCALL 是 seccomp 之外的另一个沙箱
// 两者独立：
//   seccomp: 限制能发哪些 syscall
//   eBPF: 在允许的 syscall 中执行任意逻辑（无 seccomp 时）
```

### 8.3 eBPF 防恶意机制

```
Layer 1: Verifier（沙箱）
  - 所有内存访问经过边界检查
  - 无界循环被拒绝
  - 指针类型检查，防止泄漏

Layer 2: JIT 混淆（Constant Blinding）
  - 关键常量（map fd、helper addr）被混淆
  - 防止 exploit 复用 ROP Gadget

Layer 3: Capabilities
  - 不同 prog type 需要不同权限
  - 细粒度 token 可限制到具体操作

Layer 4: 加固措施（bpf_jit_harden）
  0 = 关闭
  1 = 随机化 JIT 代码布局（防 JIT spray）
  2 = 禁用非特权 JIT

Layer 5: 运行时（noexec stack、smap）
  - eBPF JIT 代码在 non-exec 内存
  - 使用 smap/ustack 防止数据执行
```

---

## 9. 关键数据结构总结

### 9.1 eBPF 指令格式

```c
// include/uapi/linux/bpf.h
struct bpf_insn {
    __u8  code;     // opcode | mode | size
    __u8  dst_reg:4;
    __u8  src_reg:4;
    __s16 off;      // 立即数偏移
    __s32 imm;      // 立即数/常量
};
```

```
BPF 指令 opcode 结构:
  [ 7 | 1 | 4 | 4 | 8 ]  = 24 bits
  class  |  mode | reg   | ... (实际是 64-bit 结构)

主要类别:
  BPF_LD   = 0x00  // Load
  BPF_LDX  = 0x01  // Load from memory
  BPF_ST   = 0x02  // Store immediate
  BPF_STX  = 0x03  // Store to memory
  BPF_ALU  = 0x04  // ALU 操作（32-bit）
  BPF_ALU64 = 0x07 // ALU 操作（64-bit）
  BPF_JMP  = 0x05  // 跳转
  BPF_JMP32 = 0x06 // 32-bit 跳转
  BPF_CALL = 0x08  // 函数调用（imm = helper id）
  BPF_EXIT = 0x09  // 退出
  BPF_ALU | BPF_XOR | BPF_K → 0xa0 = A = A ^ K
```

### 9.2 寄存器约定

```
R0: 返回值
R1 - R5: 参数传递（最多 5 参数）
R6 - R9: 被调用者保存（callee-saved）
R10: 栈帧指针（read-only，frame pointer）

x86_64 映射:
  R1 → rdi, R2 → rsi, R3 → rdx, R4 → r10, R5 → r8
  R0 → rax, R6 → rbx, R7 → r13, R8 → r14, R9 → r15, R10 → rbp
```

---

## 10. 总结

eBPF 的程序加载链路：

1. **用户态**通过 `bpf(BPF_PROG_LOAD, attr)` 发起请求
2. **SYSCALL_DEFINE3(bpf)** 接收，路由到 `bpf_prog_load()`
3. **权限检查** → **类型验证** → **Token 处理** → **程序复制**
4. **Verifer (bpf_check)** 通过状态机模拟所有执行路径，拒绝非法程序
5. **JIT 编译**将字节码转为机器码（或使用 interpreter）
6. **fd 创建**返回用户态，程序驻留在内核

eBPF 的安全建立在多层防御上：verifier 字节码验证、Caps 能力模型、JIT 混淆、运行时保护。Root 持有 CAP_SYS_ADMIN 仍然受 verifier 约束，verifier 是不可逾越的沙箱边界。