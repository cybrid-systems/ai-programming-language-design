# Linux 内核自我防护深度分析：KPTI / KASLR / SMAP/SMEP / CFI

## 概述

Linux 内核防护（Kernel Self-Protection）是一系列安全机制的集合，旨在防止用户空间程序利用内核漏洞提升权限或执行任意代码。这些机制涵盖：

- **地址空间隔离**：KPTI（内核页表隔离）、KASLR（内核地址随机化）
- **访问控制**：SMAP / SMEP（x86 特性的软件利用）、PAN / PXN（ARM 对应）
- **控制流完整性**：CFI（控制流完整性）、CET（Intel CET）
- **内存保护**：SLAB_FREELIST_RANDOM、initmem 只读化、rodata 保护

## KPTI — 内核页表隔离

KPTI（之前称为 KAISER）是应对 Meltdown（CVE-2017-5754）漏洞的缓解措施。

### Meltdown 漏洞原理

Meltdown 允许用户空间程序通过**推测执行**读取内核内存：

```
用户空间执行：
  data = *kernel_addr;          // 非法访问 → 触发 #PF（page fault）
  tmp = data_table[data * 64];  // 推测执行：data_table 的哪一 cache line 被加载？
                                // → 通过侧信道（timing）从 cache 中提取 data
```

漏洞的根本原因：**在 page fault 处理前，CPU 推测执行了后续指令**。即使 page fault 最终会触发，但 cache 已被修改。

### KPTI 的缓解方案

KPTI 将内核页表分为两组：

```
正常模式（syscall 入口后 — CR3=KERNEL_CR3）：
  用户页表 ← 映射用户空间 + 内核空间（但用户空间不可达）
  内核页表 ← 仅内核空间

KPTI 隔离模式（用户空间运行 — CR3=USER_CR3）：
  用户页表 ← 映射用户空间 + 最小内核（中断/异常向量 + syscall 入口）
  内核页表 ← 完整内核（仅在切换到内核模式时使用）
```

当用户空间执行时，CR3 指向 `USER_CR3`，其中：
- 映射所有用户空间页面
- 仅映射内核的最小部分：异常处理入口、中断向量表、syscall 入口
- 不映射大部分内核代码和数据

```
用户空间运行时页表：
  ┌────────────────────┐
  │ 用户空间代码/数据   │ ← 完全映射
  ├────────────────────┤
  │ 内核入口（受保护）   │ ← 仅异常/中断/syscall 入口
  │ （entry text）      │
  ├────────────────────┤
  │ 内核其余部分         │ ← 未映射（Meltdown 无法访问！）
  │ （代码、数据、栈）    │
  └────────────────────┘
```

当系统调用或中断发生时：
1. CPU 切换到内核栈
2. `SWAPGS` 交换 GS 基址
3. **切换 CR3** 到 `KERNEL_CR3`（完整内核页表）
4. 执行内核代码
5. 返回用户空间前：**切换 CR3** 回 `USER_CR3`

### KPTI 的关键代码路径

```c
// arch/x86/mm/pti.c — PTI 初始化
void __init pti_init(void)
{
    // 1. 克隆内核页表（kernel_page_table → user_page_table 的副本）
    pti_clone_p4d();
    
    // 2. 设置入口文本段（entry text）在用户页表中可映射
    //    这样用户空间的异常/syscall 入口可以工作
    pti_setup_entry_text();
    
    // 3. 删除用户页表中的内核映射
    //    只保留 L2/L3 跳转（保留 entry text）
    pti_remove_kernel_pages();

    // 4. 设置 ESPFIX64（iret 兼容性）
    pti_setup_espfix64();
}
```

### 性能影响

KPTI 每次 syscall、中断、异常都需要切换 CR3：
- `mov cr3, reg` 指令本身~10-30 周期
- TLB 完全失效（除非 PCID 启用）
- **PCID（Process-Context ID）**：每个 CR3 值关联一个 ID，使两个页表（USER_CR3 和 KERNEL_CR3）的 TLB 条目共存

```c
// CR3 寄存器格式（启用 PCID 后）：
// CR3 = PCID << 12 | PGD 物理地址
// 用户空间 CR3: PCID=0（用户页表，仅 TLB 条目）
// 内核 CR3:    PCID=1（内核页表，仅 TLB 条目）

// 切换页表时，PCID 让两个页表的 TLB 条目同时保留
write_cr3(pcid | pgd_addr);
```

启用 PCID 后，KPTI 的性能开销从 ~2-5% 降低到 ~0.5-1%。

## KASLR — 内核地址随机化

KASLR 在每个内核文本段的物理和虚拟基地址中引入随机偏移，防止攻击者基于固定地址构造 ROP 链。

### 实现

```c
// arch/x86/boot/compressed/kaslr.c
// 内核加载时计算随机偏移

unsigned long choose_random_location(...)
{
    // 1. 生成随机偏移
    random_addr = get_random_long() & mask;
    
    // 2. 限制在 CONFIG_RANDOMIZE_BASE 的范围内
    random_addr = slots_fetch_random();
    
    // 3. 对齐到 2MB（大页边界）
    random_addr = ALIGN(random_addr, CONFIG_PHYSICAL_ALIGN);
    
    return random_addr;
}
```

当前支持随机化的区域：

| 区域 | 随机化范围 | 描述 |
|------|-----------|------|
| 内核文本 | ~1GB | 内核代码基地址 |
| 模块 | ~960MB | 模块加载区域（独立于文本） |
| vmalloc | ~32TB | vmalloc 基地址随机化 |
| 栈 | page-level | 进程内核栈随机偏移 |

### KASLR 的局限性

- 如果内核地址被泄露（如 `/proc/kallsyms`、dmesg 信息泄露），KASLR 被绕过
- KASLR 不影响内核内部的相对偏移（函数间的相对位置不变）
- 攻击者可以通过侧信道逐步缩小随机化范围

## SMAP / SMEP（x86）— 用户空间访问隔离

SMAP（Supervisor Mode Access Prevention）和 SMEP（Supervisor Mode Execution Prevention）是 x86 CPU 特性：

```
SMEP（OSXSAVE=1, CR4.SMEP=1）：
  内核模式（CPL=0）执行的代码不能执行用户空间（CPL=3）的代码
  防止：RET2USER → 攻击者利用用户空间代码执行内核态函数

SMAP（OSXSAVE=1, CR4.SMAP=1）：
  内核模式不能访问用户空间的页面（数据+代码）
  防止：内核代码在使用用户空间指针时意外读取
  内核可以通过 EFLAGS.AC（Alignment Check）临时禁用
```

内核中的典型权限提升攻击利用 SMAP/SMEP 绕过：

```
攻击（无 SMAP/SMEP）：
  用户进程：构造一个 ROP 链在用户空间
  触发内核漏洞 → 劫持控制流 → 返回到用户空间的 ROP 链 → 执行 shellcode

防御（有 SMAP/SMEP）：
  用户进程：构造 ROP 链 + shellcode
  触发内核漏洞 → 劫持控制流 → 试图返回到用户空间
  → CPU 触发 #PF（SMEP violation）→ 内核被杀
```

### 内核中的 SMAP/SMEP 处理

```c
// arch/x86/include/asm/smap.h
// 当内核需要访问用户空间数据时（如 copy_from_user）：
static __always_inline void stac(void)
{
    // 设置 EFLAGS.AC 位，临时禁用 SMAP
    alternative("nop; nop", "stac", X86_FEATURE_SMAP);
}

static __always_inline void clac(void)
{
    // 清除 EFLAGS.AC 位，恢复 SMAP
    alternative("nop; nop", "clac", X86_FEATURE_SMAP);
}

// copy_from_user 使用 stac/clac：
unsigned long copy_from_user(void *to, const void __user *from, unsigned long n)
{
    stac();
    ret = raw_copy_from_user(to, from, n);
    clac();
    return ret;
}
```

## CFI — 控制流完整性

### Kernel Control-Flow Integrity（kCFI）

kCFI 在内核编译时插入校验点，确保间接调用的目标地址是合法的函数入口：

```c
// 编译器插入的校验代码（LLVM CFI）：
// 每个间接函数调用前，检查函数指针的哈希值

void (*func)(void) = get_handler();

// 编译后的代码：
// r1 = hash_of_function_signature(func);
// if (r1 != expected_hash)  → panic();
// func();
```

启用 `CONFIG_CFI_CLANG` 后，所有 `indirect call` 都被保护：
- `ops->callback()` → 检查 callback 的签名哈希
- `file_operations->read()` → 检查 read 的签名
- 模块加载时，模块中的函数指针也被签名验证

### FineIBT（Fine-Grained Indirect Branch Tracking）

Intel CET 的 IBT 扩展 + kCFI：

```
FineIBT：在每个函数的入口处插入 `endbr64` 指令
间接跳转时，如果目标地址不是 `endbr64` 开头 → #CP（Control Protection）

kCFI + FineIBT 组合：
  硬件层：endbr64 检查 → 保证跳转到函数入口
  软件层：函数入口处的哈希校验 → 保证跳转到正确的函数
```

## 其他内核防护机制

### 内存保护

| 机制 | 描述 | 配置 |
|------|------|------|
| rodata 只读 | `.rodata` 段标记为只读 | `CONFIG_STRICT_KERNEL_RWX` |
| initmem 释放 | 初始化后释放 init 段 | 默认启用 |
| SLAB_FREELIST_RANDOM | slab 空闲链表随机化 | `CONFIG_SLAB_FREELIST_RANDOM` |
| SLAB_FREELIST_HARDENED | slab 元数据完整性 | `CONFIG_SLAB_FREELIST_HARDENED` |
| STACKPROTECTOR | 内核栈溢出检测 | `CONFIG_STACKPROTECTOR` |
| VMAP_STACK | 内核栈基于 vmap（溢出检测） | `CONFIG_VMAP_STACK` |

### 漏洞缓解

| 机制 | 描述 |
|------|------|
| REFCOUNT_FULL | 完整的引用计数溢出保护 |
| FORTIFY_SOURCE | 编译时缓冲区溢出检测 |
| USERCOPY | 用户空间拷贝的边界检查 |
| RANDOMIZE_KSTACK_OFFSET | 内核栈偏移随机化 |
| BUG_ON_DATA_CORRUPTION | 关键数据结构的完整性断言 |

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `pti_init()` | arch/x86/mm/pti.c | 625 |
| `pti_setup_espfix64()` | arch/x86/mm/pti.c | 502 |
| `pti_clone_p4d()` | arch/x86/mm/pti.c | 相关 |
| `pti_setup_entry_text()` | arch/x86/mm/pti.c | 相关 |
| `pti_check_boottime_disable()` | arch/x86/mm/init.c | 762 |
| `choose_random_location()` | arch/x86/boot/compressed/kaslr.c | 相关 |
| `stac()` / `clac()` | arch/x86/include/asm/smap.h | 内联函数 |
| `copy_from_user()` | include/linux/uaccess.h | (使用 stac/clac) |
| `kernel_text_address()` | kernel/extable.c | 94 |
| `__kernel_text_address()` | kernel/extable.c | 77 |
| X86_FEATURE_PTI | arch/x86/include/asm/cpufeatures.h | 特征位 |
| X86_FEATURE_SMEP | arch/x86/include/asm/cpufeatures.h | 特征位 |
| X86_FEATURE_SMAP | arch/x86/include/asm/cpufeatures.h | 特征位 |
| X86_FEATURE_IBT | arch/x86/include/asm/cpufeatures.h | 特征位 |
