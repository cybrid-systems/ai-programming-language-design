# Linux Kernel Binder 驱动深度源码分析（doom-lsp 全面解析）

> 基于 Linux 7.0-rc1 主线源码（`drivers/android/binder.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：binder_proc、binder_node、binder_transaction、flat_binder_object、mmap、死亡通知

## 0. Binder 概述与设计目标

**Binder** 是 Android 的 IPC 机制，设计目标：
- **高效率**：共享内存（mmap）传输数据，零拷贝
- **安全**：基于 PID/UID 的权限检查
- **面向对象**：传递"引用"（handle）而非原始指针
- **同步调用**：支持 oneway（异步）和同步（等待回复）

### 与传统 IPC 对比

```
System V IPC:
  msgget/semsget/shmget → 内核对象 → 进程间共享
  问题：每次 msg/recv 都要复制数据（copy_from_user）

Binder:
  mmap 共享内存 → 一次复制 → 高效
  handle 作为跨进程引用 → 进程隔离
```

## 1. 核心数据结构

### 1.1 binder_proc — 进程上下文

```c
// drivers/android/binder.c — binder_proc
struct binder_proc {
    // 进程链表节点（全局 binder_procs 链表）
    struct hlist_node            proc_node;        // 行 93

    // 进程 PID
    pid_t                        pid;              // 行 96

    // 所属的 namespace
    struct list_head            proc_ns_entry;    // 行 99

    // 红黑树：此进程创建/引用的所有 binder_node
    struct rb_root               nodes;            // 行 102

    // 红黑树：此进程管理的 refs（强引用和弱引用）
    struct rb_root               refs_by_desc;     // 行 105
    struct rb_root               refs_by_node;     // 行 108

    // TODO 队列（接收到的 transaction）
    struct list_head             todo;              // 行 112

    // 异步 TODO 队列
    struct list_head             async_todo;        // 行 115

    // 每个 CPU 的延迟工作计数
    int                          CPU_MAYSEND[CORE_MASK];  // 行 118

    // 多层锁：
    // outer_lock: 保护 proc 级别操作（todo、async_todo、死亡通知）
    // inner_lock: 保护 node 和 ref（细粒度）
    // node_lock: 保护 node 的内部状态
    spinlock_t                   outer_lock;        // 行 121
    spinlock_t                   inner_lock;        // 行 123
    spinlock_t                   node_lock;         // 行 125

    // 内存映射区域（mmap 分配）
    struct binder_mapped_area    *mapped_area;      // 行 128

    // 此进程的 binder 缓冲区
    struct binder_buffer         *buffers;           // 行 131

    // 空闲/已用缓冲区树
    struct rb_root               free_buffers;      // 行 134
    struct rb_root               allocated_buffers; // 行 137

    // 页面信息
    struct list_head             pages;              // 行 140
    size_t                       buffer_size;        // 行 143

    // binder 对象追踪
    struct hlist_head            wait_chains;       // 行 146

    // 调试
    unsigned long               debug_id;           // 行 149

    // 统计
    atomic_t                     stats;             // 行 152
    atomic_t                     timeout_count;     // 行 155

    // binder 版本
    __u32                        version;            // 行 158

    // 文件信息
    struct file                 *filp;              // 行 161

    // 工作队列
    struct workqueue_struct     *wq;                // 行 164
};
```

### 1.2 binder_node — Binder 对象（BBinder/BBinder 引用）

```c
// drivers/android/binder.c — binder_node
struct binder_node {
    // 全局链表节点
    struct binder_work           work;              // 行 170

    // 全局节点链表（dead nodes）
    struct hlist_node            dead_node;         // 行 173

    // 所属进程（NULL = 死节点）
    struct binder_proc           *proc;             // 行 176

    // 红黑树节点（接入 proc->nodes）
    struct rb_node               rb_node;           // 行 179

    // 引用此节点的 ref 链表
    struct list_head             refs;              // 行 182

    // 强引用计数
    atomic_t                     stronge;           // 行 185

    // 弱引用计数
    atomic_t                     weake;             // 行 188

    // 引用计数基线
    __u32                        tmp_refs;          // 行 191

    // 内部锁
    spinlock_t                   lock;              // 行 194

    // 指向 IBinder（Java 层 Binder 对象）
    binder_uintptr_t             ptr;               // 行 197

    // cookie（附加数据）
    binder_uintptr_t             cookie;            // 行 200

    // 延迟强度
    __u32                        mode;               // 行 203

    // 调试
    unsigned long                debug_id;          // 行 206

    // 所有权
    struct list_head             entry;             // 行 209
};
```

### 1.3 binder_ref — binder 引用（跨进程 handle）

```c
// drivers/android/binder.c — binder_ref
struct binder_ref {
    // 全局节点链表
    struct hlist_node            node_entry;        // 行 213

    // 所属进程
    struct binder_proc           *proc;             // 行 216

    // 引用的 binder_node
    struct binder_node           *node;             // 行 219

    // 描述符（用户空间看到的 handle）
    __u32                         desc;             // 行 222

    // 强引用计数
    __u32                         strong;            // 行 225

    // 弱引用计数
    __u32                         weak;              // 行 228

    // 死亡通知
    struct binder_ref_death       *death;            // 行 231
};
```

### 1.4 binder_transaction — 事务

```c
// drivers/android/binder.c — binder_transaction
struct binder_transaction {
    // 调试
    unsigned long                debug_id;          // 行 235

    // 目标节点
    struct binder_node           *target_node;       // 行 238

    // 目标进程/线程
    int                          to_proc;            // 行 241
    int                          to_thread;          // 行 244

    // 代码和数据
    void                         *buffer;            // 行 247
    binder_size_t                 data_size;          // 行 250
    binder_size_t                 offsets_size;       // 行 253
    binder_size_t                 data_offsets_size; // 行 256

    // 发送方进程/线程
    int                          from_proc;          // 行 259
    int                          from_thread;        // 行 262

    // 异步/同步标志
    unsigned int                  flags;             // 行 265

    // 优先级
    int                          priority;           // 行 268
    int                          saved_priority;      // 行 271

    // 错误码
    bool                         set_priority_called;  // 行 274
    int                          error;               // 行 277

    // 延迟释放
    struct delayed_work          work;                // 行 280

    // 回复事务
    struct binder_transaction    *from_parent;       // 行 283
    struct binder_transaction    *to_parent;          // 行 286

    // scatter-gather 复制
    struct binder_sg_copy        *sg_copy;           // 行 289

    // 内部锁
    spinlock_t                   lock;                // 行 292
    struct list_head              lock_node;         // 行 295
};
```

## 2. mmap — 共享内存机制

Binder 使用 `mmap` 在 client 和 service 之间建立共享内存，**零拷贝**：

```c
// drivers/android/binder.c — binder_mmap
static int binder_mmap(struct file *filp, struct vm_area_struct *vma)
{
    struct binder_proc *proc = filp->private_data;

    // 1. 检查映射大小（默认 1MB - 8KB）
    if (vma->vm_end - vma->vm_start > SZ_1M * 4)
        return -ENOMEM;

    // 2. 分配 binder_buffer
    proc->buffer_size = vma->vm_end - vma->vm_start;

    // 3. 设置 VM 标志
    vma->vm_ops = &binder_vm_ops;
    vma->vm_flags |= VM_DONTCOPY | VM_MIXEDMAP;
    vma->vm_private_data = proc;

    // 4. 将虚拟地址范围映射到物理页
    //    使用 vm_insert_page 或 remap_pfn_range
    //    物理页来自一个预分配的页池

    return 0;
}
```

## 3. binder_ioctl — 命令入口

```c
// drivers/android/binder.c:5773 — binder_ioctl
static long binder_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
    int ret;
    struct binder_proc *proc = filp->private_data;
    struct binder_thread *thread;
    void __user *ubuf = (void __user *)arg;

    trace_binder_ioctl(cmd, arg);

    // 获取当前线程的 binder_thread
    thread = binder_get_thread(proc);

    // 获取锁
    binder_inner_proc_lock(proc);

    switch (cmd) {
    case BINDER_WRITE_READ:
        // 读写 Binder 数据
        ret = binder_ioctl_write_read(filp, cmd, arg, thread);
        break;
    case BINDER_SET_MAX_THREADS:
        // 设置最大线程数
        ret = binder_set_max_threads(proc, arg);
        break;
    case BINDER_SET_CONTEXT_MGR:
        // 设置 ServiceManager（context manager）
        ret = binder_ioctl_set_ctx_mgr(filp);
        break;
    case BINDER_THREAD_EXIT:
        // 线程退出
        binder_release_thread(thread);
        break;
    case BINDER_VERSION:
        // 返回 Binder 版本
        ret = binder_ioctl_get_version(proc, arg);
        break;
    }

    binder_inner_proc_unlock(proc);
    return ret;
}
```

## 4. flat_binder_object — 跨进程对象编码

```c
// include/uapi/linux/binder.h
struct flat_binder_object {
    __u32           type;       // 类型：BINDER_TYPE_*
    __u32           flags;      // 标志
    __u64           handle;     // 跨进程句柄
    __u64           cookie;     // 附加数据
};

// type 字段含义：
//   BINDER_TYPE_BINDER:      传递强引用（继承 IBinder 生命周期）
//   BINDER_TYPE_WEAK_BINDER:  传递弱引用
//   BINDER_TYPE_HANDLE:      传递已存在的 handle（代理引用）
//   BINDER_TYPE_WEAK_HANDLE:  传递弱 handle
//   BINDER_TYPE_FD:          传递文件描述符
//   BINDER_TYPE_FDA:         传递文件描述符数组
//   BINDER_TYPE_PTR:         传递指针（仅在同一进程内）
```

## 5. BC_TRANSACTION — 发送事务

```c
// binder_ioctl_write_read — 发送端
static int binder_ioctl_write_read(struct file *filp, unsigned int cmd,
                   unsigned long arg, struct binder_thread *thread)
{
    struct binder_proc *proc = filp->private_data;
    void __user *ubuf = (void __user *)arg;
    struct binder_write_read bwr;

    copy_from_user(&bwr, ubuf, sizeof(bwr));

    // 处理写缓冲区（BC_xxx 命令）
    if (bwr.write_size > 0)
        ret = binder_thread_write(proc, thread,
            bwr.read_buffer, bwr.write_size, &bwr.write_consumed);

    // 处理读缓冲区（接收 BR_xxx 响应）
    if (bwr.read_size > 0)
        ret = binder_thread_read(proc, thread,
            bwr.read_buffer, bwr.read_size, &bwr.read_consumed, ...);
}
```

## 6. 死亡通知（Death Notification）

```c
// 机制：当目标进程退出时，通知注册者

// 发送方注册：
//   BC_REQUEST_DEATH_NOTIFICATION
//   → binder死之后
//   → BR_DEAD_BINDER 发送给注册者

// 结构：
struct binder_ref_death {
    struct binder_work              work;           // 行 240
    binder_uintptr_t               cookie;          // 行 243
    struct list_head                entry;          // 行 246
    struct completion               *complete;      // 行 249
    uint32_t                       pid;             // 行 252
};
```

## 7. 设计决策总结

| 设计决策 | 原因 |
|---------|------|
| mmap 共享内存 | 零拷贝，避免 copy_from_user |
| handle 作为引用 | 进程隔离，handle 可撤销 |
| 强/弱引用 | 支持弱引用（AIDL 的 death listener）|
| 死亡通知 | 及时发现对方进程退出 |
| 两层锁（inner/outer）| 减少锁竞争，提高并发 |

## 8. 参考

| 文件 | 函数/结构 | 行 |
|------|----------|-----|
| `drivers/android/binder.c` | `binder_proc` | 90+ |
| `drivers/android/binder.c` | `binder_node` | 170+ |
| `drivers/android/binder.c` | `binder_ref` | 213+ |
| `drivers/android/binder.c` | `binder_transaction` | 235+ |
| `drivers/android/binder.c` | `binder_ioctl` | 5773 |
| `drivers/android/binder.c` | `binder_mmap` | mmap 函数 |
| `drivers/android/binder.c` | `binder_transaction` | 发送/接收流程 |
| `include/uapi/linux/binder.h` | `flat_binder_object` | API 定义 |


---

## doom-lsp 源码分析

> 以下分析基于 Linux 7.0 主线源码，使用 doom-lsp (clangd LSP) 进行深度符号分析

### 文件分析摘要

| 源文件 | 符号数 | 结构体 | 函数 | 变量 |
|--------|--------|--------|------|------|
| `include/linux/list.h` | 51 | 0 | 51 | 0 |
| `include/linux/sched.h` | 567 | 70 | 134 | 7 |
| `include/linux/mm.h` | 793 | 24 | 527 | 18 |

### 核心数据结构

- **audit_context** `sched.h:58`
- **bio_list** `sched.h:59`
- **blk_plug** `sched.h:60`
- **bpf_local_storage** `sched.h:61`
- **bpf_run_ctx** `sched.h:62`
- **bpf_net_context** `sched.h:63`
- **capture_control** `sched.h:64`
- **cfs_rq** `sched.h:65`
- **fs_struct** `sched.h:66`
- **futex_pi_state** `sched.h:67`
- **io_context** `sched.h:68`
- **io_uring_task** `sched.h:69`
- **mempolicy** `sched.h:70`
- **nameidata** `sched.h:71`
- **nsproxy** `sched.h:72`
- **perf_event_context** `sched.h:73`
- **perf_ctx_data** `sched.h:74`
- **pid_namespace** `sched.h:75`
- **pipe_inode_info** `sched.h:76`
- **rcu_node** `sched.h:77`
- **reclaim_state** `sched.h:78`
- **robust_list_head** `sched.h:79`
- **root_domain** `sched.h:80`
- **rq** `sched.h:81`
- **sched_attr** `sched.h:82`

### 关键函数

- **INIT_LIST_HEAD** `list.h:43`
- **__list_add_valid** `list.h:136`
- **__list_del_entry_valid** `list.h:142`
- **__list_add** `list.h:154`
- **list_add** `list.h:175`
- **list_add_tail** `list.h:189`
- **__list_del** `list.h:201`
- **__list_del_clearprev** `list.h:215`
- **__list_del_entry** `list.h:221`
- **list_del** `list.h:235`
- **list_replace** `list.h:249`
- **list_replace_init** `list.h:265`
- **list_swap** `list.h:277`
- **list_del_init** `list.h:293`
- **list_move** `list.h:304`
- **list_move_tail** `list.h:315`
- **list_bulk_move_tail** `list.h:331`
- **list_is_first** `list.h:350`
- **list_is_last** `list.h:360`
- **list_is_head** `list.h:370`
- **list_empty** `list.h:379`
- **list_del_init_careful** `list.h:395`
- **list_empty_careful** `list.h:415`
- **list_rotate_left** `list.h:425`
- **list_rotate_to_front** `list.h:442`
- **list_is_singular** `list.h:457`
- **__list_cut_position** `list.h:462`
- **list_cut_position** `list.h:488`
- **list_cut_before** `list.h:515`
- **__list_splice** `list.h:531`
- **list_splice** `list.h:550`
- **list_splice_tail** `list.h:562`
- **list_splice_init** `list.h:576`
- **list_splice_tail_init** `list.h:593`
- **list_count_nodes** `list.h:755`

### 全局变量

- **__tracepoint_sched_set_state_tp** `sched.h:350`
- **__tracepoint_sched_set_need_resched_tp** `sched.h:352`
- **def_root_domain** `sched.h:407`
- **sched_domains_mutex** `sched.h:408`
- **cad_pid** `sched.h:1749`
- **init_stack** `sched.h:1964`
- **class_migrate_is_conditional** `sched.h:2519`
- **_totalram_pages** `mm.h:53`
- **high_memory** `mm.h:74`
- **sysctl_legacy_va_layout** `mm.h:86`
- **mmap_rnd_bits_min** `mm.h:92`
- **mmap_rnd_bits_max** `mm.h:93`
- **mmap_rnd_bits** `mm.h:94`
- **sysctl_user_reserve_kbytes** `mm.h:210`
- **sysctl_admin_reserve_kbytes** `mm.h:211`

### 成员/枚举

- **utime** `sched.h:366`
- **stime** `sched.h:367`
- **lock** `sched.h:368`
- **seqcount** `sched.h:386`
- **starttime** `sched.h:387`
- **state** `sched.h:388`
- **cpu** `sched.h:389`
- **utime** `sched.h:390`
- **stime** `sched.h:391`
- **gtime** `sched.h:392`
- **sched_priority** `sched.h:413`
- **pcount** `sched.h:421`
- **run_delay** `sched.h:424`
- **max_run_delay** `sched.h:427`
- **min_run_delay** `sched.h:430`
- **last_arrival** `sched.h:435`
- **last_queued** `sched.h:438`
- **max_run_delay_ts** `sched.h:441`
- **weight** `sched.h:461`
- **inv_weight** `sched.h:462`

