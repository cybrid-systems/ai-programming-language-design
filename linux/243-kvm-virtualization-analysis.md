# KVM 虚拟化机制深度分析

> 基于 Linux 7.0-rc1 内核源码分析  
> 核心文件：`virt/kvm/kvm_main.c`、`arch/x86/kvm/x86.c`、`arch/x86/kvm/vmx/`

---

## 1. VM 创建链路——从 KVM_CREATE_VM 到 struct kvm

### 1.1 /dev/kvm 的初始化

在内核模块初始化时，KVM 通过 `misc_register(&kvm_dev)` 将自己注册为一个 misc 设备（主设备号 10），生成 `/dev/kvm 字符设备节点：

```c
// virt/kvm/kvm_main.c
static struct miscdevice kvm_dev = {
    .minor = KVM_MINOR,
    .name = "kvm",
    .fops = &kvm_chardev_fops,
};
misc_register(&kvm_dev);       // → /dev/kvm 创建设备节点
```

`/dev/kvm` 的 `fops` 指向 `kvm_chardev_fops`，其 `unlocked_ioctl` 是 `kvm_dev_ioctl`。此后用户态 QEMU 打开 `/dev/kvm`，一切通信都经由这个 ioctl 路由。

### 1.2 KVM_CREATE_VM 路由

用户态发出 `ioctl(fd, KVM_CREATE_VM, type)` 后，内核路由如下：

```
kvm_dev_ioctl()
  case KVM_CREATE_VM:
    → kvm_dev_ioctl_create_vm(type)
```

`kvm_dev_ioctl_create_vm` 的核心步骤：

```c
// virt/kvm/kvm_main.c:5479
fd = get_unused_fd_flags(O_CLOEXEC);
kvm = kvm_create_vm(type, fdname);        // ← 核心分配函数
file = anon_inode_getfile("kvm-vm", &kvm_vm_fops, kvm, O_RDWR);
fd_install(fd, file);
return fd;                                // → 返回 VM fd 给用户态
```

### 1.3 kvm_create_vm()——struct kvm 的分配与初始化

```c
// virt/kvm/kvm_main.c:1098
static struct kvm *kvm_create_vm(unsigned long type, const char *fdname)
{
    struct kvm *kvm = kvm_arch_alloc_vm();    // 分配 struct kvm + kvm->arch
    struct kvm_memslots *slots;

    mmgrab(current->mm);                      // 引用用户进程地址空间
    kvm->mm = current->mm;                    // ★ 关键：kvm->mm 指向创建者进程
```

**关键点：`kvm->mm = current->mm`**

这里的 `current->mm` 是调用 `KVM_CREATE_VM` 的**用户态进程**（即 QEMU 进程）的 `struct mm_struct *`。这个指针不是为 VM 单独创建的地址空间，而是 KVM 用它来实现：

- 内存条目的管理（`memslots` 的 HVA→GPA 映射依赖这个 mm）
- mmu_notifier 回调的绑定（`mmu_notifier_register(&kvm->mmu_notifier, current->mm)`）
- 用户态映射的页面的可回收性检查

随后依次初始化：
```c
kvm_eventfd_init(kvm);
mutex_init(&kvm->lock);
mutex_init(&kvm->irq_lock);
xa_init(&kvm->vcpu_array);          // xarray 存储 vCPU 指针
init_srcu_struct(&kvm->srcu);       // SRCU 用于 memslot 切换
init_srcu_struct(&kvm->irq_srcu);

// 每个 address space 初始化两份 memslot（active/inactive）
for (i = 0; i < kvm_arch_nr_memslot_as_ids(kvm); i++)
    for (j = 0; j < 2; j++)
        slots = &kvm->__memslots[i][j]; // 初始化 RB tree / hash

// I/O 总线
for (i = 0; i < KVM_NR_BUSES; i++)
    kvm->buses[i] = kzalloc_obj(struct kvm_io_bus, ...);

// 架构相关初始化（x86: setup IDT、GDT、MSR buffer 等）
kvm_arch_init_vm(kvm, type);

// 虚拟化使能（设置 KVM CPU flag）
kvm_enable_virtualization();

// mmu notifier 注册（★ 后续详述）
kvm_init_mmu_notifier(kvm);

// 合并 MMIO ring 初始化
kvm_coalesced_mmio_init(kvm);

// debugfs 目录
kvm_create_vm_debugfs(kvm, fdname);

// 加入全局 VM 链表
mutex_lock(&kvm_lock);
list_add(&kvm->vm_list, &vm_list);
mutex_unlock(&kvm_lock);
```

### 1.4 struct kvm 核心字段

```c
// include/linux/kvm_host.h:770
struct kvm {
    rwlock_t mmu_lock;                 // MMU 操作锁
    struct mutex slots_lock;           // memslot 修改锁
    struct mm_struct *mm;              // ★ 创建者用户进程 mm
    struct kvm_memslots __rcu *memslots[KVM_MAX_NR_ADDRESS_SPACES];
    struct xarray vcpu_array;          // xarray<kvm_vcpu*>
    atomic_t online_vcpus;
    int max_vcpus;
    int created_vcpus;
    struct list_head vm_list;          // 全局 VM 链表
    struct kvm_io_bus __rcu *buses[KVM_NR_BUSES]; // PIO/MMIO/PIO 总线
    struct kvm_arch arch;              // 架构特定状态
    struct mmu_notifier mmu_notifier;  // ★ mmu notifier
    struct kvm_coalesced_mmio_ring *coalesced_mmio_ring;
    struct srcu_struct srcu;
    struct srcu_struct irq_srcu;
    // ...
};
```

---

## 2. vCPU 创建链路——KVM_CREATE_VCPU

### 2.1 VM fd 上的 KVM_CREATE_VCPU

用户态拿到 VM fd 后，发出 `ioctl(vm_fd, KVM_CREATE_VCPU, vcpu_id)`：

```
kvm_vm_ioctl()
  case KVM_CREATE_VCPU:
    → kvm_vm_ioctl_create_vcpu(kvm, arg)
```

### 2.2 kvm_vm_ioctl_create_vcpu()

```c
// virt/kvm/kvm_main.c:4151
static int kvm_vm_ioctl_create_vcpu(struct kvm *kvm, unsigned long id)
{
    // 1. 分配 struct kvm_vcpu 缓存（kmem_cache_zalloc）
    vcpu = kmem_cache_zalloc(kvm_vcpu_cache, GFP_KERNEL_ACCOUNT);
    
    // 2. 分配 struct kvm_run（恰好一个 PAGE_SIZE）
    page = alloc_page(GFP_KERNEL_ACCOUNT | __GFP_ZERO);
    vcpu->run = page_address(page);

    // 3. 通用初始化（设置 kvm、vcpu_id，建立 runsomemem）
    kvm_vcpu_init(vcpu, kvm, id);    // → 设置 vcpu->kvm = kvm
    
    // 4. ★ 架构相关初始化（LAPIC、FPU、MMU、msr_bitmap...）
    r = kvm_arch_vcpu_create(vcpu);
    
    // 5. dirty ring 分配（可选）
    if (kvm->dirty_ring_size)
        kvm_dirty_ring_alloc(kvm, &vcpu->dirty_ring, ...);
    
    // 6. 插入 xarray
    xa_insert(&kvm->vcpu_array, vcpu->vcpu_idx, vcpu, ...);
    kvm->created_vcpus++;
    kvm->online_vcpus++;
}
```

### 2.3 kvm_arch_vcpu_create()（x86）

```c
// arch/x86/kvm/x86.c:12833
int kvm_arch_vcpu_create(struct kvm_vcpu *vcpu)
{
    // 分配 vCPU 特定的 MMU 页表结构（sp、root_hpa 等）
    kvm_mmu_create(vcpu);
    
    // 创建本地 APIC（LAPIC）
    kvm_create_lapic(vcpu);
    
    // 分配 PIO 数据页面
    page = alloc_page(GFP_KERNEL_ACCOUNT | __GFP_ZERO);
    vcpu->arch.pio_data = page_address(page);
    
    // 分配 MCE banks
    vcpu->arch.mce_banks = kcalloc(KVM_MAX_MCE_BANKS * 4, sizeof(u64), ...);
    
    // 分配 wbinvd_dirty_mask
    zalloc_cpumask_var(&vcpu->arch.wbinvd_dirty_mask, ...);
    
    // 创建 emulator context
    alloc_emulate_ctxt(vcpu);
    
    // 分配Guest FPU状态
    fpu_alloc_guest_fpstate(&vcpu->arch.guest_fpu);
    
    // 初始化 PMU
    kvm_pmu_init(vcpu);
    
    // ★ 调用 VMX/SVM 的 vcpu_create（VMX: vmx_vcpu_create）
    r = kvm_x86_call(vcpu_create)(vcpu);
    
    // 重置 vCPU 状态
    kvm_vcpu_reset(vcpu, false);
    
    // 初始化 vCPU MMU（setup root page table ptr 等）
    kvm_init_mmu(vcpu);
    
    return 0;
}
```

**初始化顺序（重要）**：  
`kvm_mmu_create` → 创建 MMU 基础结构  
`kvm_create_lapic` → LAPIC 模拟设备  
`kvm_x86_call(vcpu_create)` → **VMX 特定**：分配 VMCS、建立 VMCS 配置  
`kvm_init_mmu` → **在 VMX 创建之后**：建立 nested EPT/VPID 等  

---

## 3. vCPU 运行路径——KVM_RUN → VM-Exit → 返回

### 3.1 KVM_RUN ioctl 入口

用户态在 vCPU fd 上调用 `ioctl(vcpu_fd, KVM_RUN)`：

```
kvm_vcpu_ioctl()                     // virt/kvm/kvm_main.c:4405
  case KVM_RUN:
    → kvm_arch_vcpu_ioctl_run(vcpu)  // arch/x86/kvm/x86.c:12014
```

### 3.2 kvm_arch_vcpu_ioctl_run()

```c
// arch/x86/kvm/x86.c:12014
int kvm_arch_vcpu_ioctl_run(struct kvm_vcpu *vcpu)
{
    vcpu_load(vcpu);                 // 迁移 vCPU 到当前物理 CPU
    kvm_load_guest_fpu(vcpu);        // 加载 Guest FPU/XSAVE 状态
    kvm_vcpu_srcu_read_lock(vcpu);   // 获取 srcu read lock

    // 处理 vCPU 首次运行前初始化（INIT 信号等）
    if (unlikely(vcpu->arch.mp_state == KVM_MP_STATE_UNINITIALIZED)) {
        if (!vcpu->wants_to_run) { r = -EINTR; goto out; }
        kvm_vcpu_block(vcpu);        // 等待 INIT deassert
        if (kvm_apic_accept_events(vcpu) < 0) { r = 0; goto out; }
        r = -EAGAIN;
        if (signal_pending(current)) { ... goto out; }
    }

    // 同步寄存器（用户态灌入的寄存器值）
    if (kvm_run->kvm_dirty_regs)
        r = sync_regs(vcpu);

    // ★ 预处理：inject pending irqs、fixup cr8 等
    r = kvm_x86_vcpu_pre_run(vcpu);
    if (r <= 0) goto out;

    // ★ 核心：运行 vCPU
    r = vcpu_run(vcpu);

out:
    kvm_put_guest_fpu(vcpu);         // 保存 Guest FPU
    store_regs(vcpu);                // 同步寄存器回 kvm_run
    kvm_vcpu_srcu_read_unlock(vcpu);
    vcpu_put(vcpu);
    return r;
}
```

### 3.3 vcpu_run()——vCPU 主循环

```c
// arch/x86/kvm/x86.c:11750
static int vcpu_run(struct kvm_vcpu *vcpu)
{
    vcpu->run->exit_reason = KVM_EXIT_UNKNOWN;

    for (;;) {
        vcpu->arch.at_instruction_boundary = false;
        
        if (kvm_vcpu_running(vcpu)) {
            // ★ 运行 Guest 代码（直到 VM-Exit）
            r = vcpu_enter_guest(vcpu);
        } else {
            // vCPU 被阻塞（HLT、等待中断等）
            r = vcpu_block(vcpu);
        }

        if (r <= 0) break;   // 0: exit to userspace; <0: error

        kvm_clear_request(KVM_REQ_UNBLOCK, vcpu);
        
        // 如果 Xen hypercall 有待处理事件
        if (kvm_xen_has_pending_events(vcpu))
            kvm_xen_inject_pending_events(vcpu);

        // 如果有 timer 中断 pending，注入
        if (kvm_cpu_has_pending_timer(vcpu))
            kvm_inject_pending_timer_irqs(vcpu);

        // ★ IRQ window exit：Guest 想要接收外部中断
        if (dm_request_for_irq_injection(vcpu) &&
            kvm_vcpu_ready_for_interrupt_injection(vcpu)) {
            vcpu->run->exit_reason = KVM_EXIT_IRQ_WINDOW_OPEN;
            ++vcpu->stat.request_irq_exits;
            r = 0; break;
        }

        // 转到 guest mode 前处理待处理的工作
        if (__xfer_to_guest_mode_work_pending())
            ...
    }
    return r;
}
```

### 3.4 vcpu_enter_guest()——进入 Guest 前的请求处理

```c
// arch/x86/kvm/x86.c:11167
static int vcpu_enter_guest(struct kvm_vcpu *vcpu)
{
    // 按优先级顺序处理所有 pending requests
    if (kvm_request_pending(vcpu)) {
        if (kvm_check_request(KVM_REQ_VM_DEAD, vcpu))    { r=-EIO; goto out; }
        if (kvm_check_request(KVM_REQ_TLB_FLUSH, vcpu))   kvm_vcpu_flush_tlb_all(vcpu);
        if (kvm_check_request(KVM_REQ_MMU_SYNC, vcpu))   kvm_mmu_sync_roots(vcpu);
        if (kvm_check_request(KVM_REQ_LOAD_MMU_PGD, vcpu)) kvm_mmu_load_pgd(vcpu);
        if (kvm_check_request(KVM_REQ_APF_HALT, vcpu))   { vcpu->arch.apf.halted=true; r=1; goto out; }
        if (kvm_check_request(KVM_REQ_NMI, vcpu))        process_nmi(vcpu);
        if (kvm_check_request(KVM_REQ_EVENT, vcpu))      { inject_pending_irq(vcpu); }
        if (kvm_check_request(KVM_REQ_PMU, vcpu))         kvm_pmu_handle_event(vcpu);
        // ... 更多 requests
    }

    // 注入 pending exception（如 triple fault）
    // 注入 pending interrupt（KVM_REQ_EVENT）
    // ...
    
    // 加载 guest FPU/XSAVE/MSRbitmap/TSC...
    kvm_x86_call(prepare_guest_switch)(vcpu);

    // ★ 调用 VMX: vmx_vcpu_run() → VM entry
    exit_fastpath = kvm_x86_call(vcpu_run)(vcpu, run_flags);
    
    // VM-Exit 发生：从这里继续...
    vcpu->mode = OUTSIDE_GUEST_MODE;
    smp_wmb();

    // VM-Exit 后处理 irq（软中断、时钟等）
    kvm_before_interrupt(vcpu, KVM_HANDLING_IRQ);
    local_irq_enable();
    ++vcpu->stat.exits;
    local_irq_disable();
    kvm_after_interrupt(vcpu);
    
    // 处理 EXIT_FASTPATH 返回值
    if (exit_fastpath == EXIT_FASTPATH_EXIT_USERSPACE) { r = 0; goto out; }
    
    // 调用 handle_exit 处理 exit_reason
    r = kvm_x86_call(handle_exit)(vcpu, exit_fastpath);
    return r;
}
```

### 3.5 VMX/SVM vcpu_run() 和 VM-Exit

以 VMX 为例：

```
vmx_vcpu_run(vcpu, run_flags)           // arch/x86/kvm/vmx/vmx.c
  → __vmx_vcpu_run(vcpu, launch_state)
      → asm volatile("vmptrst %0" : "=m"(current_vmcs_ptr))
      → asm volatile("vmcall / vmlaunch / vmresume")
      
// VM-Exit 触发，控制权回到 __vmx_vcpu_run 之后
// → 返回 EXIT_FASTPATH_* 到 vcpu_enter_guest()
```

**EXIT_FASTPATH 机制**（KVM 的快速路径优化）：

```c
typedef fastpath_t;   // 实际上是 int

// 三个可能值：
EXIT_FASTPATH_NONE            // 退出慢速路径，调用 full handle_exit
EXIT_FASTPATH_REENTER_GUEST  // 退出已被处理，直接重新进入 Guest（无 ioctl 返回）
EXIT_FASTPATH_EXIT_USERSPACE // 需要返回用户态（如 IO、MMIO、hypercall）
EXIT_FASTPATH_EXIT_HANDLED   // exit 被处理完但仍需一些 post 处理
```

Fastpath handler 在 `kvm_x86_call(vcpu_run)` 返回后检查。如果不需要返回用户态（REENTER_GUEST），`vcpu_run` 的 for 循环直接继续，再次调用 `vcpu_enter_guest` — 这避免了用户态/内核态的上下文切换开销。

### 3.6 vCPU 运行流程图（ASCII）

```
用户态 QEMU
    │
    │  ioctl(KVM_RUN)
    ▼
kvm_vcpu_ioctl()
    │
    │ → kvm_arch_vcpu_ioctl_run()
    │       │
    │       │  (1) 检查 mp_state，处理 UNINITIALIZED
    │       │  (2) sync_regs() — 用户态 → vCPU 寄存器
    │       │  (3) kvm_x86_vcpu_pre_run() — 预处理
    │       │
    ▼       ▼
  vcpu_run() ────────────────────────────── for(;;) ──────┐
    │                                                         │
    ├── kvm_vcpu_running(vcpu)? ─YES──┐                      │
    │                                 │                      │
    ▼                                 ▼                      │
vcpu_enter_guest(vcpu)        vcpu_block(vcpu)                │
    │                                 │                      │
    │ (A) 处理 KVM_REQ_*               │ (B) 睡眠等待         │
    │     KVM_REQ_TLB_FLUSH            │   wake_up(vcpu->wait)│
    │     KVM_REQ_EVENT ─── inject irq │                      │
    │     KVM_REQ_NMI                  │                      │
    │     KVM_REQ_APF_HALT             │                      │
    │     ...                          │                      │
    │                                 │                      │
    │ (C) kvm_x86_call(vcpu_run)      │                      │
    │     VMX: vmx_vcpu_run()         │                      │
    │     → VM entry (vmlaunch)       │                      │
    │     ╔═══════════════════╗        │                      │
    ║    ║   Guest Running    ║        │                      │
    ║    ╚═══════════════════╝        │                      │
    │     ╔══════════════════════╗     │                      │
    └─────║    VM-Exit 发生!    ║──────┘                      │
          ╚══════════════════════╝                           │
    │                                                         │
    │ exit_fastpath = kvm_x86_call(vcpu_run) 返回            │
    │     = EXIT_FASTPATH_REENTER_GUEST ?                    │
    │         ↓ YES                                          │
    │     循环继续，不返回用户态 ─────────────────────────────┘
    │
    ├──= EXIT_FASTPATH_EXIT_USERSPACE
    │       ↓ break
    │   返回 r=0 到 kvm_arch_vcpu_ioctl_run → out
    │
    ├──= EXIT_FASTPATH_NONE（或其他）
    │       ↓
    │   kvm_x86_call(handle_exit)(vcpu)
    │       ↓
    │   __vmx_handle_exit()
    │       → handle_exception()      # EPT violation、#PF
    │       → handle_io()             # IN/OUT 指令
    │       → handle_cr()             # CR 访问
    │       → handle_msr()             # RDMSR/WRMSR
    │       → handle_hypercall()       # VMCALL
    │       → ...
    │       │
    │       └→ 返回 EXIT_FASTPATH_* 再判断
    │
    ▼
返回用户态（r 写入 kvm_run->exit_reason）
    │
    │  用户态读取 exit_reason
    │  处理 IO/MMIO/Hypercall
    │  再次 ioctl(KVM_RUN)
    ▼
```

---

## 4. 内存虚拟化——GPA → HVA → PFN

### 4.1 gfn_to_hva 链路

当 Guest 访问 GPA（Guest Physical Address）时，需要将 GPA 转换为宿主机的 HVA（Host Virtual Address），最后得到 PFN（Page Frame Number）：

```
gfn_to_hva(kvm, gfn)                  // virt/kvm/kvm_main.c:2741
  → gfn_to_hva_many(gfn_to_memslot(kvm, gfn), gfn, NULL)
      → __gfn_to_hva_memslot(slot, gfn)
          → __gfn_to_hva_many(slot, gfn, nr_pages, writable=true)
              → check memory slot range → 返回 HVA
```

**memslot** 是 Guest 物理地址区间到宿主机虚拟地址区间的映射：
```c
struct kvm_memory_slot {
    gfn_t base_gfn;           // Guest physical frame number
    unsigned long npages;      // 页数
    unsigned long userspace_addr; // HVA（用户态 QEMU mmap 的地址）
    // ...
};
```

### 4.2 kvm_mmu_lookup_gfn——MMU 页表查找

```c
// arch/x86/kvm/mmu/mmu.c
// 查找 guest physical address 对应的 host PFN
// 由 mmu_spte_get_lockless() 实现 lockless 页表查找

// 典型调用路径：
kvm_mmu_lookup_gfn(vcpu, gpa, &spte)
  → walk_shadow_page_set_atomic(vcpu, gpa, &sptep)
      → get_walker(gpa, &walker)
      → for each level: sptep = mmu_spte_get_lockless(walker.sptep)
      → 如果 spte 是 leaf，返回 pfn
```

### 4.3 mmu_notifier——宿主机内存回收与 Guest 页表的同步

KVM 在 VM 创建时注册 mmu_notifier：

```c
// virt/kvm/kvm_main.c:887
static int kvm_init_mmu_notifier(struct kvm *kvm)
{
    kvm->mmu_notifier.ops = &kvm_mmu_notifier_ops;
    return mmu_notifier_register(&kvm->mmu_notifier, current->mm);
}

static const struct mmu_notifier_ops kvm_mmu_notifier_ops = {
    .invalidate_range_start  = kvm_mmu_notifier_invalidate_range_start,
    .invalidate_range_end    = kvm_mmu_notifier_invalidate_range_end,
    .clear_flush_young       = kvm_mmu_notifier_clear_flush_young,
    .clear_young             = kvm_mmu_notifier_clear_young,
    .test_young              = kvm_mmu_notifier_test_young,
    .release                 = kvm_mmu_notifier_release,
};
```

**触发时机**（当宿主机内存压力导致页面换出或迁移时）：

| 回调 | 触发场景 |
|------|---------|
| `invalidate_range_start` | `munmap`、`madvise(MADV_DONTNEED)`、`page migration`、`hugepage collapse` |
| `clear_flush_young` | ` Page Table Entry 的 A/D bit 被 clear（KSM 合并等） |
| `test_young` | 询问某 HVA 对应页是否 young |
| `release` | `mm_struct` 销毁 |

`invalidate_range_start` 的核心动作：
```c
// virt/kvm/kvm_main.c:721
static int kvm_mmu_notifier_invalidate_range_start(...)
{
    const struct mmu_notifier_range hva_range = {
        .start = range->start,
        .end   = range->end,
        .event  = MMU_NOTIFIER_RANGE_LAZY,
        .ops   = &kvm_mmu_notifier_range_ops,
    };
    
    __mmu_notifier_invalidate_range(kvm, &hva_range);
    
    // 对每个受影响 memslot：
    // → kvm_arch_memslot_updated()
    // → flush remote TLBs（TLLB）
}
```

### 4.4 kvm->tlb_dirty 与 TLB 刷新

KVM 使用 `tlb_dirty` 机制追踪 Guest 页表的脏页。关键路径：

```c
// 宿主机页面被修改（如被 mmu_notifier 回收）
kvm_mmu_notifier_invalidate_range_start()
  → __kvm_mmu_invalidate_range()
  → kvm->mmu_invalidate_seq++   // 序列号递增

// Guest TLB shootdown：强制所有物理 CPU 刷新 EPT/TLB
kvm_flush_remote_tlbs(kvm)         // virt/kvm/kvm_main.c:293
  → on_each_cpu_mask(cpu_online_mask, flush_smp_call_function, ...)
  → arch/x86: kvm_flush_tlb_all()
```

**dirty ring**（新机制，替代旧的 dirty bitmap）：
- 每个 vCPU 有自己的 `struct kvm_dirty_ring`
- Guest 写 guest page 时，硬件自动记录 GFN 到 dirty ring（通过 EPT dirty bit 或 hardware logdirty）
- 用户态通过 `KVM_GET_DIRTY_LOG` 一次性读取

---

## 5. 中断虚拟化——PIC / IOAPIC / LAPIC

### 5.1 三层设备架构

```
外部中断源（硬件）
    │
    │ IRQ pin
    ▼
┌─────────┐   ISA  IRQs   ┌───────────────┐
│  vPIC   │ (ISA 0-7,8-15)│               │
│ (i8259) │───────────────►│   IOAPIC      │
└─────────┘               │ (for PCI)     │
                          │               │
                          │  PIN 0-23    │
                          └───────┬───────┘
                                  │ PIN/INT 点
                                  ▼
                          ┌───────────────┐
                          │    LAPIC      │
                          │ (per-vCPU)   │
                          │   IRR / ISR   │
                          └───────┬───────┘
                                  │ vectors
                                  ▼
                            Guest CPU
                            (注入 #INT)
```

### 5.2 vPIC（虚拟 8259 PIC）

```c
// arch/x86/kvm/i8259.c
struct kvm_pic {
    struct kvm *kvm;
    struct kvm_vcpu *vpic0, *vpic1;   // 主 PIC 和从 PIC
    // 8 位寄存器：IMR、IRR、ISR、INT
    u8 imr;       // Interrupt Mask Register
    u8 irr;       // Interrupt Request Register
    u8 isr;       // In-Service Register
    unsigned char read_reg_select;
    // ...
};
```

当 ISA 外设发出 IRQ（如 PIT 计时器）→ 注入 `KVM_REQ_EVENT` → `vcpu_enter_guest` 中处理。

### 5.3 IOAPIC

```c
// arch/x86/kvm/ioapic.c
struct kvm_ioapic {
    struct kvm *kvm;
    union kvm_ioapic_redirect_entry redirtbl[24];  // 24 个引脚
    // RTe: dest_id, dest_mode, delivery_mode, vector, masked
};

int ioapic_set_irq(struct kvm_ioapic *ioapic, unsigned int irq,
                   unsigned int level, bool line_status)
  → kvm_irq_delivery_to_apic(ioapic->kvm, NULL, &irqe)
      → __kvm_irq_delivery_to_apic() → 查 RTE → 找目标 LAPIC
```

### 5.4 LAPIC

```c
// arch/x86/kvm/lapic.c
struct kvm_lapic {
    struct kvm_vcpu *vcpu;
    struct page *regs_page;      // 映射到 Guest 0xFEE00000 区域
    // 32 位 timer
    // IRR[32]: Interrupt Request Register（pending 中断）
    // ISR[32]: In-Service Register（正在服务的中断）
    // TPR、EOI、ICR、LDR、SVR...
};
```

**中断注入流程**：

```
外部中断 (IOAPIC/PIC)
    │
    ▼
kvm_irq_delivery_to_apic()
    │
    ├── PIR（Posted Interrupt Request，APICv 模式）路径：
    │   → kvm_x86_call(deliver_interrupt)(vcpu)
    │   → 或设置 vcpu->arch.pending_ext_irq
    │
    └── 普通路径：
        → __kvm_irq_delivery_to_apic()
        → irqe.vector 写入 LAPIC IRR
        → kvm_make_request(KVM_REQ_EVENT, vcpu)

vcpu_enter_guest():
    if (kvm_check_request(KVM_REQ_EVENT, vcpu))
        → kvm_x86_call(inject_pending_irq)(vcpu)
            → kvm_apic_has_interrupt(vcpu)      // 检查 IRR
            → kvm_x86_call(set_irq)(vcpu)         // VMX: vmx_inject_irq
            → 更新 LAPIC ISR

LAPIC timer 超时：
    lapic_timer_expire() → kvm_make_request(KVM_REQ_EVENT, vcpu)
```

### 5.5 kvm_vcpu_interrupt 调用位置

```c
// arch/x86/kvm/lapic.c
static void kvm_apic_inject_pending_timer_irqs(struct kvm_lapic *apic)
{
    kvm_apic_set_timer(apic);
    kvm_make_request(KVM_REQ_EVENT, apic->vcpu);  // ← 触发注入
}

// i8259.c
pic_intack(vcpu)  → kvm_make_request(KVM_REQ_EVENT, vcpu)
```

在 `vcpu_enter_guest()` 中，`KVM_REQ_EVENT` 被处理时会：
1. 调用 `kvm_apic_has_interrupt()` 检查 LAPIC IRR 是否有待处理中断
2. 调用 `kvm_x86_call(inject_pending_irq)` 实际写入 VMCS 中断信息字段
3. VM entry 时硬件自动注入该中断到 Guest

---

## 6. /dev/kvm 设备节点与 ioctl 路由总图

```
用户态 QEMU
    │
    ├── open("/dev/kvm") → 得到 kvm_chardev fd
    │
    │  ioctl(kvm_fd, KVM_CREATE_VM, type)
    │  → kvm_dev_ioctl_create_vm()
    │      → kvm_create_vm()              // → struct kvm
    │      → anon_inode_getfile("kvm-vm", &kvm_vm_fops, kvm)
    │      → 返回 VM fd
    │
    ├── ioctl(vm_fd, KVM_CREATE_VCPU, id)
    │  → kvm_vm_ioctl_create_vcpu()
    │      → kvm_arch_vcpu_create()       // → struct kvm_vcpu
    │      → 返回 vCPU fd
    │
    ├── ioctl(vm_fd, KVM_SET_MEM_REGION / KVM_SET_USER_MEMORY_REGION)
    │  → kvm_vm_ioctl_set_memory_region()
    │      → kvm_set_memory_region()
    │
    ├── ioctl(vm_fd, KVM_IRQFD, ...)
    │  → kvm_vm_ioctl_irqfd()
    │
    ├── ioctl(vm_fd, KVM_CREATE_IRQCHIP)
    │  → kvm_vm_ioctl_create_irqchip()
    │      → kvm_pic_init() + kvm_ioapic_init()
    │
    ├── ioctl(vcpu_fd, KVM_RUN)
    │  → kvm_vcpu_ioctl()
    │      → kvm_arch_vcpu_ioctl_run()
    │          → vcpu_run()
    │              → vcpu_enter_guest()
    │                  → [Guest 执行]
    │                  → VM-Exit
    │                  → handle_exit() / fastpath
    │
    ├── ioctl(vcpu_fd, KVM_KVM_GET_REGS / KVM_SET_REGS)
    │  → kvm_vcpu_ioctl(get|set)_regs()
    │
    └── ioctl(vcpu_fd, KVM_GET_SREGS / KVM_SET_SREGS)
        → kvm_vcpu_ioctl(get|set)_sregs()
```

---

## 7. Hypercall 机制

### 7.1 Guest 发起 Hypercall

Guest 执行 `VMCALL`（或 `vmcall` 指令）→ VM-Exit → `handle_hypercall()` → `kvm_emulate_hypercall()`

### 7.2 KVM 支持的 Hypercall（arch/x86/kvm/x86.c）

```c
int ____kvm_emulate_hypercall(struct kvm_vcpu *vcpu, int cpl, ...)
{
    unsigned long nr = kvm_rax_read(vcpu);   // hypercall number
    unsigned long a0 = kvm_rbx_read(vcpu);   // arg0
    unsigned long a1 = kvm_rcx_read(vcpu);   // arg1 ...

    if (cpl) { ret = -KVM_EPERM; goto out; }  // 必须 CPL=0（kernel mode）

    switch (nr) {
    case KVM_HC_VAPIC_POLL_IRQ:
        ret = 0;  // 通知 host: 无需注入中断，guest 自己轮询
        break;

    case KVM_HC_KICK_CPU:
        // 唤醒指定 vCPU（用于 PV unlock提示）
        kvm_pv_kick_cpu_op(vcpu->kvm, a1);
        kvm_sched_yield(vcpu, a1);  // yield 给指定 vCPU
        ret = 0;
        break;

    case KVM_HC_CLOCK_PAIRING:
        // Para-virtualized clock：更新 guest 物理TSC → host wallclock 映射
        ret = kvm_pv_clock_pairing(vcpu, a0, a1);
        break;

    case KVM_HC_SEND_IPI:
        // Para-virtualized IPI：批量发送中断到多个 vCPU
        ret = kvm_pv_send_ipi(vcpu->kvm, a0, a1, a2, a3, op_64_bit);
        break;

    case KVM_HC_SCHED_YIELD:
        // 让当前 vCPU 让出调度
        kvm_sched_yield(vcpu, a0);
        ret = 0;
        break;

    case KVM_HC_MAP_GPA_RANGE: {
        // ★ 通知 host：GPA 区间现在可以直接映射（shared memory）
        // → KVM_EXIT_HYPERCALL 返回用户态
        vcpu->run->exit_reason = KVM_EXIT_HYPERCALL;
        vcpu->run->hypercall.nr = KVM_HC_MAP_GPA_RANGE;
        vcpu->run->hypercall.args[0] = gpa;
        vcpu->run->hypercall.args[1] = npages;
        vcpu->run->hypercall.ret  = 0;
        vcpu->arch.complete_userspace_io = complete_hypercall;
        return 0;   // ← 不 inject，返回用户态处理
    }
    }
}
```

**对于 `KVM_HC_MAP_GPA_RANGE`**：这是 SEV 机密 VM 共享内存映射场景。由于 KVM 无法直接处理，需要将控制权交回 QEMU（用户态）处理。

### 7.3 Hypercall 返回用户态的路径

```
kvm_emulate_hypercall() 返回 0
    ↓
vcpu_enter_guest() 返回 r=0
    ↓
vcpu_run() 的 for 循环 break
    ↓
kvm_arch_vcpu_ioctl_run() 返回 r=0
    ↓
用户态 ioctl 返回 0
    ↓
用户态看到 exit_reason == KVM_EXIT_HYPERCALL
    ↓
读取 vcpu->run->hypercall.* 字段
    ↓
处理完毕后再次 ioctl(KVM_RUN)
```

---

## 8. Coalesced MMIO

### 8.1 背景

传统 MMIO 处理流程：每次 Guest MMIO 写 → VM-Exit → `handle_mmio()` → `kvm_queue_emulation()` → QEMU 处理 → 返回 KVM。频繁的 VM-Exit 带来巨大开销。

### 8.2 Coalesced MMIO 机制

```c
// virt/kvm/coalesced_mmio.c
struct kvm_coalesced_mmio_ring {
    __u32 coalesced_mmio[KVM_COALESCED_MMIO_LIMIT];
    // 每个 entry: { phys_addr, len, data, pio }
    __u32 prod;
    __u32 count;
};

// 写 MMIO 到合并区域
coalesced_mmio_write(vcpu, this, addr, len, val)
  → ring = dev->kvm->coalesced_mmio_ring;
  → ring->coalesced_mmio[prod % KVM_COALESCED_MMIO_LIMIT]
       = { addr, len, data, pio };
  → ring->prod++;

// QEMU 用户态通过读这个 ring 批量接收 MMIO 写
// 避免逐个 VM-Exit
```

**与 `kvm_write_guest_cached` 的关系**：

- `kvm_write_guest_cached` — KVM 内核向 Guest 物理内存写入（模拟设备写 Guest RAM）
- `coalesced_mmio_write` — Guest 写 MMIO region，被合并到 ring，供用户态批量收集

两者方向相反。Coalesced ring 通过 `KVM_GET_COALESCED_mmio` 从用户态读取。

### 8.3 kvm_coalesced_mmio_init()

```c
// virt/kvm/coalesced_mmio.c:95
int kvm_coalesced_mmio_init(struct kvm *kvm)
{
    page = alloc_page(GFP_KERNEL_ACCOUNT | __GFP_ZERO);
    kvm->coalesced_mmio_ring = page_address(page);
    spin_lock_init(&kvm->ring_lock);
    kvm->coalesced_mmio_ring->prod = 0;
    kvm->coalesced_mmio_ring->count = 0;
}
```

在 `kvm_create_vm()` 中调用（在 `kvm_create_vm_debugfs` 之前）。

---

## 9. vCPU 运行 → VM-Exit → 中断注入 完整流程图（ASCII）

```
═══════════════════════════════════════════════════════════════
                    vCPU Run Loop — Complete Flow
═══════════════════════════════════════════════════════════════

  QEMU 进程（用户态）
      │
      │  ioctl(vcpu_fd, KVM_RUN)
      ▼
┌─────────────────────────────────────────────────────────────┐
│  kvm_vcpu_ioctl(KVM_RUN)                                   │
│    → kvm_arch_vcpu_ioctl_run(vcpu)                         │
│      → kvm_load_guest_fpu()                                │
│      → [MP_STATE_UNINIT? → kvm_vcpu_block() 等待 INIT]     │
│      → kvm_x86_vcpu_pre_run()                              │
│      ▼                                                     │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  vcpu_run()  ──── for (;;) {                         │  │
│  │                                                    │  │
│  │  ┌─ kvm_vcpu_running(vcpu)?                       │  │
│  │  │  YES                                          │  │
│  │  ▼                                                │  │
│  │  vcpu_enter_guest(vcpu)                          │  │
│  │    ├─ kvm_check_request(KVM_REQ_TLB_FLUSH)       │  │
│  │    ├─ kvm_check_request(KVM_REQ_EVENT)──inject   │  │
│  │    │    interrupt (irq, nmi, exception)           │  │
│  │    ├─ kvm_check_request(KVM_REQ_NMI)             │  │
│  │    ├─ kvm_check_request(KVM_REQ_APF_HALT)       │  │
│  │    ├─ [其他 requests]                            │  │
│  │    ├─ kvm_x86_call(prepare_guest_switch)(vcpu)   │  │
│  │    │   (加载 Guest TSC / MSR bitmap / FPU)       │  │
│  │    └────────────────────────────────────────────  │  │
│  │    │                                              │  │
│  │    │ kvm_x86_call(vcpu_run)(vcpu)  ◄── VMX/SVM   │  │
│  │    │   ├─ vmx_vcpu_run()                         │  │
│  │    │   │    └─ __vmx_vcpu_run()                  │  │
│  │    │   │         └─ asm("vmlaunch") / vmresume    │  │
│  │    │   │                                           │  │
│  │    │   ╔═══════════════════════════════════════╗    │  │
│  │    ║══║         G  U  E  S  T     R  U  N    ║════│  │
│  │    ║  ╚═══════════════════════════════════════╝    │  │
│  │    │                                              │  │
│  │    │  ╔══════════════════════════════════════╗    │  │
│  │    ╚══╣         VM - EXIT  发 生  !          ╠════│  │
│  │       ╚══════════════════════════════════════╝    │  │
│  │    │                                              │  │
│  │    │ exit_fastpath = kvm_x86_call(vcpu_run)      │  │
│  │    │       返回 fastpath_t                       │  │
│  │    │                                              │  │
│  │    ├─ EXIT_FASTPATH_REENTER_GUEST               │  │
│  │    │    (退出被处理，无需用户态介入)              │  │
│  │    │    → 循环继续，再次 vcpu_enter_guest()      │  │
│  │    │                                             │  │
│  │    ├─ EXIT_FASTPATH_EXIT_USERSPACE              │  │
│  │    │    → break; r=0; (QEMU 处理)              │  │
│  │    │                                             │  │
│  │    └─ EXIT_FASTPATH_NONE                        │  │
│  │         → kvm_x86_call(handle_exit)(vcpu)       │  │
│  │            ├─ __vmx_handle_exit()              │  │
│  │            │    ├─ handle_exception(#PF, #GP)  │  │
│  │            │    ├─ handle_io()  (IN/OUT)       │  │
│  │            │    ├─ handle_cr()  (CR access)    │  │
│  │            │    ├─ handle_msr() (RDMSR/WRMSR) │  │
│  │            │    ├─ handle_hypercall(VMCALL)   │  │
│  │            │    ├─ handle_apic_access()       │  │
│  │            │    └─ ...                         │  │
│  │            │    → 返回 EXIT_FASTPATH_*         │  │
│  │            └─ 循环继续 / break                 │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  kvm_put_guest_fpu()                                        │
│  store_regs(vcpu)            // 同步寄存器到 kvm_run        │
│  return r (0: exit to userspace, >0: continue loop)        │
└─────────────────────────────────────────────────────────────┘
      │
      │  用户态：read(vcpu_fd, kvm_run, ...)
      │  检查 kvm_run->exit_reason
      │  switch(exit_reason) { 处理 }
      │
      ├── KVM_EXIT_IO          → QEMU 模拟 I/O 端口访问
      ├── KVM_EXIT_MMIO        → QEMU 模拟 MMIO 读写
      ├── KVM_EXIT_HYPERCALL   → QEMU 处理 KVM_HC_MAP_GPA_RANGE 等
      ├── KVM_EXIT_IRQ_WINDOW_OPEN → QEMU 注入外部中断
      ├── KVM_EXIT_SHUTDOWN    → QEMU 处理 triple fault / reboot
      └── KVM_EXIT_DEBUG       → QEMU 处理 guest debug
```

---

## 10. 关键数据结构关系总览

```
┌──────────────────────────────────────────────────────────────────┐
│  用户态 QEMU 进程（current->mm）                                  │
│    │                                                             │
│    ├─ /dev/kvm fd (kvm_chardev_fops)                            │
│    │     │                                                       │
│    │     ├─ KVM_CREATE_VM ──→ kvm_create_vm()                    │
│    │     │                    ├─ kvm_arch_alloc_vm()             │
│    │     │                    ├─ mmgrab(current->mm)              │
│    │     │                    ├─ kvm->mm = current->mm  ★       │
│    │     │                    ├─ kvm_init_mmu_notifier(kvm)      │
│    │     │                    ├─ kvm_coalesced_mmio_init(kvm)     │
│    │     │                    └─ 返回 struct kvm *               │
│    │     │                                                       │
│    │     └─ VM fd (kvm_vm_fops) ─┐                              │
│    │                             │                              │
│    │    KVM_CREATE_VCPU          │                              │
│    │         ↓                   │                              │
│    │    kvm_vm_ioctl_create_vcpu │                              │
│    │         ├─ kmem_cache_zalloc(kvm_vcpu_cache)               │
│    │         ├─ kvm_vcpu_init()                                 │
│    │         ├─ kvm_arch_vcpu_create()  ★ x86 特有            │
│    │         │     ├─ kvm_mmu_create()                         │
│    │         │     ├─ kvm_create_lapic()                       │
│    │         │     ├─ kvm_x86_call(vcpu_create) → VMX/SVM     │
│    │         │     ├─ fpu_alloc_guest_fpstate()                │
│    │         │     └─ kvm_init_mmu()                            │
│    │         └─ xa_insert(&kvm->vcpu_array, vcpu)               │
│    │                             │                              │
│    │         vCPU fd (kvm_vcpu_fops) ─┘                         │
│    │              │                                             │
│    │              │  KVM_RUN                                    │
│    │              ↓                                             │
│    │         kvm_arch_vcpu_ioctl_run()                          │
│    │              ├─ vcpu_load()                                │
│    │              ├─ vcpu_run() ─── for(;;)                    │
│    │              │     ├─ vcpu_enter_guest()                  │
│    │              │     │     ├─ 处理 KVM_REQ_*                │
│    │              │     │     ├─ kvm_x86_call(vcpu_run)       │
│    │              │     │     │    (VMX: vmx_vcpu_run)         │
│    │              │     │     │     └─ VM entry                 │
│    │              │     │     │        Guest runs              │
│    │              │     │     │        VM-Exit                 │
│    │              │     │     │     ← return fastpath          │
│    │              │     │     ├─ handle_exit()                 │
│    │              │     │     └─ (loop)                       │
│    │              │     └─ vcpu_put()                           │
│    │              └─ return r                                   │
│    │                                                             │
│    └─ 共享内存 mmap(VMA) ←── guest RAM ←── memslot             │
│           (HVA)               (GPA)                            │
└──────────────────────────────────────────────────────────────────┘

┌─────────────────── struct kvm_vcpu ─────────────────────────┐
│  struct kvm_vcpu {                                            │
│      struct kvm *kvm;           // 所属 VM                    │
│      int vcpu_id;              // 用户空间给的 ID             │
│      struct kvm_run *run;      // ★ PAGE_SIZE，共享给用户态  │
│      struct kvm_vcpu_arch {                                      │
│          // LAPIC                                                     │
│          // FPU (Guest FPU 状态)                                      │
│          // MMU (shadow page tables, root_hpa)                         │
│          // MSR_bitmap                                                │
│          // APICv ( Posted Interrupt Descriptor )                      │
│          struct kvm_lapic *apic;                                    │
│          u8 pending_external_vector;                               │
│      };                                                          │
│      struct mmu_page_desc *arch.mmu.something;                   │
│      struct kvm_vcpu_arch arch;                                  │
│      mode (VCPU_RUNNING / OUTSIDE_GUEST_MODE 等)               │
│      requests (bitfield of KVM_REQ_*)                            │
│  };                                                             │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────── struct kvm ──────────────────────────────┐
│  struct kvm {                                                  │
│      struct mm_struct *mm;      // 创建者用户态进程 mm ★       │
│      struct xarray vcpu_array;  // 所有 vCPU                  │
│      struct kvm_memslots *memslots[NR_AS];  // GPA→HVA 映射 │
│      struct kvm_arch arch;                                   │
│          // vpic、vioapic、x2apic                          │
│          // TSC offset、apic_base、pvclock                  │
│      struct mmu_notifier mmu_notifier;  // 监听宿主机 mm    │
│      struct kvm_coalesced_mmio_ring *coalesced_mmio_ring;    │
│      struct kvm_io_bus *buses[3];  // MMIO/PIO/COALESCED    │
│  };                                                           │
└──────────────────────────────────────────────────────────────┘
```

---

## 11. 小结

| 环节 | 核心函数 | 关键机制 |
|------|---------|---------|
| **VM 创建** | `kvm_create_vm()` → `kvm_arch_alloc_vm()` | `kvm->mm = current->mm` 绑定用户进程 |
| **vCPU 创建** | `kvm_vm_ioctl_create_vcpu()` → `kvm_arch_vcpu_create()` | 先 `kvm_mmu_create()`、再 `vmx_vcpu_create()`、最后 `kvm_init_mmu()` |
| **vCPU 运行** | `vcpu_run()` → `vcpu_enter_guest()` → `vmx_vcpu_run()` | for(;;) 循环 + fastpath 优化 |
| **VM-Exit** | `__vmx_handle_exit()` → 各 handler | exit_reason 决定处理路径 |
| **内存虚拟化** | `gfn_to_hva()` + `kvm_mmu_lookup_gfn()` | memslot 映射 GPA→HVA；shadow page table |
| **MMU notifier** | `invalidate_range_start/end()` | 监听宿主机页面回收，同步 Guest TLB |
| **TLB 刷新** | `kvm_flush_remote_tlbs()` | multi-CPU shootdown，序列号追踪 |
| **中断注入** | `ioapic_set_irq()` → `kvm_irq_delivery_to_apic()` → `KVM_REQ_EVENT` | vPIC + IOAPIC + LAPIC 三层；IRR/ISR 状态机 |
| **Hypercall** | `____kvm_emulate_hypercall()` | `KVM_HC_MAP_GPA_RANGE` 返回用户态，其他内核处理 |
| **Coalesced MMIO** | `coalesced_mmio_write()` | 合并 ring 减少 VM-Exit |
| **设备节点** | `misc_register()` → `kvm_dev_ioctl()` → `kvm_vm_ioctl()` | 二层 ioctl 路由：dev → vm → vcpu |