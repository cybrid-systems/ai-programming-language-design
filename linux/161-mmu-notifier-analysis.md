# 161-mmu_notifier — MMU通知器深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`mm/mmu_notifier.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**MMU Notifier** 是 Linux 内核的内存管理通知机制，当一个进程的页表发生变化时（如 KVM 虚拟化中的客户机页表更新、进程迁移、内存回收），通知其他内核子系统（如 RDMA、设备驱动）刷新相关的 TLB 或 IOVA 映射。

---

## 1. 为什么需要 MMU Notifier

```
KVM 虚拟化场景：

VM (guest) write to GPA 0x1000
  → VM exits to host KVM
  → KVM updates guest page table (EPT/NPT)
  → 但 RDMA 设备的 IOVA 映射还指向旧的 GPA
  → RDMA 设备需要知道 GPA 映射变了 → mmu_notifier

或者：

进程 A 的内存被移动（migration/CMA）
  → 物理页地址变了
  → 设备驱动的 DMA 地址映射需要更新
  → mmu_notifier
```

---

## 2. 核心数据结构

### 2.1 struct mmu_notifier — 通知器

```c
// include/linux/mmu_notifier.h — mmu_notifier
struct mmu_notifier {
    struct hlist_node       mn_node;           // 哈希表节点
    const struct mmu_notifier_ops *ops;       // 操作函数表
    struct mm_struct       *mn_mm;             // 关联的 mm

    // 链表
    struct list_head        mn_notifications; // 当前正在通知的事件
};
```

### 2.2 struct mmu_notifier_ops — 操作函数表

```c
// include/linux/mmu_notifier.h — mmu_notifier_ops
struct mmu_notifier_ops {
    // 页面即将失效
    void  (*invalidate_range_start)(struct mmu_notifier *mn,
                                     const struct mmu_notifier_range *range);
    void  (*invalidate_range_end)(struct mmu_notifier *mn,
                                   const struct mmu_notifier_range *range);

    // 单页失效
    int   (*invalidate_page)(struct mmu_notifier *mn,
                               struct vm_area_struct *vma,
                               unsigned long address);

    // TLB 刷新
    void  (*test_clear_young)(struct mmu_notifier *mn,
                               struct vm_area_struct *vma,
                               unsigned long address);
    int   (*clear_flush_young)(struct mmu_notifier *mn,
                                 struct vm_area_struct *vma,
                                 unsigned long start,
                                 unsigned long end);

    // 页面迁移
    void  (*change_pte)(struct mmu_notifier *mn,
                          struct vm_area_struct *vma,
                          unsigned long address,
                          pte_t old_pte,
                          pte_t new_pte);

    // 页面移出（迁移/回收）
    int   (*migrate_notifier)(struct mmu_notifier *mn,
                                struct page *page);
};
```

### 2.3 struct mmu_notifier_range — 范围

```c
// include/linux/mmu_notifier.h — mmu_notifier_range
struct mmu_notifier_range {
    struct mmu_notifier *notifier;              // 触发通知的 notifier
    unsigned long       start;                   // 起始地址
    unsigned long       end;                     // 结束地址
    unsigned int        event;                   // MMU_NOTIFY_* 事件
    bool                blocked;                  // 是否阻塞
};
```

---

## 3. 事件类型

```c
// include/linux/mmu_notifier.h — 事件类型
enum mmu_notifier_event {
    MMU_NOTIFY_UNMAP = 0,       // 页面解除映射
    MMU_NOTIFY_CLEAR = 1,       // 页表项清除
    MMU_NOTIFY_PROTECTION = 2, // 保护变化
    MMU_NOTIFY_EXCLUSIVE = 3,  // 独占
    MMU_NOTIFY_EXCLUSIVE_ALL = 4, // 全部独占
};
```

---

## 4. 注册/注销

### 4.1 mmu_notifier_register

```c
// mm/mmu_notifier.c — mmu_notifier_register
int mmu_notifier_register(struct mmu_notifier *mn, struct mm_struct *mm)
{
    int ret;

    mn->mn_mm = mm;

    // 加入 mm 的 notifier 链表
    down_write(&mm->mmap_lock);
    ret = __mmu_notifier_register(mn, mm);
    up_write(&mm->mmap_lock);

    return ret;
}
```

---

## 5. 触发通知

### 5.1 mmu_notifier_invalidate_range_start

```c
// mm/mmu_notifier.c — mmu_notifier_invalidate_range_start
void mmu_notifier_invalidate_range_start(struct mmu_notifier_range *range)
{
    struct mmu_notifier *mn;
    int id;

    // 获取 notifier 序列号（用于检测并发）
    id = srcu_read_lock(&mmu_notifier_srcu);

    // 遍历所有注册的 notifier
    hlist_for_each_entry_srcu(mn, &mn->mn_node, hlist) {
        if (mn->ops->invalidate_range_start)
            mn->ops->invalidate_range_start(mn, range);
    }

    srcu_read_unlock(&mmu_notifier_srcu, id);
}
```

---

## 6. KVM 中的使用

### 6.1 kvm_mmu_notifier — KVM 实现

```c
// arch/x86/kvm/mmu.c — KVM MMU notifier
static const struct mmu_notifier_ops kvm_mmu_notifier_ops = {
    .invalidate_range_start = kvm_unmap_hva_range,
    .invalidate_range_end   = kvm->memslots,
    .clear_flush_young      = kvm_clear_young,
    .change_pte              = kvm_pt_update,
};

// KVM 调用 mmu_notifier_register(&kvm->mmu_notifier, current->mm)
```

---

## 7. 使用场景

```
MMU Notifier 的主要用户：

1. KVM（虚拟化）：
   客户机页表变化 → 通知 KVM 刷新 EPT/NPT
   GPA → HPA 映射变化 → 设备 DMA 地址需要更新

2. RDMA（远程直接内存访问）：
   进程的物理页被迁移 → RDMA 的 IOVA 映射需要更新

3. GPU（图形处理）：
   进程的页被移动 → GPU 的分页表需要刷新

4. IOMMU：
   进程的页被迁移 → IOMMU 的 IOVA 映射需要更新

5. VFIO：
   设备访问用户内存 → 设备需要知道内存位置变化
```

---

## 8. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `mm/mmu_notifier.c` | `mmu_notifier_register`、`__mmu_notifier_register` |
| `mm/mmu_notifier.c` | `mmu_notifier_invalidate_range_start`、`mmu_notifier_invalidate_range_end` |
| `include/linux/mmu_notifier.h` | `struct mmu_notifier`、`struct mmu_notifier_ops` |

---

## 9. 西游记类比

**MMU Notifier** 就像"天庭的地址变更通知处"——

> 天庭的地址（物理页）是动态分配的，当某个地址的住户变了（物理页被迁移/回收），天庭的地址簿（TLB/IOMMU）需要更新。MMU Notifier 就是通知各个相关部门的系统——KVM 的客户机页表（EPT/NPT）、RDMA 设备的 DMA 映射、GPU 的分页表等。通知处（mmu_notifier）登记了所有需要知道地址变更的部门（ops）。当地址变更时，通知处依次通知各部门："各位注意，某号房间的住户变了，请更新你们的记录。"各部门收到通知后，在自己的系统里做相应的更新。这就是为什么 RDMA 和 KVM 能正确地访问进程的内存——它们通过 MMU Notifier 实时跟踪地址变化。

---

## 10. 关联文章

- **KVM**（相关）：KVM 使用 mmu_notifier 跟踪客户机内存
- **userfaultfd**（article 51）：另一种页面故障处理机制
- **mmap**（article 88）：页表变化触发 mmu_notifier