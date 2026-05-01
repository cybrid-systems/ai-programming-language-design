# 117-CCW-zFCP — IBM 大机通道深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/s390/scsi/zfcp_*.c`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**CCW（Channel Command Word）** 和 **zFCP（SCSI over Fibre Channel on IBM mainframe）** 是 IBM 大型机（s390x 架构）的 I/O 通道接口。CCW 是通道命令字，zFCP 是在 Fibre Channel 上跑 SCSI 协议。

## 1. CCW — Channel Command Word

### 1.1 CCW 结构

```c
// arch/s390/include/asm/ccwdev.h — ccw1
struct ccw1 {
    u8  cmd_code;      // 命令码（IDA/READ/WRITE/SENSE 等）
    u32 cda;           // 数据地址（Channel Data Address）
    u8  flags;         // CCW_FLAGS_* 标志
    u16 count;         // 传输字节数
};

// CCW 标志：
//   CCW_FLAG_SLI   = 不要在异常时终止
//   CCW_FLAG_CC     = 连续命令（chained CCW）
//   CCW_FLAG_SUSPEND = 挂起当前通道程序
```

### 1.2 通道程序

```c
// CCW 通道程序 = 多个 CCW 组成的链表
// 例如：READ + SENSE 连续执行
struct ccw1 program[] = {
    { .cmd_code = CCW_CMD_READ, .cda = buf, .count = 512, .flags = CCW_FLAG_CC },
    { .cmd_code = CCW_CMD_SENSE, .cda = sense, .count = 64, .flags = 0 },
};
```

## 2. zFCP — SCSI over Fibre Channel

### 2.1 struct zfcp_adapter — 适配器

```c
// drivers/s390/scsi/zfcp_fsf.h — zfcp_adapter
struct zfcp_adapter {
    struct ccw_device       *ccw_device;      // CCW 设备
    struct fsf_qtcb_bottom_port *stats;    // 统计

    // 端口列表
    struct list_head        port_list;
    spinlock_t              port_list_lock;

    // 硬件地址
    u64                     wwpn;             // 世界-wide 端口名
    u64                     port_id;         // FC 端口 ID

    // 状态
    unsigned long           status;
    struct work_struct      scan_ports_work;  // 端口扫描
};
```

### 2.2 struct zfcp_port — 端口

```c
// drivers/s390/scsi/zfcp_fsf.h — zfcp_port
struct zfcp_port {
    struct list_head        list;             // 接入 adapter
    struct zfcp_adapter    *adapter;         // 所属适配器

    u64                     wwpn;             // 端口名
    u64                     port_id;         // FC 端口 ID

    // LUN 列表
    struct list_head        lun_list;
    spinlock_t              lun_list_lock;
};
```

## 3. FSF（Fabric Shortcut Path）

### 3.1 zfcp_fsf — FSF 请求

```c
// drivers/s390/scsi/zfcp_fsf.c — zfcp_fsf_request
// FSF 是 zFCP 和硬件之间的命令协议
// 通过 CCW 通道程序与适配器通信

struct fsf_qtcb {
    struct fsf_byte_order   byte_order;
    struct fsf_qtcb_header header;
    union {
        struct fsf_qtcb_bottom_port bottom;
        struct fsf_qtcb_bottom_port_status status;
    };
};

// FSF 命令：
//   FSF_QTCB_OPEN_PORT         = 打开 FC 端口
//   FSF_QTCB_CLOSE_PORT        = 关闭端口
//   FSF_QTCB_SEND_ELS          = 发送 ELS（Extended Link Services）
//   FSF_QTCB_FCP_CMND          = FCP 命令（读写 SCSI）
```

## 4. SCSI 命令流程

```
用户：scsi_command(read LUN)
        ↓
Linux SCSI 中层
        ↓
zfcp_scsi_command()        ← zFCP 处理
        ↓
zfcp_fsf_fcp_cmnd()       ← 构造 FCP_CMND
        ↓
ccw_device_start()        ← 通过 CCW 通道发送到主机
        ↓
Fibre Channel 传输
        ↓
目标存储返回 DATA + STATUS
        ↓
ccw_device_intr()         ← 中断处理
        ↓
向上返回给 SCSI 层
```

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `arch/s390/include/asm/ccwdev.h` | `struct ccw1`、`struct ccw` |
| `drivers/s390/scsi/zfcp_fsf.h` | `struct zfcp_adapter`、`struct zfcp_port` |
| `drivers/s390/scsi/zfcp_fsf.c` | `zfcp_fsf_fcp_cmnd`、`zfcp_fsf_request` |

## 6. 西游记类比

**CCW/zFCP** 就像"天庭的专用快递通道"——

> IBM 大型机（s390x）的 I/O 像专用物流通道，和普通的驿道（PCI）完全不同。CCW（Channel Command Word）就像快递包裹的标签，标注了命令类型（读/写/感知）、数据地址、长度。多个 CCW 组成一个通道程序，就像一套物流指令。zFCP 则是在光纤通道（Fibre Channel）上跑 SCSI 协议——就像用专用光纤快递公司来送 SCSI 命令。好处是：专用通道，不堵车，适合大型机那种高吞吐量的场景。

## 7. 关联文章

- **PCI**（article 116）：普通服务器的 I/O 总线
- **SCSI**（相关）：zFCP 是 SCSI 在大型机上的实现

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

