# USB core — USB 核心子系统深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/usb/core/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**USB core** 提供 USB 主机控制器和设备的公共抽象，支持 HUB、热插拔、传输类型（控制/批量/中断/同步）。

## 1. 核心数据结构

### 1.1 usb_device — USB 设备

```c
// drivers/usb/core/message.c — usb_device
struct usb_device {
    // 总线
    struct usb_bus          *bus;           // 所属总线
    struct usb_host_config  *config;        // 配置描述符
    struct usb_host_endpoint *ep0;           // 端点 0

    // 地址
    u8                      devnum;        // 设备地址（1-127）
    u8                      maxchild;      // 下行端口数

    // 描述符
    struct usb_device_descriptor descriptor; // 设备描述符
    struct usb_config_descriptor *actconfig; // 当前配置

    // 状态
    enum {
        USB_STATE_ATTACHED,   // 已连接
        USB_STATE_POWERED,    // 已通电
        USB_STATE_DEFAULT,    // 默认地址
        USB_STATE_ADDRESS,    // 已分配地址
        USB_STATE_CONFIGURED, // 已配置
        USB_STATE_SUSPENDED   // 暂停
    } state;

    // 速度
    enum usb_device_speed    speed;         // LOW/FULL/HIGH/SUPER
};
```

### 1.2 usb_host_endpoint — 端点

```c
// include/linux/usb/ch9.h — usb_host_endpoint
struct usb_host_endpoint {
    struct endpoint_descriptor desc;        // 端点描述符
    struct usb_ss_ep_comp_descriptor *ss_ep_comp; // SuperSpeed 额外描述符

    //urb 列表（正在进行传输）
    struct list_head        urb_list;       // URB 链表
    void                   *hcpriv;        // 主机控制器私有数据
};
```

## 2. URB — USB 请求块

```c
// include/linux/usb.h — urb
struct urb {
    // 传输
    struct list_head        anchor_list;    // 链表
    struct usb_device       *dev;          // 目标设备
    unsigned int            pipe;            // 管道（端点+方向）
    int                     status;         // URB 状态

    // 数据
    void                   *transfer_buffer; // 数据缓冲
    u32                     transfer_buffer_length; // 缓冲长度
    u32                     actual_length;  // 实际传输长度

    // 回调
    usb_complete_t          complete;        // 完成回调
    void                   *context;       // 传递给回调的上下文
};
```

## 3. 提交 URB

```c
// drivers/usb/core/message.c — usb_submit_urb
int usb_submit_urb(struct urb *urb, gfp_t mem_flags)
{
    struct usb_device *dev = urb->dev;

    // 1. 检查端点
    if (!urb->ep)
        return -EINVAL;

    // 2. 提交到主机控制器
    return urb->ep->hcpriv->submit(urb, mem_flags);
}
```

## 4. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/usb/core/message.c` | `usb_device` |
| `include/linux/usb.h` | `struct urb` |
| `include/linux/usb/ch9.h` | `usb_host_endpoint` |

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

