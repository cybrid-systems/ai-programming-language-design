# perf — 性能分析工具深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`kernel/events/core.c` + `kernel/events/ring_buffer.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**perf** 是 Linux 性能分析工具，支持：
- **硬件计数器**：PMU（Performance Monitoring Unit）事件
- **软件事件**：context switch、page fault、cache miss
- **tracepoint**：内核静态插桩点
- **动态探针（kprobe/uprobe）**：任意内核/用户函数

---

## 1. 核心数据结构

### 1.1 perf_event — 性能事件

```c
// include/linux/perf_event.h — perf_event
struct perf_event {
    // 链表
    struct list_head        group_entry;   // 事件组链表
    struct list_head        event_entry;    // 全局事件链表

    // 归属
    struct perf_event       *group_leader; // 组领导
    struct pmu              *pmu;          // PMU（性能监控单元）
    struct task_struct      *task;         // 关联进程（NULL=系统范围）
    struct file             *filp;         // 关联文件描述符

    // 配置
    u64                     config;         // 事件配置
    enum perf_type_id       type;          // 类型（HARDWARE/SOFTWARE/TRACEPOINT）
    unsigned int            size;          // 结构大小

    // 采样
    struct perf_sample_data *data;         // 采样数据
    unsigned long           sample_period; // 采样周期
    unsigned long           sample_type;   // 采样类型（TID/TIME/IP/...）

    // 回调
    const struct perf_event_attr *attr;    // 属性
    void                    *destroy;       // 销毁函数

    // 环形缓冲区
    struct ring_buffer      *rb;           // 输出缓冲区

    // 过滤
    struct event_filter     *filter;       // BPF 过滤
};
```

### 1.2 pmu — 性能监控单元

```c
// include/linux/perf_event.h — pmu
struct pmu {
    const char              *name;         // "cpu" "tracepoint" 等
    int                     (*event_init)(struct perf_event *event, int flags);
    void                    (*enable)(struct perf_event *event);
    void                    (*disable)(struct perf_event *event);
    int                     (*add)(struct perf_event *event, int flags);
    void                    (*del)(struct perf_event *event, int flags);
    void                    (*read)(struct perf_event *event);
    void                    (*start)(struct perf_event *event, int flags);
    void                    (*stop)(struct perf_event *event, int flags);
    struct attribute_group  **attr_groups; // sysfs 属性组
    struct task_event_ops   *task_ctx;     // 任务上下文
};
```

### 1.3 perf_swevent_enabled — 软件事件

```c
// kernel/events/core.c — perf_swevent_enabled
static const atomic_t perf_swevent_enabled[PERF_COUNT_SW_MAX];

// PERF_COUNT_SW_CPU_CLOCK         = 0
// PERF_COUNT_SW_TASK_CLOCK       = 1
// PERF_COUNT_SW_PAGE_FAULTS      = 2
// PERF_COUNT_SW_CONTEXT_SWITCHES  = 3
// PERF_COUNT_SW_CPU_MIGRATIONS   = 4
// PERF_COUNT_SW_PAGE_FAULTS_MIN   = 5
// PERF_COUNT_SW_PAGE_FAULTS_MAJ   = 6
// PERF_COUNT_SW_ALIGNMENT_FAULTS   = 7
// PERF_COUNT_SW_EMULATION_FAULTS  = 8
```

---

## 2. perf_event_open 系统调用

### 2.1 sys_perf_event_open

```c
// kernel/events/core.c — SYSCALL_DEFINE5(perf_event_open, ...)
long sys_perf_event_open(struct perf_event_attr *attr,
                         pid_t pid, int cpu, int group_fd, unsigned long flags)
{
    struct perf_event *event;
    struct perf_event_attr *attr;

    // 1. 分配 perf_event
    event = kzalloc(sizeof(*event), GFP_KERNEL);

    // 2. 复制属性
    memcpy(&event->attr, attr, sizeof(*attr));

    // 3. 初始化 PMU
    pmu = pmu_get(attr->type);
    if (pmu)
        pmu->event_init(event, flags);

    // 4. 关联进程/CPU
    if (pid != -1)
        event->task = find_task(pid);
    event->cpu = cpu;

    // 5. 分配环形缓冲区
    event->rb = alloc_ring_buffer(event);

    // 6. 加入组的链表
    if (group_fd != -1) {
        group_leader = perf_event_get(group_fd);
        list_add(&event->group_entry, &group_leader->group_list);
    }

    return fd;
}
```

---

## 3. enable/disable 流程

### 3.1 perf_event_enable

```c
// kernel/events/core.c — perf_event_enable
static void perf_event_enable(struct perf_event *event)
{
    struct pmu *pmu = event->pmu;

    // 1. 如果有 group_leader，需要一起 enable
    if (event->group_leader != event)
        return;

    // 2. 调用 PMU 的 enable
    if (pmu && pmu->enable)
        pmu->enable(event);

    // 3. 如果有软件事件，设置软件回调
    if (event->attr.type == PERF_TYPE_SOFTWARE)
        swevent_hrtimer_init(event);

    // 4. 增加引用计数
    atomic_inc(&event->refcount);
}
```

---

## 4. 采样流程

### 4.1 perf_output_sample — 输出样本

```c
// kernel/events/ring_buffer.c — perf_output_sample
static void perf_output_sample(struct ring_buffer *rb,
                                struct perf_event *event,
                                struct perf_sample_data *data)
{
    // 1. 检查采样类型
    if (data->sample_type & PERF_SAMPLE_TID)
        output_u64(data->tid);

    if (data->sample_type & PERF_SAMPLE_TIME)
        output_u64(data->time);

    if (data->sample_type & PERF_SAMPLE_IP)
        output_u64(data->ip);

    if (data->sample_type & PERF_SAMPLE_CALLCHAIN)
        output_callchain(data);

    if (data->sample_type & PERF_SAMPLE_RAW)
        output_raw(data);
}
```

---

## 5. 数据结构关系

```
perf_event_open()
    ↓
struct perf_event { event }
    ↓
struct pmu { cpu_hw_events } ←────────────────────┐
    ↓                                          │
struct cpu_hw_events {                     (硬件 PMU)
    struct perf_event *events[];          (硬件计数器)
    struct perf_hw_pmu *pmu;             (事件配置)
}
    ↓
struct ring_buffer {                     (输出缓冲)
    struct page **pages;
}
```

---

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `kernel/events/core.c` | `sys_perf_event_open`、`perf_event_enable` |
| `kernel/events/ring_buffer.c` | `perf_output_sample`、`alloc_ring_buffer` |
| `include/linux/perf_event.h` | `struct perf_event`、`struct pmu` |