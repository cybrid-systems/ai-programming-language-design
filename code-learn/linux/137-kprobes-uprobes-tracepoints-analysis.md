# 137-kprobes — 读 kernel/kprobes.c

---

## 设计

kprobe 允许在内核函数的任意指令位置插入探测点。原理是将目标指令替换为 INT3（0xCC），当 CPU 执行到该指令时触发 `#BP` 异常，内核在异常处理程序中调用注册的回调函数。

---

## register_kprobe——注册流程

（`kernel/kprobes.c` L1708）

```c
int register_kprobe(struct kprobe *p)
{
    // 1. 解析符号名 → 地址
    addr = _kprobe_addr(p->addr, p->symbol_name, p->offset, &on_func_entry);

    // 2. 安全检查
    ret = check_kprobe_address_safe(p, &probed_mod);
    // → 检查地址是否在内核文本段
    // → 检查是否在 __init 段（已释放）
    // → 增加模块引用计数（如果在模块中）

    // 3. 注册
    ret = __register_kprobe(p);
    // → 如果目标地址已有 kprobe，加入聚合列表
    // → 否则创建新的 aggr_kprobe
    // → arch_prepare_kprobe(p) — 保存原始指令
    // → arch_arm_kprobe(p) — 写入 INT3 (0xCC)
}
```

---

## kprobe 的执行路径

```
CPU 执行到 INT3
  ↓
#BP 异常（trap 3）
  ↓
do_int3() → kprobe_handler()
  ├─ 1. 查哈希表（按地址）→ 找到对应的 kprobe
  ├─ 2. p->pre_handler(p, regs)  // 预处理器（用户注册的）
  ├─ 3. 单步执行原始指令
  │    → 将 regs->ip 指向 kprobe 的单步缓冲区
  │    → 设置 EFLAGS.TF（Trap Flag）
  │    → 执行完单条指令后触发 #DB 异常
  ├─ 4. p->post_handler(p, regs, flags)  // 后处理器
  └─ 5. 恢复 regs->ip 指向 INT3 后一条指令
```

---

## 为什么需要单步缓冲区

INT3 指令覆盖了原始指令。为了执行原始指令，kprobe 在 `arch_prepare_kprobe` 阶段将原始指令拷贝到 `p->ainsn.insn` 中（在 x86-64 上，这是一个 kprobe 专用的内存区域）。单步执行时，`regs->ip` 指向这个拷贝，而不是原始位置。这样原始位置的 INT3 保持不变——其他 CPU 如果也执行到同一位置，仍然会触发 kprobe。

---

## kretprobe——函数返回探测

kretprobe 在函数入口处替换返回地址：当目标函数被调用时，kretprobe 修改栈上的返回地址，指向 `kretprobe_trampoline`。函数执行 `ret` 指令时返回到 trampoline，trampoline 调用用户注册的返回值处理器，然后跳转到真正的返回地址。
