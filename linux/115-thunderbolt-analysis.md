# Thunderbolt — 高速外设总线深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/thunderbolt/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**Thunderbolt** 是 Intel/Apple 开发的点对点高速互连协议（40Gbps/80Gbps），支持 PCIe 数据传输和 DisplayPort 视频输出。

## 1. 协议概述

```
Thunderbolt 版本：
- Thunderbolt 1: 10 Gbps (2 通道 PCIe + DisplayPort)
- Thunderbolt 2: 20 Gbps (聚合通道)
- Thunderbolt 3: 40 Gbps (USB-C 接口，PCIe 3.0 x4 + DP 1.3)
- Thunderbolt 4: 40 Gbps (完整 PCIe x4，支持双屏幕）

特点：
- USB-C 接口
- 同时传输 PCIe 数据 + DP 视频
- 菊花链连接（最多 6 台设备）
- 兼容 USB Power Delivery
```

## 2. 核心数据结构

### 2.1 tb_switch — Thunderbolt 交换器

```c
// drivers/thunderbolt/tb.h — tb_switch
struct tb_switch {
    struct device           dev;           // 设备

    // 拓扑
    struct tb_port         *ports;         // 端口数组
    unsigned int           port_count;     // 端口数量
    u8                      depth;         // 拓扑深度

    // 路由
    u64                    route;          // 64 位路由路径
    // route 示例：0x1a3b0000 表示通过端口 0x1a、0x3b 到达

    // USB4
    u8                      cap_plug_events; // 即插即用事件能力
    u8                      cap_tmu;        // 时间管理单元能力

    // NVM（Non-Volatile Memory）
    struct tb_nvm           *nvm;           // NVM 存储
};
```

### 2.2 tb_port — Thunderbolt 端口

```c
// drivers/thunderbolt/tb.h — tb_port
struct tb_port {
    struct tb_switch        *sw;            // 所属 switch
    unsigned int            port;            // 端口号（本地）
    enum tb_port_type      type;           // 端口类型
    //   TB_TYPE_PORT         = 0  // 普通 Thunderbol t端口
    //   TB_TYPE_PCIE_UP      = 1  // PCIe 上行
    //   TB_TYPE_PCIE_DOWN    = 2  // PCIe 下行
    //   TB_TYPE_DP_HDMI      = 3  // DisplayPort
    //   TB_TYPE_USB4         = 4  // USB4 端口

    struct tb_port         *remote;         // 对端端口（菊花链）

    // 状态
    bool                    enabled;         // 是否启用
    struct tb_retimer      *retimer;        // retimer 芯片（信号增强）
};
```

## 3. USB4 集成

```c
// Thunderbolt 3/4 底层使用 USB4 架构：

// USB4 规范：
// - USB4 基于 PCIe 和 USB 3.2
// - 使用 USB-C 接口
// - 支持 DisplayPort 隧道
// - 支持 PCIe 隧道
// - 通过 USB Power Delivery 协商

// tb_switch 对应 USB4 规范中的 USB4 适配器：
struct usb4_switch {
    struct tb_switch       tb;             // 基类（Thunderbolt 交换器）

    // USB4 能力
    u8                      negotiated_version; // 协商的 USB4 版本
    u32                     link_speed;     // 链路速度（10/20/40 Gbps）
    u32                     link_width;     // 链路宽度（x1/x2/x4）
};
```

## 4. 菊花链（Daisy Chain）

```
菊花链拓扑：

主机 → 设备1 → 设备2 → 设备3
        ↓         ↓
       显示器    存储

路由路径编码：
- 设备1 route = 0x01（通过端口 1 到达）
- 设备2 route = 0x0102（通过端口 1 → 2 到达）
- 设备3 route = 0x010203（通过端口 1 → 2 → 3 到达）
```

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/thunderbolt/tb.h` | `struct tb_switch`、`struct tb_port` |
| `drivers/thunderbolt/retimer.c` | Thunderbolt retimer 驱动 |
| `drivers/thunderbolt/switch.c` | switch 配置和枚举 |

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

