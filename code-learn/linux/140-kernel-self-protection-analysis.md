# 140-kernel-self-protection — 读 arch/x86/mm/pti.c + arch/x86/boot/compressed/kaslr.c

---

## KPTI——CR3 切换的成本

（`arch/x86/mm/pti.c` L625）

KPTI（Kernel Page Table Isolation）将内核页表分为两组：用户运行时使用 USER_CR3（只映射用户空间 + entry text），内核运行时切换回 KERNEL_CR3（完整内核映射）。

每次系统调用都需要切换 CR3：

```c
// 用户进入内核时：
// SWITCH_TO_KERNEL_CR3 → mov cr3, KERNEL_PGD | PCID

// 返回用户时：
// SWITCH_TO_USER_CR3 → mov cr3, USER_PGD | PCID
```

CR3 切换本身约 10-30 个周期，但 TLB flush 是真正的成本——旧 CR3 对应的 TLB 条目全部失效。**PCID（Process-Context ID）** 缓解了这个问题：USER_CR3 和 KERNEL_CR3 使用不同的 PCID，两个页表的 TLB 条目可以共存。

```c
pti_init()                            // L625
  ├─ pti_clone_p4d()                  // 克隆内核页表到用户页表
  ├─ pti_setup_entry_text()           // 设置 entry text（syscall/int 入口）在用户页表中可映射
  ├─ pti_remove_kernel_pages()        // 移除用户页表中的内核数据映射
  └─ pti_setup_espfix64()             // L502 — ESPFIX64 兼容性
```

---

## SMAP/SMEP——硬件辅助的隔离

SMAP（Supervisor Mode Access Prevention）和 SMEP（Supervisor Mode Execution Prevention）是 x86 CPU 特性：

- SMEP（CR4.SMEP=1）：内核模式不能执行用户空间的代码
- SMAP（CR4.SMAP=1）：内核模式不能访问用户空间的数据（除非 EFLAGS.AC=1）

内核在 `copy_from_user` 和 `copy_to_user` 中使用 `stac()/clac()` 临时禁用 SMAP：

```c
// arch/x86/include/asm/smap.h
static __always_inline void stac(void)  // Set AC flag — 允许用户空间访问
{ asm volatile("stac" : : : "memory"); }
static __always_inline void clac(void)  // Clear AC flag — 禁止
{ asm volatile("clac" : : : "memory"); }
```

---

## KASLR——地址随机化

KASLR 在内核启动时随机化内核文本和模块的基地址。`choose_random_location()` 在 `arch/x86/boot/compressed/kaslr.c` 中实现：

```
随机化范围：
  kernel text:     ~1GB
  modules:         ~960MB（独立随机）
  vmalloc:         ~32TB
  内核栈偏移：    每进程不同
```
