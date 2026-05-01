# KVM 虚拟化机制深度分析

> 基于 Linux 7.0-rc1 内核源码
> 核心源码路径：`virt/kvm/kvm_main.c`、`arch/x86/kvm/`

---

## 一、整体架构总览

KVM（Kernel-based Virtual Machine）是 Linux 内核的硬件虚拟化基础设施。它不是独立的 Hypervisor，而是依赖 CPU 硬件虚拟化支持（Intel VT-x / AMD-V），将 Linux 内核本身转化为 Hypervisor。

```
┌──────────────────────────────────────────────────────┐
│                   用户态 (QEMU / Libvirt)            │
│                                                      │
│   /dev/kvm (char device)                            │
│     ├── kvm_dev_ioctl()   ← KVM_CREATE_VM          │
│     └── VM fd → kvm_vm_ioctl() ← KVM_CREATE_VCPU   │
│          └── vCPU fd → kvm_vcpu_ioctl() ← KVM_RUN │
└──────────────────────────────────────────────────────┘
                           │
┌──────────────────────────────────────────────────────┐
│                   内核态 (KVM 模块)                  │
│                                                      │
│  kvm_main.c:                                         │
│    struct kvm         ← Virtual Machine               │
│    struct kvm_vcpu   ← Virtual CPU                    │
│    kvm_mmu_notifier  ← 内存监听器                    │
│                                                      │
│  arch/x86/kvm/:                                      │
│    vmx/vmx.c     ← Intel VT-x 实现                   │
│    svm/svm.c     ← AMD-V 实现                        │
│    lapic.c       ← 虚拟 Local APIC                   │
│    ioapic.c      ← 虚拟 IOAPIC                       │
│    irq.c         ← 中断路由                          │
│    x86.c         ← 通用 x86 逻辑                     │
└──────────────────────────────────────────────────────┘
```

---

## 二、VM 创建 —— 从 KVM_CREATE_VM 到 struct kvm

### 2.1 /dev/kvm 注册与 ioctl 路由

KVM 通过 miscdevice 注册为字符设备：

```c
// kvm_main.c
static struct file_operations kvm_chardev_ops = {
    .unlocked_ioctl = kvm_dev_ioctl,
    KVM_COMPAT(kvm_dev_ioctl),
};

static struct miscdevice kvm_dev = {
    .minor = MISC_DYNAMIC_MINOR,
    .name = "kvm",
    .fops = &kvm_chardev_ops,
};
// 通过 misc_register() 注册到 /dev/kvm
```

`kvm_dev_ioctl()` 是进入内核的第一个入口：

```c
// kvm_main.c:5522
static long kvm_dev_ioctl(struct file *filp, unsigned int ioctl, unsigned long arg)
{
    switch (ioctl) {
    case KVM_GET_API_VERSION:    // → 12
    case KVM_CHECK_EXTENSION:    // 查询能力
    case KVM_CREATE_VM:         // ★ 创建 VM
        return kvm_dev_ioctl_create_vm(arg);
    }
}
```

### 2.2 kvm_dev_ioctl_create_vm 流程

```c
// kvm_main.c:5479
static int kvm_dev_ioctl_create_vm(unsigned long type)
{
    fd = get_unused_fd_flags(O_CLOEXEC);
    file = anon_inode_getfile("kvm-vm", &kvm_vm_fops, NULL, O_RDWR);
    // kvm_vm_fops 的 unlocked_ioctl 指向 kvm_vm_ioctl()

    fd_install(fd, file);
    return fd;  // 返回 VM fd 给用户态
}
```

### 2.3 kvm_create_vm() —— struct kvm 的诞生

```c
// kvm_main.c:1098
static struct kvm *kvm_create_vm(unsigned long type, const char *fdname)
{
    struct kvm *kvm = kvm_arch_alloc_vm();   // 分配 struct kvm + arch 部分
    mmgrab(current->mm);                    // ★ 持有用户进程的 mm_struct
    kvm->mm = current->mm;                  // ★ VM 与创建者进程绑定

    KVM_MMU_LOCK_INIT(kvm);
    mutex_init(&kvm->lock);
    mutex_init(&kvm->slots_lock);
    spin_lock_init(&kvm->mn_invalidate_lock);
    xa_init(&kvm->vcpu_array);

    // 初始化 MMU notifier（用于监听宿主内存变化）
    r = kvm_init_mmu_notifier(kvm);         // 注册 mmu_notifier

    // 创建 ISA 总线（用于 PIT、PS/2 等）
    kvm_init_pmu_control(kvm);

    // 初始化中断路由
#ifdef CONFIG_HAVE_KVM_IRQCHIP
    kvm_init_irq_routing(kvm);
#endif

    // 创建 debugfs 节点
    r = kvm_create_vm_debugfs(kvm, fdname);

    list_add(&kvm->vm_list, &vm_list);  // 加入全局 vm_list
    return kvm;
}
```

**关键点：kvm->mm 与用户进程的关系**

- `kvm->mm = current->mm`：记录创建 VM 的用户态进程的 `struct mm_struct`
- `mmgrab(current->mm)`：增加 mm 的引用计数，防止进程退出时 mm 被销毁
- 这个 mm 用于：**用户态通过 mmap 映射的 guest 内存，需要通过这个 mm 找到对应的虚拟地址空间**
- 注意：KVM **不依赖** Linux 的进程调度来运行 vCPU。vCPU 跑在宿主的物理 CPU 上，通过 VM-Exit/VM-Entry 切换客户机状态

### 2.4 struct kvm 核心字段

```c
// include/linux/kvm_host.h:770
struct kvm {
    struct mm_struct *mm;           // ★ 创建 VM 的用户进程
    struct mutex slots_lock;        // 保护 memory slots
    struct kvm_memslots __rcu *memslots[KVM_MAX_NR_ADDRESS_SPACES];
                                   // ★ 客户机物理地址 → 宿主虚拟地址 的映射

    struct xarray vcpu_array;       // ★ 所有 vCPU 的数组
    atomic_t online_vcpus;

    struct list_head vm_list;       // 全局 VM 链表
    struct mutex lock;

    struct kvm_io_bus __rcu *buses[KVM_NR_BUSES];  // PIO/MMIO 总线
    struct mmu_notifier mmu_notifier;  // ★ 内存变化监听
    spinlock_t mn_invalidate_lock;
    unsigned long mn_active_invalidate_count;

    // APIC / 中断
#ifdef CONFIG_HAVE_KVM_IRQCHIP
    struct kvm_irq_routing *irq_routing;
    struct kvm_irqchip *irqchip;    // 虚拟 LAPIC + IOAPIC
#endif

    // 架构相关
    struct kvm_arch arch;
};
```

---

## 三、vCPU 创建 —— KVM_CREATE_VCPU

### 3.1 VM fd → kvm_vm_ioctl()

用户态拿到 VM fd 后，调用 `KVM_CREATE_VCPU` ioctl，经过：

```c
// kvm_main.c:5147
static long kvm_vm_ioctl(struct file *filp, unsigned int ioctl, unsigned long arg)
{
    struct kvm *kvm = filp->private_data;

    switch (ioctl) {
    case KVM_CREATE_VCPU:
        r = kvm_vm_ioctl_create_vcpu(kvm, arg);  // arg = vcpu_id
    }
}
```

### 3.2 kvm_vm_ioctl_create_vcpu()

```c
// kvm_main.c:4151
static int kvm_vm_ioctl_create_vcpu(struct kvm *kvm, unsigned long id)
{
    // 1. 分配 struct kvm_vcpu + arch 部分
    vcpu = kvm_arch_vcpu_create(kvm, id);

    // 2. 设置 vCPU 的运行 fd（anon_inode）
    file = anon_inode_getfile("kvm-vcpu", &kvm_vcpu_fops, vcpu, O_RDWR);
    vcpu->run = mmap(file, 0, PAGESIZE, PROT_READ|PROT_WRITE, MAP_SHARED, 0);
    // ↑ vcpu->run 指向 struct kvm_run，是 guest 运行状态的共享内存

    // 3. 注册到 kvm->vcpu_array
    xa_store(&kvm->vcpu_array, id, vcpu, GFP_KERNEL_ACCOUNT);

    // 4. 初始化 LAPIC（x86）
    kvm_arch_vcpu_postcreate(vcpu);

    return fd;  // 返回 vCPU fd 给用户态
}
```

### 3.3 struct kvm_vcpu 核心字段

```c
// include/linux/kvm_host.h:325
struct kvm_vcpu {
    struct kvm *kvm;              // 所属 VM
    unsigned int vcpu_id;         // vCPU 编号
    struct file *run;             // ★ struct kvm_run 用户空间映射

    // 运行状态
    enum kvm_mp_state mp_state;   // RUNNABLE / HALTED / UNINITIALIZED
    struct pid *pid;             // 绑定到的宿主线程

    // 架构相关
    struct kvm_vcpu_arch arch;   // vCPU 执行状态（寄存器等）

    // 中断/异常注入
    struct {
        bool injected;
        bool pending;
        int vector;
    } exception;

    struct {
        bool injected;
        int nr;
    } nmi;

    struct {
        bool injected;
        int nr;
    } interrupt;

    // 各种请求标志（KVM_REQ_*）
    unsigned long requests;

    // LAPIC
    struct kvm_lapic *apic;       // 虚拟 Local APIC

    // preempt_notifier 用于 vcpu_load/vcpu_put
    struct preempt_notifier preempt_notifier;
};
```

### 3.4 /dev/kvm 的三层 ioctl 分发总结

```
ioctl(fd, KVM_CREATE_VM, type)
  └→ kvm_dev_ioctl()          ← /dev/kvm (全局)
       └→ kvm_dev_ioctl_create_vm()
            ├→ kvm_create_vm()
            └→ 返回 VM fd（绑定 kvm_vm_fops）

ioctl(vm_fd, KVM_CREATE_VCPU, vcpu_id)
  └→ kvm_vm_ioctl()           ← VM fd（绑定 kvm_vm_fops）
       └→ kvm_vm_ioctl_create_vcpu()
            ├→ kvm_arch_vcpu_create()
            └→ 返回 vCPU fd（绑定 kvm_vcpu_fops）

ioctl(vcpu_fd, KVM_RUN, 0)
  └→ kvm_vcpu_ioctl()         ← vCPU fd（绑定 kvm_vcpu_fops）
       └→ case KVM_RUN → kvm_arch_vcpu_ioctl_run(vcpu)
```

---

## 四、vCPU 运行路径 —— KVM_RUN 完整链路

### 4.1 用户态视角

```c
// QEMU 类用户态
int vcpu_fd = open("/dev/kvm");
int vm_fd = ioctl(vcpu_fd, KVM_CREATE_VM, 0);
int vcpu_fd = ioctl(vm_fd, KVM_CREATE_VCPU, 0);

struct kvm_run *run = mmap(vcpu_fd, 0, 4096, PROT_READ|PROT_WRITE, 0);

while (1) {
    ioctl(vcpu_fd, KVM_RUN, 0);  // ← 触发 vCPU 执行
    switch (run->exit_reason) {
    case KVM_EXIT_IO:        // 客户机执行 IN/OUT 指令
    case KVM_EXIT_MMIO:      // 客户机访问 MMIO
    case KVM_EXIT_HYPERCALL: // 客户机执行 VMMCALL
    case KVM_EXIT_HLT:      // HLT 指令（客户机空闲）
    }
}
```

### 4.2 vcpu_load() / vcpu_put() —— 宿主线程绑定

```c
// kvm_main.c:164 — vCPU 切换到当前 CPU
void vcpu_load(struct kvm_vcpu *vcpu)
{
    int cpu = get_cpu();
    __this_cpu_write(kvm_running_vcpu, vcpu);          // 每个 CPU 一个"当前运行的 vCPU"
    preempt_notifier_register(&vcpu->preempt_notifier);
    kvm_arch_vcpu_load(vcpu, cpu);                    // arch 特定初始化（如加载 FPU）
    put_cpu();
}

// kvm_main.c:175 — vCPU 切出
void vcpu_put(struct kvm_vcpu *vcpu)
{
    preempt_disable();
    kvm_arch_vcpu_put(vcpu);
    preempt_notifier_unregister(&vcpu->preempt_notifier);
    __this_cpu_write(kvm_running_vcpu, NULL);
    preempt_enable();
}
```

### 4.3 kvm_arch_vcpu_ioctl_run()

```c
// arch/x86/kvm/x86.c:12014
int kvm_arch_vcpu_ioctl_run(struct kvm_vcpu *vcpu)
{
    vcpu_load(vcpu);                  // ★ 绑定到当前 CPU
    kvm_sigset_activate(vcpu);
    kvm_load_guest_fpu(vcpu);         // 加载 guest FPU 状态

    if (vcpu->arch.mp_state == KVM_MP_STATE_UNINITIALIZED) {
        kvm_vcpu_block(vcpu);         // 等待 init 信号
        goto out;
    }

    if (!vcpu->wants_to_run) {
        r = -EINTR;
        goto out;
    }

    r = kvm_x86_vcpu_pre_run(vcpu);   // 前置检查（如中断窗口）
    if (r <= 0) goto out;

    r = vcpu_run(vcpu);               // ★ ★ ★ 进入 guest 执行

out:
    kvm_put_guest_fpu(vcpu);
    vcpu_put(vcpu);                   // ★ 从当前 CPU 解绑
    return r;
}
```

### 4.4 vcpu_run() —— vCPU 主循环

```c
// arch/x86/kvm/x86.c:11750
static int vcpu_run(struct kvm_vcpu *vcpu)
{
    vcpu->run->exit_reason = KVM_EXIT_UNKNOWN;

    for (;;) {
        if (kvm_vcpu_running(vcpu)) {
            r = vcpu_enter_guest(vcpu);  // ★ 进入 guest 执行
        } else {
            r = vcpu_block(vcpu);        // vCPU 被阻塞（HLT / 等待事件）
        }

        if (r <= 0) break;  // 退出条件

        // ★ VM-Exit 后的处理 ★
        if (kvm_xen_has_pending_events(vcpu))
            kvm_xen_inject_pending_events(vcpu);

        if (kvm_cpu_has_pending_timer(vcpu))
            kvm_inject_pending_timer_irqs(vcpu);  // 注入时钟中断

        if (dm_request_for_irq_injection(vcpu) &&
            kvm_vcpu_ready_for_interrupt_injection(vcpu)) {
            vcpu->run->exit_reason = KVM_EXIT_IRQ_WINDOW_OPEN;
            ++vcpu->stat.request_irq_exits;
            break;
        }

        if (__xfer_to_guest_mode_work_pending())
            kvm_xfer_to_guest_mode_handle_work(vcpu);
    }
    return r;
}
```

### 4.5 vcpu_enter_guest() —— VM-Entry 的准备与执行

```c
// arch/x86/kvm/x86.c:11167
static int vcpu_enter_guest(struct kvm_vcpu *vcpu)
{
    // 1. 处理 KVM_REQ_* 请求（中断注入、TLB flush 等）
    if (kvm_request_pending(vcpu)) {
        if (kvm_check_request(KVM_REQ_EVENT, vcpu)) {
            // 注入中断/异常
            r = kvm_check_and_inject_events(vcpu, &req_immediate_exit);
        }
        if (kvm_check_request(KVM_REQ_TLB_FLUSH, vcpu))
            kvm_vcpu_flush_tlb_all(vcpu);
        if (kvm_check_request(KVM_REQ_APF_HALT, vcpu))
            vcpu->arch.apf.halted = true;
        // ... 更多请求处理
    }

    // 2. 处理中断窗口请求
    if (dm_request_for_irq_injection(vcpu) && kvm_cpu_accept_dm_intr(vcpu))
        req_int_win = true;

    // 3. 重新加载 MMU 页表
    r = kvm_mmu_reload(vcpu);
    if (unlikely(r)) goto cancel_injection;

    // 4. 进入 guest 前的最后检查
    if (kvm_lapic_enabled(vcpu))
        kvm_x86_call(sync_pir_to_irr)(vcpu);  // 同步 posted interrupt

    // 5. ★★★ VM-Entry ★★★
    //    kvm_x86_call(vcpu_run) = vmx_vcpu_run() 或 svm_vcpu_run()
    exit_fastpath = kvm_x86_call(vcpu_run)(vcpu, run_flags);

    // 6. ★★★ VM-Exit 发生 ★★★
    //    控制权回到宿主机
    kvm_x86_call(handle_exit_irqoff)(vcpu);  // irq disabled 期间处理

    // 7. 中断上下文处理
    local_irq_disable();
    ++vcpu->stat.exits;
    local_irq_enable();

    return 0;  // 返回到 vcpu_run() 循环
}
```

### 4.6 VM-Exit 处理

```c
// arch/x86/kvm/vmx/vmx.c:6828
int vmx_handle_exit(struct kvm_vcpu *vcpu, fastpath_t exit_fastpath)
{
    // 读取 VM-Exit 原因
    u32 exit_reason = vmcs_read32(VM_EXIT_REASON);

    switch (exit_reason) {
    case EXIT_REASON_HLT:           // 客户机执行 HLT
    case EXIT_REASON_IO_INSTRUCTION: // IN/OUT 指令
    case EXIT_REASON_MMIO_READ:
    case EXIT_REASON_MMIO_WRITE:
    case EXIT_REASON_EPT_VIOLATION: // ★ EPT 页错误（客户机访问未映射的 GPA）
    case EXIT_REASON_VMCALL:        // ★ hypercall (VMMCALL)
    case EXIT_REASON_EXTERNAL_INTERRUPT:  // 外部中断
    }
}
```

### 4.7 vCPU 运行→VM-Exit→中断注入完整流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                        用户态 QEMU / Libvirt                    │
│                     ioctl(vcpu_fd, KVM_RUN, 0)                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  kvm_vcpu_ioctl(KVM_RUN)                                        │
│    → kvm_arch_vcpu_ioctl_run(vcpu)                              │
│        → vcpu_load(vcpu)         [绑定到当前 CPU]                 │
│        → vcpu_run(vcpu)          [进入主循环]                    │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  vcpu_enter_guest(vcpu)                                         │
│    ├─ 处理 KVM_REQ_EVENT → kvm_check_and_inject_events()        │
│    │     ├─ kvm_inject_exception()      [异常注入]              │
│    │     └─ kvm_x86_call(inject_irq)    [中断注入]              │
│    ├─ kvm_mmu_reload()               [重新加载 EPT]              │
│    ├─ sync_pir_to_irr()               [同步 posted interrupt]   │
│    └─ kvm_x86_call(vcpu_run)()        [★★★ VM-Entry ★★★]        │
└─────────────────────────────────────────────────────────────────┘
                                │
                     ┌──────────┴──────────┐
                     │   VM-Entry 成功      │
                     │  客户机代码执行中...   │
                     └──────────┬──────────┘
                               │
                    (硬件触发 VM-Exit)
                               │
                     ┌──────────┴──────────┐
                     │    VM-Exit 发生     │
                     │  退出到宿主机内核    │
                     └──────────┬──────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  handle_exit_irqoff(vcpu)    [irq disabled 状态下快速处理]       │
│    ├─ 读取 VM_EXIT_REASON                                        │
│    ├─ 如果是外部中断 → 更新 vCPU 状态                             │
│    └─ 如果是 EPT_VIOLATION → 调用 kvm_mmu_page_fault()            │
└─────────────────────────────────────────────────────────────────┘
                                │
┌─────────────────────────────────────────────────────────────────┐
│  local_irq_enable()  [打开中断，统计 guest 时间]                  │
│                                │
│  返回 vcpu_run() 循环:                                          │
│    ├─ kvm_xen_has_pending_events() → kvm_xen_inject_pending()    │
│    ├─ kvm_cpu_has_pending_timer()  → kvm_inject_pending_timer_irqs()
│    ├─ dm_request_for_irq_injection()                            │
│    └─ 再次调用 vcpu_enter_guest() 或 退出到用户态                 │
└─────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    │   需要退出到用户态     │
                    │   exit_reason 非 0     │
                    └───────────┬───────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  vcpu_run() 返回 → kvm_arch_vcpu_ioctl_run()                    │
│    → vcpu_put(vcpu)          [从当前 CPU 解绑]                   │
│    → 返回到用户态 ioctl()                                        │
│                                                                 │
│  用户态看到 vcpu->run->exit_reason:                             │
│    KVM_EXIT_IO        → IN/OUT 指令处理                          │
│    KVM_EXIT_MMIO      → MMIO 访问处理                           │
│    KVM_EXIT_HYPERCALL → hypercall 处理（KVM_HC_*）               │
│    KVM_EXIT_HLT       → guest 空闲（HLT）                       │
│    KVM_EXIT_IRQ_WINDOW_OPEN → 需要打开 IRQ 窗口                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 五、内存虚拟化 —— gpa_to_hva 与 mmu_notifier

### 5.1 客户机物理地址 → 宿主虚拟地址的映射体系

KVM 的内存虚拟化采用两级映射：

```
客户机虚拟地址 (GVA) → 客户机物理地址 (GPA) → 宿主虚拟地址 (HVA)
      (客户机页表)          (EPT/NPT 页表)        (宿主页表)
```

用户态通过 `KVM_SET_USER_MEMORY_REGION` 设置客户机物理地址区间与宿主进程的映射：

```c
// kvm_main.c:2140
static int kvm_vm_ioctl_set_memory_region(struct kvm *kvm, struct kvm_memory_slot *slot)
{
    // 更新 kvm->memslots[as_id]（addr space id）
    // 每个 slot 将 guest physical address range 映射到 user virtual address
}
```

### 5.2 gfn_to_hva() —— GPA → HVA 的转换

```c
// kvm_main.c:2741
unsigned long gfn_to_hva(struct kvm *kvm, gfn_t gfn)
{
    return gfn_to_hva_many(gfn_to_memslot(kvm, gfn), gfn, NULL);
}

// kvm_main.c:2713
static unsigned long __gfn_to_hva_many(const struct kvm_memory_slot *slot, gfn_t gfn, ...)
{
    if (!slot || slot->flags & KVM_MEMSLOT_INVALID)
        return KVM_HVA_ERR_BAD;

    // 检查 gfn 是否在 slot 范围内
    return slot->userspace_addr + (gfn - slot->base_gfn) * PAGE_SIZE;
}
```

路径链：
```
gfn_to_hva(kvm, gfn)
  ├→ gfn_to_memslot(kvm, gfn)       // 查找包含 gfn 的 memory slot
  └→ __gfn_to_hva_many(slot, gfn)    // slot->userspace_addr + offset
                                      // = host virtual address
```

### 5.3 kvm_read_guest() / kvm_write_guest() 流程

```c
// kvm_main.c:3217
int kvm_read_guest(struct kvm *kvm, gpa_t gpa, void *data, unsigned long len)
{
    gfn_t gfn = gpa >> PAGE_SHIFT;
    int offset = gpa & (PAGE_SIZE - 1);

    while (len > 0) {
        unsigned long hva = gfn_to_hva(kvm, gfn);  // GPA → HVA
        // copy_to_user() 从 hva 读取数据到 guest 内存区域
        copy_to_user(data, (void __user *)hva + offset, seg);
    }
}

int kvm_write_guest_page(struct kvm *kvm, gfn_t gfn, const void *data, int offset, int len)
{
    unsigned long hva = gfn_to_hva_memslot(memslot, gfn);
    // copy_from_user() 从用户态 HVA 写入
}
```

### 5.4 mmu_notifier —— 宿主内存变化的监听

当用户态进程通过 `munmap()` 或 `madvise()` 释放/移动 guest 内存时，KVM 必须同步更新 EPT 页表，否则客户机可能访问已释放的物理页面。

KVM 通过 Linux 的 `mmu_notifier` 机制监听宿主内存变化：

```c
// kvm_main.c:887
static int kvm_init_mmu_notifier(struct kvm *kvm)
{
    kvm->mmu_notifier.ops = &kvm_mmu_notifier_ops;
    return mmu_notifier_register(&kvm->mmu_notifier, kvm->mm);  // 注册到创建者进程
}

// kvm_main.c:878
static const struct mmu_notifier_ops kvm_mmu_notifier_ops = {
    .invalidate_range_start   = kvm_mmu_notifier_invalidate_range_start,
    .invalidate_range_end     = kvm_mmu_notifier_invalidate_range_end,
    .clear_flush_young        = kvm_mmu_notifier_clear_flush_young,
    .clear_young              = kvm_mmu_notifier_clear_young,
    .test_young              = kvm_mmu_notifier_test_young,
    .release                 = kvm_mmu_notifier_release,
};

// kvm_main.c:721 — 当宿主内存被 invalidate 时
static int kvm_mmu_notifier_invalidate_range_start(struct mmu_notifier *mn, ...)
{
    const struct kvm_mmu_notifier_range range = {
        .start  = range->start,
        .end    = range->end,
        .handler   = kvm_unmap_gfn_range,    // 清除 EPT 映射
        .on_lock  = NULL,
        .flush_on_ret = true,
        .may_block = mmu_notifier_range_blockable(range),
    };
    kvm_handle_hva_range(kvm, &range);
}
```

**mmu_notifier 触发时机：**
- 用户态调用 `munmap()` → 释放的虚拟地址范围触发 `invalidate_range_start`
- 用户态调用 `madvise(MADV_DONTNEED / MADV_REMOVE)` → 部分页失效
- 用户态调用 `mremap()` → 虚拟地址迁移

**kvm_unmap_gfn_range() 会：**
1. 找到与 [start, end] 相交的所有 memory slot
2. 清除这些 gfn 对应的 EPT 页表项（`kvm_mmu_flush_tlb`）
3. 如果页被访问过，标记为 `KVM_MEMSLOT_DIRTY_LOG` 供迁移使用

### 5.5 EPT 页错误 (EPT_VIOLATION)

当客户机访问一个 GPA，但 EPT 页表中没有对应映射时，触发 VM-Exit：

```c
// arch/x86/kvm/vmx/vmx.c
static int __vmx_handle_exit(struct kvm_vcpu *vcpu, fastpath_t exit_fastpath)
{
    exit_reason = vmcs_read32(VM_EXIT_REASON);
    if (exit_reason == EXIT_REASON_EPT_VIOLATION) {
        // VM-Exit 信息中包含失败的客户机物理地址和访问类型（R/W/X）
        gpa = vmcs_read64(GUEST_PHYSICAL_ADDRESS);
        // 调用 MMU 页错误处理
        r = kvm_mmu_page_fault(vcpu, gpa, error_code);
    }
}
```

---

## 六、中断虚拟化 —— LAPIC + IOAPIC

### 6.1 虚拟 LAPIC (Local APIC)

每个 vCPU 有一个虚拟 LAPIC，模拟 Intel 8259A 的本地中断控制器功能：

```c
// arch/x86/kvm/lapic.c
struct kvm_lapic {
    struct kvm_vcpu *vcpu;
    page->virtual;      // 映射到 guest MMIO 空间（通常 0xFEE00000）
    union {
        struct kvm_lapic_regs regs;
        u8 padding[LAPIC_PAGE_SIZE];
    };
    // 定时器相关
    struct hrtimer timer;
    // ISR / TMR / RR 寄存器（中断状态）
}
```

LAPIC 状态通过 `kvm_run` 共享给用户态：
```c
struct kvm_run {
    // ...
    __u8 pending_ioapic_eoi;       // 待处理的 EOI
    __u32 ready_for_interrupt_injection;
};
```

### 6.2 中断注入流程

**注入点1：KVM_REQ_EVENT 请求**

```c
// arch/x86/kvm/x86.c:11347
r = kvm_check_and_inject_events(vcpu, &req_immediate_exit);

// arch/x86/kvm/x86.c:10688
static int kvm_check_and_inject_events(struct kvm_vcpu *vcpu, bool *req_immediate_exit)
{
    if (vcpu->arch.exception.injected)
        kvm_inject_exception(vcpu);        // 注入异常
    else if (kvm_is_exception_pending(vcpu))
        ; // 处理 pending 异常
    else if (vcpu->arch.nmi_injected)
        kvm_x86_call(inject_nmi)(vcpu);     // 注入 NMI
    else if (vcpu->arch.interrupt.injected)
        kvm_x86_call(inject_irq)(vcpu, true);  // ★ 注入外部中断
}
```

**注入点2：kvm_inject_pending_timer_irqs()**

```c
// arch/x86/kvm/x86.c:11778
if (kvm_cpu_has_pending_timer(vcpu))
    kvm_inject_pending_timer_irqs(vcpu);

// arch/x86/kvm/lapic.c
void kvm_inject_apic_timer_irqs(struct kvm_vcpu *vcpu)
{
    if (apic_lvtt_tscdeadline_mode(vcpu->arch.apic))
        kvm_inject_lvt0(vcpu);  // 或者注入时钟向量
}
```

**注入点3：IOAPIC 中断路由**

```c
// arch/x86/kvm/ioapic.c:187
static int ioapic_set_irq(struct kvm_ioapic *ioapic, unsigned int irq, ...)
{
    // 根据 RTe（Redirection Table Entry）计算目标 vCPU
    // 调用 kvm_apic_set_irq(dest_vcpu, &irq, NULL)
}

// arch/x86/kvm/lapic.c:829
int kvm_apic_set_irq(struct kvm_vcpu *vcpu, struct kvm_lapic_irq *irq, int *r)
{
    // 计算目标向量，写入 IRR（Interrupt Request Register）
    // 如果目标 vCPU 正运行，通过 posted interrupt 机制直接注入
}
```

### 6.3 Posted Interrupt 机制

当 vCPU 正在运行时（IN_GUEST_MODE），外部中断不能直接注入，因为 CPU 处于非中断状态。KVM 使用 Posted Interrupt：

1. vCPU 运行前，`vcpu_enter_guest()` 调用 `sync_pir_to_irr()`
2. 如果有 pending posted interrupt，设置 vCPU 的 APICv 状态
3. VM-Entry 时硬件自动检查 PID（Posted Interrupt Descriptor）
4. 中断被直接投递到 vCPU，无需 VM-Exit

### 6.4 IOAPIC 路由建立

```c
// 用户态通过 KVM_SET_GSI_ROUTING 设置
// kvm_main.c:5298
case KVM_SET_GSI_ROUTING: {
    struct kvm_irq_routing routing;
    // 复制用户态的路由表
    r = kvm_set_irq_routing(kvm, entries, routing.nr, ...);
}
```

---

## 七、Hypercall 机制 —— 从 guest 到 host

### 7.1 KVM Hypercall 入口：VMMCALL / VMCALL

客户机代码执行 `vmcall` 或 `vmrun` 指令，触发 VM-Exit，reason = `EXIT_REASON_VMCALL`。

```c
// arch/x86/kvm/vmx/vmx.c:6309
[EXIT_REASON_VMCALL] = kvm_emulate_hypercall,
```

### 7.2 kvm_emulate_hypercall()

```c
// arch/x86/kvm/x86.c
int kvm_emulate_hypercall(struct kvm_vcpu *vcpu)
{
    if (kvm_xen_hypercall_enabled(vcpu->kvm))
        return kvm_xen_hypercall(vcpu);    // Xen 半虚拟化 hypercall
    if (kvm_hv_hypercall_enabled(vcpu))
        return kvm_hv_hypercall(vcpu);      // Hyper-V hypercall

    // ★ 标准 KVM hypercall
    return __kvm_emulate_hypercall(vcpu, kvm_x86_call(get_cpl)(vcpu),
                                   complete_hypercall_exit);
}
```

### 7.3 ____kvm_emulate_hypercall()

```c
// arch/x86/kvm/x86.c — 按 hypercall 号分发
switch (nr) {
case KVM_HC_VAPIC_POLL_IRQ:      // 1 — 轮询虚拟中断
    ret = 0;
    break;

case KVM_HC_KICK_CPU:            // 5 — 唤醒另一个 vCPU
    kvm_pv_kick_cpu_op(vcpu->kvm, a1);
    kvm_sched_yield(vcpu, a1);
    ret = 0;
    break;

case KVM_HC_CLOCK_PAIRING:       // 9 — 同步时钟
    ret = kvm_pv_clock_pairing(vcpu, a0, a1);
    break;

case KVM_HC_SEND_IPI:            // 10 — 发送 IPI
    ret = kvm_pv_send_ipi(vcpu->kvm, a0, a1, a2, a3, op_64_bit);
    break;

case KVM_HC_SCHED_YIELD:         // 11 — 让出调度
    kvm_sched_yield(vcpu, a0);
    ret = 0;
    break;

case KVM_HC_MAP_GPA_RANGE: {     // 12 — ★ 映射 GPA（SEV/TDX）
    ret = -KVM_ENOSYS;
    if (!user_exit_on_hypercall(vcpu->kvm, KVM_HC_MAP_GPA_RANGE))
        break;

    // 填写 vcpu->run->hypercall 让用户态处理
    vcpu->run->exit_reason = KVM_EXIT_HYPERCALL;
    vcpu->run->hypercall.nr = KVM_HC_MAP_GPA_RANGE;
    vcpu->run->hypercall.args[0] = gpa;
    vcpu->run->hypercall.args[1] = npages;
    vcpu->run->hypercall.args[2] = attrs;
    return 0;  // 退出到用户态
}
}
```

### 7.4 Hypercall 两类处理模式

| 类型 | 处理方式 | 示例 |
|------|---------|------|
| **内核直接处理** | KVM 直接执行（如 KICK_CPU、SCHED_YIELD） | 不退出到用户态 |
| **需要用户态介入** | 标记 `KVM_EXIT_HYPERCALL`，等待 QEMU 处理 | KVM_HC_MAP_GPA_RANGE（SEV/TDX）|

### 7.5 KVM_HC_* 定义（来自 kvm_para.h）

```c
// include/uapi/linux/kvm_para.h
#define KVM_HC_VAPIC_POLL_IRQ        1
#define KVM_HC_MMU_OP                2
#define KVM_HC_FEATURES              3
#define KVM_HC_PPC_MAP_MAGIC_PAGE    4
#define KVM_HC_KICK_CPU              5
#define KVM_HC_MIPS_GET_CLOCK_FREQ   6
#define KVM_HC_MIPS_EXIT_VM          7
#define KVM_HC_MIPS_CONSOLE_OUTPUT   8
#define KVM_HC_CLOCK_PAIRING         9
#define KVM_HC_SEND_IPI             10
#define KVM_HC_SCHED_YIELD          11
#define KVM_HC_MAP_GPA_RANGE        12  // SEV/TDX 私有内存映射
```

---

## 八、/dev/kvm 注册 —— 完整 ioctl 路由图

```
用户态 open("/dev/kvm")
  │
  ├─ miscdevice 注册 → /dev/kvm (主设备号 10, 动态 minor)
  │
  └─ fd (文件描述符)
        │
        ▼
  kvm_dev_ioctl(file, ioctl, arg)          [处理全局 ioctl]
  ┌───────────────────────────────────────────────────────┐
  │  KVM_GET_API_VERSION     → 返回 12                    │
  │  KVM_CHECK_EXTENSION     → 查询 KVM_CAP_* 能力        │
  │  KVM_CREATE_VM           → kvm_dev_ioctl_create_vm()   │
  │       ├→ kvm_create_vm()                             │
  │       ├→ anon_inode_getfile("kvm-vm", &kvm_vm_fops)  │
  │       └→ 返回 VM fd（unlocked_ioctl = kvm_vm_ioctl） │
  └───────────────────────────────────────────────────────┘
        │
        ▼ VM fd
  kvm_vm_ioctl(file, ioctl, arg)           [处理 VM 级 ioctl]
  ┌───────────────────────────────────────────────────────┐
  │  KVM_CREATE_VCPU      → kvm_vm_ioctl_create_vcpu()    │
  │       ├→ kvm_arch_vcpu_create()                       │
  │       ├→ anon_inode_getfile("kvm-vcpu", &kvm_vcpu_fops)
  │       └→ mmap(vcpu_run)                              │
  │  KVM_SET_USER_MEMORY_REGION → kvm_vm_ioctl_set_memory_region()
  │  KVM_SET_MEMORY_ATTRIBUTES  → kvm_vm_ioctl_set_mem_attributes()
  │  KVM_GET_DIRTY_LOG    → kvm_vm_ioctl_get_dirty_log() │
  │  KVM_SET_GSI_ROUTING  → kvm_set_irq_routing()        │
  │  KVM_CREATE_IRQCHIP   → kvm_vm_ioctl_create_irqchip() │
  └───────────────────────────────────────────────────────┘
        │
        ▼ vCPU fd
  kvm_vcpu_ioctl(file, ioctl, arg)        [处理 vCPU 级 ioctl]
  ┌───────────────────────────────────────────────────────┐
  │  KVM_RUN             → kvm_arch_vcpu_ioctl_run()       │
  │       ├→ vcpu_load()                                   │
  │       ├→ vcpu_run()                                    │
  │       │     └→ vcpu_enter_guest()                     │
  │       │           └→ kvm_x86_call(vcpu_run)()          │
  │       │               (vmx_vcpu_run / svm_vcpu_run)    │
  │       └→ vcpu_put()                                   │
  │  KVM_GET_REGS / KVM_SET_REGS                           │
  │  KVM_GET_SREGS / KVM_SET_SREGS                         │
  │  KVM_GET_MP_STATE / KVM_SET_MP_STATE                   │
  │  KVM_GET_LAPIC / KVM_SET_LAPIC                         │
  │  KVM_INJECT_SET_IRQ / KVM_INJECT_NMI                   │
  └───────────────────────────────────────────────────────┘
```

---

## 九、核心数据结构关系图

```
struct kvm (VM)
  ├── mm = current->mm          ← 与用户态进程绑定
  ├── memslots[]               ← GPA → HVA 映射表
  ├── vcpu_array (xarray)      ← 所有 vCPU
  │     └── struct kvm_vcpu
  │           ├── run          ← struct kvm_run（用户共享）
  │           ├── arch        ← 寄存器状态
  │           ├── apic        ← 虚拟 LAPIC
  │           └── preempt_notifier
  ├── mmu_notifier             ← 监听宿主内存变化
  ├── buses[KVM_NR_BUSES]      ← PIO/MMIO 设备总线
  └── arch                     ← 架构特定数据
        ├── vmx(如 VMXON area)
        └── irq_routing

struct kvm_run（mmap 到用户空间）
  ├── exit_reason              ← VM-Exit 原因
  ├── mmio                     ← MMIO 访问信息
  ├── io                       ← PIO 访问信息
  ├── hypercall                ← Hypercall 参数
  └── eoi                      ← EOI 信息
```

---

## 十、关键源码位置索引

| 功能 | 文件 | 行号 |
|------|------|------|
| /dev/kvm 注册 | kvm_main.c | 5557, 5563 |
| KVM_CREATE_VM | kvm_main.c | 5479, 1098 |
| kvm->mm 绑定 | kvm_main.c | 1108-1109 |
| mmu_notifier 注册 | kvm_main.c | 887-891 |
| KVM_CREATE_VCPU | kvm_main.c | 4151 |
| KVM_RUN ioctl | kvm_main.c | 4405, 4440 |
| vcpu_load/put | kvm_main.c | 164, 175 |
| kvm_arch_vcpu_ioctl_run | x86.c | 12014 |
| vcpu_run | x86.c | 11750 |
| vcpu_enter_guest | x86.c | 11167 |
| kvm_check_and_inject_events | x86.c | 10688 |
| VM-Entry (VMX) | vmx/vmx.c | 11481 |
| VM-Exit 处理 | vmx/vmx.c | 6672, 6828 |
| kvm_emulate_hypercall | x86.c | 10525 |
| ____kvm_emulate_hypercall | x86.c | 10459 |
| gfn_to_hva | kvm_main.c | 2741 |
| kvm_read_guest | kvm_main.c | 3217 |
| mmu_notifier invalidate | kvm_main.c | 721 |
| kvm_apic_set_irq | lapic.c | 829 |
| ioapic_set_irq | ioapic.c | 187 |
| KVM_HC_* 定义 | kvm_para.h | 21-32 |