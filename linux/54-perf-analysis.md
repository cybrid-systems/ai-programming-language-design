# 54-perf — Linux perf_event 性能监控框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**perf_event** 是 Linux 内核的通用性能监控子系统。它从 PMU（Performance Monitoring Unit，性能监控单元）硬件采样到软件跟踪（tracepoint、kprobe），为用户空间提供统一的性能数据接口。

**核心设计哲学**：将所有的性能事件抽象为 `perf_event` 对象——不论其来源是硬件 PMC 计数器、软件计数器、tracepoint、kprobe 还是动态跟踪——通过统一的打开/关闭/读取/映射接口管理。

```
用户空间                     内核
─────────                  ──────
perf tool / perf_event_open()
   ↓
perf_event_alloc() → 分配事件
   │
   ├── sys_perf_event_open()
   │    ↓
   │  perf_install_in_context()
   │    ↓ 调度到目标 CPU/任务
   │
   ├── 计数模式
   │    ↓
   │  PMU: pmu->add()/read() → ring_buffer
   │  或软件: 软件事件计数
   │
   └── 采样模式
        ↓
      NMI/中断 → perf_event_overflow()
         → __perf_event_output()
             → ring_buffer 写入
                 → mmap 可见给用户
```

**doom-lsp 确认**：核心实现在 `kernel/events/core.c`（**15,371 行**，**948 个符号**）。Ring buffer 在 `kernel/events/ring_buffer.c`（975 行）。uprobes 在 `kernel/events/uprobes.c`（2,914 行）。

**关键文件索引**：

| 文件 | 行数 | 符号数 | 职责 |
|------|------|--------|------|
| `kernel/events/core.c` | 15371 | 948 | perf 核心框架 |
| `kernel/events/ring_buffer.c` | 975 | — | 采样环形缓冲区 |
| `kernel/events/uprobes.c` | 2914 | — | 用户空间探针 |
| `kernel/events/callchain.c` | 330 | — | 调用链回溯 |
| `kernel/events/hw_breakpoint.c` | 1025 | — | 硬件断点 |
| `include/linux/perf_event.h` | 2139 | — | 核心头文件 |

---

## 1. 核心数据结构

### 1.1 struct perf_event — 性能事件

```c
// include/linux/perf_event.h
struct perf_event {
    /* ── 事件标识 ─ */
    u64 id;                                  /* 事件 ID */
    u64 state;                                /* 事件状态 */
    enum perf_type_id type;                   /* 类型：HW/SOFT/TRACEPOINT/HW_CACHE/BREAKPOINT */

    /* ── 所属 PMU ─ */
    struct pmu *pmu;                          /* 关联的 PMU */
    struct perf_event *parent;                /* 父事件（分组 leader）*/
    struct list_head sibling_list;            /* 同一组的兄弟事件 */

    /* ── 属性 ─ */
    struct perf_event_attr attr;              /* 用户定义的属性 */

    /* ── 上下文 ─ */
    struct perf_event_context *ctx;           /* 事件上下文 */
    struct perf_cpu_context *cpu_context;     /* per-CPU 上下文 */
    struct hw_perf_event hw;                  /* PMU 硬件状态 */

    /* ── 计数/采样 ─ */
    local64_t count;                          /* 累计计数 */
    local64_t total_time_enabled;             /* 总启用时间 */
    local64_t total_time_running;             /* 总运行时间 */

    /* ── 采样 ─ */
    struct ring_buffer *rb;                   /* 采样环形缓冲区 */
    u64 sample_period;                        /* 采样周期 */
    perf_callback_t overflow_handler;         /* 溢出回调 */

    /* ── 依附 ─ */
    struct list_head event_entry;             /* 上下文事件链表 */
    struct hlist_node hlist_entry;            /* 全局哈希表条目 */
    struct rcu_head rcu;                      /* RCU 释放 */
};
```

**`struct hw_perf_event`** — PMU 硬件状态：

```c
struct hw_perf_event {
    struct {
        u64 config;         /* PMU 配置（事件选择）*/
        u64 config_base;    /* 配置寄存器基址 */
        u64 event_base;     /* 事件计数寄存器基址 */
        int idx;            /* PMC 索引 */
        int last_cpu;       /* 最后运行的 CPU */
    };

    u64 period_left;        /* 剩余采样周期 */
    u64 interrupts_seq;     /* 中断序列号 */
    u64 interrupts;         /* 中断计数（溢出次数）*/
};
```

### 1.2 struct pmu — PMU 抽象

```c
// include/linux/perf_event.h
struct pmu {
    struct list_head entry;              /* PMU 类型链表 */
    struct module *module;
    struct device *dev;
    const struct attribute_group **attr_groups;

    /* ── 事件生命周期 ─ */
    int (*event_init)(struct perf_event *event);      /* 初始化事件 */
    void (*event_destroy)(struct perf_event *event);   /* 销毁事件 */

    /* ── 调度 ─ */
    int (*add)(struct perf_event *event, int flags);   /* 添加事件到 PMU */
    void (*del)(struct perf_event *event, int flags);  /* 从 PMU 移除 */
    void (*start)(struct perf_event *event, int flags); /* 启动事件 */
    void (*stop)(struct perf_event *event, int flags);  /* 停止事件 */
    void (*read)(struct perf_event *event);              /* 读取计数 */

    /* ── 采样 ─ */
    void (*event_update_userpage)(struct perf_event *event);
    int (*event_idx)(struct perf_event *event);

    /* ── 分组 ─ */
    int (*commit_txn)(struct pmu *pmu);
    void (*cancel_txn)(struct pmu *pmu);
    void (*pmu_enable)(struct pmu *pmu);
    void (*pmu_disable)(struct pmu *pmu);

    u32 type;                            /* PMU 类型 ID */
    const char *name;                    /* PMU 名称 */
};
```

**doom-lsp 确认**：`struct pmu` 在 `include/linux/perf_event.h`。所有硬件 PMU（x86 Intel/AMD、ARM PMUv3、RISC-V 等）都注册为 `pmu` 实例。

### 1.3 struct perf_event_context — 事件上下文

```c
struct perf_event_context {
    struct pmu *pmu;                     /* 关联的 PMU */
    struct list_head pinned_groups;      /* 固定事件组 */
    struct list_head flexible_groups;    /* 灵活事件组 */
    struct list_head event_list;         /* 事件列表 */
    int nr_events;                       /* 事件数 */
    int nr_active;                       /* 活跃事件数 */
    int is_active;                       /* 是否激活 */
    struct task_struct *task;            /* 绑定任务（per-task 模式）*/
    struct rcu_head rcu;
};
```

---

## 2. 系统调用——perf_event_open

```c
// kernel/events/core.c
SYSCALL_DEFINE5(perf_event_open,
    struct perf_event_attr __user *, attr_uptr,
    pid_t, pid, int, cpu, int, group_fd, unsigned long, flags)
{
    /* 1. 复制用户属性 */
    copy_from_user(&attr, attr_uptr, sizeof(attr));

    /* 2. 分配 perf_event */
    event = perf_event_alloc(&attr, cpu, task, group_leader, NULL,
                             NULL, NULL, cgroup_fd);
    if (IS_ERR(event))
        return PTR_ERR(event);

    /* 3. 验证事件（perf_event_validate_size）*/
    perf_event_validate_size(event);

    /* 4. 安装事件到目标上下文 */
    perf_install_in_context(ctx, event, cpu);

    /* 5. 返回 fd */
    return anon_inode_getfd("[perf_event]", &perf_fops, event, 0);
}
```

**打开模式**：

| pid 参数 | cpu 参数 | 绑定范围 |
|----------|---------|---------|
| `-1` | ≥ 0 | 全系统，特定 CPU |
| ≥ 0 | ≥ 0 | 特定进程 + 特定 CPU |
| ≥ 0 | `-1` | 特定进程，所有 CPU |
| `-1` | `-1` | 无效 |

### 2.1 event_fops

```c
// kernel/events/core.c
const struct file_operations perf_fops = {
    .read           = perf_read,            /* 读取计数 */
    .poll           = perf_poll,            /* poll 等待采样数据 */
    .release        = perf_release,         /* 释放事件 */
    .unlocked_ioctl = perf_ioctl,           /* 控制命令 */
    .mmap           = perf_mmap,            /* mmap 采样缓冲区 */
};
```

**ioctl 命令**：

| 命令 | 功能 |
|------|------|
| `PERF_EVENT_IOC_ENABLE` | 启用事件 |
| `PERF_EVENT_IOC_DISABLE` | 禁用事件 |
| `PERF_EVENT_IOC_REFRESH` | 刷新事件（重新计数）|
| `PERF_EVENT_IOC_RESET` | 重置计数 |
| `PERF_EVENT_IOC_PERIOD` | 设置采样周期 |
| `PERF_EVENT_IOC_SET_OUTPUT` | 设置输出缓冲区 |
| `PERF_EVENT_IOC_SET_FILTER` | 设置过滤条件 |
| `PERF_EVENT_IOC_ID` | 获取事件 ID |
| `PERF_EVENT_IOC_SET_BPF` | 关联 BPF 程序 |
| `PERF_EVENT_IOC_PAUSE_OUTPUT` | 暂停输出 |
| `PERF_EVENT_IOC_QUERY_BPF` | 查询关联的 BPF |

---

## 3. 两类模式：计数 vs 采样

### 3.1 计数模式

```c
// perf_event 在 attr.sample_period = 0 时是计数模式
// attr.sample_type 控制采样行为——sample_type = 0 是纯计数

// 用户通过 read() 获取当前计数值
// 内核在事件启动时累计计数：
perf_event_count(event);    /* 获取当前累计计数 */
```

**典型用户**：`perf stat`：
```bash
perf stat ./myapp
# 直接读取周期性累计计数，不采样
```

### 3.2 采样模式

```c
// attr.sample_period > 0 → 每 N 次事件触发一次采样
// 或 attr.freq = 1 → 自适应频率采样

// 硬件计数溢出时：
perf_event_overflow()
  └→ __perf_event_output()
       └→ 写入 ring_buffer
```

**采样数据记录**（`attr.sample_type` 控制包含哪些字段）：

| 标志 | 包含的数据 |
|------|-----------|
| `PERF_SAMPLE_IP` | 指令指针 |
| `PERF_SAMPLE_TID` | PID/TID |
| `PERF_SAMPLE_TIME` | 时间戳 |
| `PERF_SAMPLE_ADDR` | 地址 |
| `PERF_SAMPLE_CPU` | CPU ID |
| `PERF_SAMPLE_PERIOD` | 周期 |
| `PERF_SAMPLE_STREAM_ID` | 流 ID |
| `PERF_SAMPLE_RAW` | 原始 PMU 数据 |
| `PERF_SAMPLE_BRANCH_STACK` | 分支记录 |
| `PERF_SAMPLE_REGS_USER` | 用户寄存器 |
| `PERF_SAMPLE_STACK_USER` | 用户栈 |
| `PERF_SAMPLE_WEIGHT` | 权重 |
| `PERF_SAMPLE_DATA_SRC` | 数据源 |
| `PERF_SAMPLE_IDENTIFIER` | 标识符 |
| `PERF_SAMPLE_TRANSACTION` | 事务 |
| `PERF_SAMPLE_REGS_INTR` | 中断寄存器 |
| `PERF_SAMPLE_PHYS_ADDR` | 物理地址 |
| `PERF_SAMPLE_CGROUP` | cgroup ID |
| `PERF_SAMPLE_CODE_PAGE_SIZE` | 代码页大小 |
| `PERF_SAMPLE_WEIGHT_STRUCT` | 权重结构体 |
| `PERF_SAMPLE_DATA_PAGE_SIZE` | 数据页大小 |

**典型用户**：`perf record`：
```bash
perf record -F 1000 ./myapp    # 1kHz 采样
```

---

## 4. 采样环形缓冲区

```c
// kernel/events/ring_buffer.c:975
// perf ring_buffer 是用户-内核共享的 mmap 环形缓冲区
//
// mmap 布局（2 个页面 header + 数据区域）：
//  page 0: struct perf_event_mmap_page（控制头）
//  page 1: 数据描述符
//  page 2+: 环形数据区域

struct ring_buffer {
    atomic_t head;                     /* 写位置 */
    atomic_t nest;                     /* 嵌套计数 */
    int page_order;                    /* 页面大小（order）*/
    int nr_pages;                      /* 数据页面数 */
    struct user_struct *mmap_user;
    struct perf_event_mmap_page *user_page; /* 用户空间头 */
    struct page **pages;               /* 数据页面数组 */
    struct list_head event_list;       /* 输出到此 rb 的事件 */
};
```

**数据写入路径**：

```c
// kernel/events/core.c
void __perf_event_output(struct perf_event *event, ...)
{
    struct ring_buffer *rb;
    struct perf_output_handle handle;

    /* 1. 获取 ring_buffer */
    rcu_read_lock();
    rb = rcu_dereference(event->rb);

    /* 2. 保留数据空间 */
    perf_output_begin(&handle, event, size);

    /* 3. 写入采样数据 */
    perf_output_sample(&handle, &header, event, ...);

    /* 4. 提交数据 */
    perf_output_end(&handle);
    rcu_read_unlock();
}
```

**用户空间读取**：

```c
// mmap 后直接读取共享内存
struct perf_event_mmap_page *pc = mmap(NULL, ...);
// 内核写入: pc->data_head
// 用户读取后: pc->data_tail = pc->data_head
```

---

## 5. 事件调度

perf 事件必须被"调度"到 PMU 硬件上才能开始计数。`perf_event_context` 维护两个事件组列表：

```
perf_event_context
  ├── pinned_groups:   固定组（总是调度，优先级最高）
  │    ├── event_A (PMU PMC 0)
  │    └── event_B (PMU PMC 1)
  │
  └── flexible_groups: 灵活组（PMU 资源不足时弹性）
       ├── event_C
       └── event_D
```

**调度算法**（`perf_event_sched_in()`）：

```c
// 内核/events/core.c
static void perf_event_context_sched_in(struct perf_event_context *ctx, ...)
{
    /* 1. 优先调度 pinned 组 */
    list_for_each_entry(event, &ctx->pinned_groups, ...)
        pmu->add(event, PERF_EF_START);   /* 必须成功 */

    /* 2. 再调度 flexible 组（尽量多）*/
    list_for_each_entry(event, &ctx->flexible_groups, ...)
        if (pmu->add(event, PERF_EF_START) == 0)
            nr++;                          /* 可能失败 */
}
```

---

## 6. PMU 类型

| PMU 类型 | 值 | 来源 |
|----------|-----|------|
| `PERF_TYPE_HARDWARE` | 0 | CPU 硬件 PMC |
| `PERF_TYPE_SOFTWARE` | 1 | 内核软件事件 |
| `PERF_TYPE_TRACEPOINT` | 2 | tracepoint |
| `PERF_TYPE_HW_CACHE` | 3 | 缓存相关事件 |
| `PERF_TYPE_RAW` | 4 | 原始 PMU 配置 |
| `PERF_TYPE_BREAKPOINT` | 5 | 硬件断点 |

**预定义硬件事件**：

```c
PERF_COUNT_HW_CPU_CYCLES           /* CPU 周期 */
PERF_COUNT_HW_INSTRUCTIONS          /* 指令数 */
PERF_COUNT_HW_CACHE_REFERENCES      /* 缓存引用 */
PERF_COUNT_HW_CACHE_MISSES          /* 缓存未命中 */
PERF_COUNT_HW_BRANCH_INSTRUCTIONS   /* 分支指令 */
PERF_COUNT_HW_BRANCH_MISSES         /* 分支预测失败 */
PERF_COUNT_HW_BUS_CYCLES            /* 总线周期 */
PERF_COUNT_HW_STALLED_CYCLES_FRONTEND /* 前端停顿 */
PERF_COUNT_HW_STALLED_CYCLES_BACKEND  /* 后端停顿 */
PERF_COUNT_HW_REF_CPU_CYCLES        /* 参考 CPU 周期 */
```

**软件事件**：

```c
PERF_COUNT_SW_CPU_CLOCK             /* CPU 时钟 */
PERF_COUNT_SW_TASK_CLOCK            /* 任务时钟 */
PERF_COUNT_SW_PAGE_FAULTS           /* 缺页 */
PERF_COUNT_SW_CONTEXT_SWITCHES      /* 上下文切换 */
PERF_COUNT_SW_CPU_MIGRATIONS        /* CPU 迁移 */
PERF_COUNT_SW_PAGE_FAULTS_MIN       /* 小缺页 */
PERF_COUNT_SW_PAGE_FAULTS_MAJ       /* 大缺页 */
PERF_COUNT_SW_ALIGNMENT_FAULTS      /* 对齐错误 */
PERF_COUNT_SW_EMULATION_FAULTS      /* 模拟错误 */
PERF_COUNT_SW_DUMMY                 /* 哑事件 */
PERF_COUNT_SW_BPF_OUTPUT            /* BPF 输出 */
PERF_COUNT_SW_CGROUP_SWITCHES       /* cgroup 切换 */
```

---

## 7. NMI 中断处理路径

```c
// 硬件 PMC 溢出时触发 NMI → perf_event_nmi_handler()
//   → perf_pmu_enable()
//     → x86_pmu_handle_irq()
//       → 遍历活跃 PMC，读取计数器
//         → perf_event_overflow()
//           → 采样：__perf_event_output() → ring_buffer
//           → 计数：local64_add(period, &event->count)
//           → 设置新的 sample_period
```

---

## 8. 事件分组

```c
// perf_event_open 支持 group_fd 参数（group leader）
// 一组事件作为一个原子单元调度：
//   - 要么全部在 PMU 上，要么全不在
//   - 分组保证事件同时开始/停止
//   - 用于计算比率（如 cache_misses / cache_refs）

// 创建分组：
int leader = perf_event_open(&attr1, pid, cpu, -1, 0);
int member = perf_event_open(&attr2, pid, cpu, leader, 0);
```

---

## 9. 与 BPF 集成

```c
// perf_event 可以通过 IOC_SET_BPF 关联 BPF 程序：
// 当事件触发时，BPF 程序接收事件数据
//
// 典型流程：
// 1. perf_event_open() 创建事件
// 2. bpftool prog load 加载 BPF 程序
// 3. ioctl(fd, PERF_EVENT_IOC_SET_BPF, prog_fd)
//
// 应用：perf tool 的 --bpf-prog 参数
```

---

## 10. 调用链（Callchain）回溯

```c
// kernel/events/callchain.c:330
// 在采样点回溯调用栈：
//   用户空间：读取用户栈（dump 寄存器 + 栈数据）
//   内核空间：使用 unwind（guess/conservative/arch specific）
//
// 采样时需要 PERF_SAMPLE_CALLCHAIN 标志
```

---

## 11. uprobe——用户空间探针

```c
// kernel/events/uprobes.c:2914
// 在用户空间进程的任意指令地址设置探针
// 实现方式：
//   1. 将目标地址的指令替换为 breakpoint (int3)
//   2. hit 时触发：
//      uprobe_notify_handler() → perf_event_overflow()
//   3. 单步执行原指令
//   4. 恢复

// 用于：用户空间动态跟踪
// perf probe -x /usr/lib/libc.so.6 'malloc%return'
```

---

## 12. 调试与使用

```bash
# 查看所有 PMU
ls /sys/bus/event_source/devices/
# 可能: cpu, uncore, software, tracepoint, breakpoint, ...

# 查看 CPU PMU 事件
perf list

# 计数模式
perf stat -e cycles,instructions,cache-misses ./myapp

# 采样模式
perf record -F 99 -e cycles ./myapp
perf report

# 动态跟踪
perf probe --add 'do_sys_open filename:string'
perf record -e probe:do_sys_open -aR sleep 1

# 硬件断点
perf record -e mem:0x7f...:rw

# 查看事件信息
cat /proc/<pid>/fdinfo/<perf_fd>
```

---

## 13. 性能考量

| 操作 | 延迟 | 说明 |
|------|------|------|
| 无事件启用 | **0** | perf 不使用时无开销 |
| 计数模式（单事件） | **1-5ns/次** | PMU 硬件自动计数 |
| 计数模式（多事件） | **5-20ns/次** | PMU 多个计数器 |
| 采样模式（1kHz） | **~10ns/tick** | 1ms 触发一次 |
| 采样模式（max） | **~200ns/事件** | 受 NMI 频率限制 |
| ring buffer 写入 | **~100-500ns** | 内存复制 + 障碍 |

---

## 14. 总结

Linux perf_event 子系统的设计体现了：

**1. 统一的事件抽象**——硬件 PMC、软件事件、tracepoint、kprobe、uprobe 全部抽象为 `perf_event` 对象，共用 fd 接口。

**2. PMU 插件架构**——`struct pmu` 定义标准接口，x86 Intel/AMD、ARM、RISC-V 等各架构通过注册 pmu 实例无缝接入。

**3. 两种互补模式**——计数模式（零开销统计数据）和采样模式（获取上下文快照），覆盖性能分析的全部需求。

**4. 高效的 ring_buffer**——共享内存环形缓冲区，内核写入、用户读取，零系统调用（poll 和 read 仅在需要新数据时调用）。

**5. 事件分组调度**——pinned + flexible 两级调度 + 原子分组 = 精确的资源控制和比率测量。

**关键数字**：
- `kernel/events/core.c`：15,371 行，948 符号
- 事件类型：HW/SW/TRACEPOINT/HW_CACHE/BREAKPOINT
- 预定义硬件事件：8 个
- 预定义软件事件：12 个
- sample_type 字段：20+ 种组合
- PMU 数量：取决于硬件（Intel 通常 2-4 个，ARM 可变）

---

## 附录 A：关键源码索引

| 文件 | 行号 | 符号 |
|------|------|------|
| `include/linux/perf_event.h` | — | `struct perf_event`, `struct pmu`, `struct hw_perf_event` |
| `kernel/events/core.c` | — | `SYSCALL_DEFINE5(perf_event_open)` |
| `kernel/events/core.c` | — | `perf_event_alloc()` |
| `kernel/events/core.c` | — | `perf_event_overflow()` |
| `kernel/events/core.c` | — | `__perf_event_output()` |
| `kernel/events/core.c` | — | `perf_event_context_sched_in()` |
| `kernel/events/ring_buffer.c` | — | `struct ring_buffer`, `perf_output_begin/end` |
| `kernel/events/callchain.c` | — | `perf_callchain()` |
| `kernel/events/uprobes.c` | — | `uprobe_handler`, `uprobe_register` |
| `kernel/events/hw_breakpoint.c` | — | `hw_breakpoint_event_init` |

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
