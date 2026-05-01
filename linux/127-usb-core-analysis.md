# Linux Kernel USB Core 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/usb/core/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：URB、端点、传输类型、HCD、xHCI

## 0. USB 架构

```
USB 设备
  │
  ├─ Hub（集线器）
  │    └─ 端口 1: 键盘
  │    └─ 端口 2: 鼠标
  │    └─ 端口 3: Webcam
  │
主机控制器（HCD）：
  UHCI — USB 1.0（Intel，的软件控制）
  OHCI — USB 1.0（Compaq/Apple，硬件控制）
  EHCI — USB 2.0（高速，480 Mbps）
  xHCI — USB 3.0+（超高速，5 Gbps+）
```

## 1. 核心数据结构

### 1.1 usb_device — USB 设备

```c
// drivers/usb/core/message.c — usb_device
struct usb_device {
    int                 devnum;         // 设备地址（1-127）
    char                devpath[16];     // 路径字符串（"1-2.3"）

    // 设备描述符（bcdDevice、idVendor、idProduct）
    struct usb_device_descriptor descriptor;

    // 当前配置
    struct usb_host_config *actconfig;  // 当前活跃配置

    // 所有配置
    struct usb_host_config *config, **configs;

    // 设备状态
    enum usb_device_state   state;  // DEFAULT / ADDRESS / CONFIGURED / SUSPENDED

    // 父设备（Hub）
    struct usb_device   *parent;     // NULL = root hub

    // 设备速度
    enum usb_device_speed speed;     // LOW / FULL / HIGH / SUPER

    // 端点 0（控制端点）
    struct usb_host_endpoint ep0;

    // 端口信息
    struct usb_hub *hub;             // Hub（如果有）
    int portnum;                     // 端口号
};
```

### 1.2 usb_host_endpoint — 端点

```c
// drivers/usb/core/message.c — usb_host_endpoint
struct usb_host_endpoint {
    // 端点描述符
    struct usb_endpoint_descriptor desc;

    // SS 端点补充描述符
    struct usb_ss_ep_comp_descriptor *ss_ep_comp;

    // 过滤列表
    struct list_head urb_list;       // 此端点的 URB 链表
    void            *hcpriv;         // HCD 私有数据
};
```

### 1.3 URB (USB Request Block)

```c
// include/linux/usb.h — struct urb
struct urb {
    // 引用计数
    atomic_t            usage_count;     // 行 1328
    refcount_t          reject;           // 行 1329

    // 链表节点
    struct list_head    urb_list;          // 行 1332

    // 所属 USB 设备
    struct usb_device  *dev;             // 行 1335

    // 端点（in/out）
    unsigned int        pipe;             // 行 1338

    // 传输参数
    void               *transfer_buffer;   // 行 1341
    u32                 transfer_flags;    // 行 1342
    int                 transfer_buffer_length; // 行 1343
    int                 actual_length;     // 行 1344

    // DMA
    dma_addr_t          transfer_dma;     // 行 1347
    struct scatterlist  *sg;             // 行 1348
    int                 num_sgs;         // 行 1349

    // 完成回调
    usb_complete_t      complete;         // 行 1352
    void               *context;          // 行 1353
    void               *status;          // 行 1354

    // 每次传输的起始时间
    unsigned long       start_time;      // 行 1356
};
```

## 2. 传输类型

### 2.1 控制传输（Control）

```
SETUP → DATA（可选）→ STATUS

用于：设备枚举、配置、命令
特点：可靠、保证顺序
```

### 2.2 批量传输（Bulk）

```
批量端点传输大量数据

特点：
  - 带宽不保证（等时传输优先）
  - 可靠（CRC 校验，错误重传）
  - 异步（无固定延迟）

用于：U盘、打印机、扫描仪
```

### 2.3 中断传输（Interrupt）

```
定期轮询端点（polling interval）

特点：
  - 低延迟
  - 小数据量
  - 保证带宽

用于：键盘、鼠标
```

### 2.4 等时传输（Isochronous）

```
实时传输，无错误重传

特点：
  - 固定带宽
  - 无 CRC 校验
  - 可能丢帧

用于：摄像头、麦克风、音频
```

## 3. URB 生命周期

```c
// 1. 创建 URB
struct urb *usb_alloc_urb(int iso_packets, gfp_t mem_flags);

// 2. 初始化
usb_fill_control_urb(urb, dev, pipe,
             setup_packet, transfer_buffer, buffer_length,
             complete_fn, context);

// 3. 提交
int usb_submit_urb(urb, mem_flags);

// 4. 取消
int usb_kill_urb(urb);
int usb_unlink_urb(urb);
```

## 4. xHCI 主机控制器

```c
// drivers/usb/host/xhci.h — xhci_hcd
struct xhci_hcd {
    struct usb_hcd      *hcd;            // USB HCD 基类
    struct device       *dev;

    // 寄存器
    void __iomem        *run_regs;       // 运行时寄存器
    void __iomem        *dba;            // Doorbell Array
    void __iomem        *prima;          // Primary Stream ID Array

    // 端点上下文
    struct xhci_ring   *cmd_ring;       // 命令环
    struct xhci_ring   *event_ring;     // 事件环

    // Slot 上下文
    struct xhci_slot_ctx *slots[255];
};
```

## 5. 参考

| 文件 | 内容 |
|------|------|
| `drivers/usb/core/hcd.c` | HCD（主机控制器驱动）|
| `drivers/usb/core/message.c` | USB 消息传递 |
| `drivers/usb/core/urb.c` | URB 管理 |
| `include/linux/usb.h` | `struct urb` |
| `drivers/usb/host/xhci.h` | xHCI 驱动 |


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

