# 164-cfg80211_mac80211 — 无线网络框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`net/wireless/` + `net/mac80211/`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

## 0. 概述

**cfg80211** 是 Linux 无线配置的通用 API（nl80211），**mac80211** 是软件无线网卡驱动框架（SoftMAC）。用户空间通过 nl80211 与 cfg80211 交互，cfg80211 再与 mac80211 或硬件驱动通信。

## 1. 三层架构

```
用户空间
    │
    │ nl80211（Netlink）
    ▼
cfg80211（通用配置 API）
    │
    │ cfg80211_ops
    ├─→ mac80211（SoftMAC 驱动框架）
    │       │
    │       ▼
    │   硬件驱动（如 iwlwifi, ath9k）
    │
    └─→ 硬件驱动直接实现 cfg80211_ops（如 brcmfmac）

架构类型：
  FullMAC：硬件自己实现 cfg80211_ops（如 Intel WiFi）
  mac80211：软件实现 802.11 MAC，硬件只做 PHY
  Legacy：硬件自己处理所有 MAC（如早期 cardbus）
```

## 2. cfg80211 核心结构

### 2.1 struct cfg80211_ops — cfg80211 操作

```c
// include/net/cfg80211.h — cfg80211_ops
struct cfg80211_ops {
    // 扫描
    int  (*scan)(struct wiphy *wiphy, struct cfg80211_scan_request *request);

    // 连接
    int  (*connect)(struct wiphy *wiphy, struct net_device *dev,
                    struct cfg80211_connect_params *sme);
    int  (*disconnect)(struct wiphy *wiphy, struct net_device *dev,
                         u16 reason_code);

    // IBSS / AP
    int  (*join_ibss)(struct wiphy *wiphy, struct net_device *dev,
                       struct cfg80211_ibss_params *params);
    int  (*leave_ibss)(struct wiphy *wiphy, struct net_device *dev);

    // AP 模式
    int  (*add_station)(struct wiphy *wiphy, struct net_device *dev,
                          const u8 *mac, struct station_parameters *params);
    int  (*del_station)(struct wiphy *wiphy, struct net_device *dev,
                          struct station_del_parameters *params);

    // TX
    int  (*tx)(struct wiphy *wiphy, struct net_device *dev,
                  struct cfg80211_mgmt_tx_params *params);

    // 帧处理
    int  (*set_channel)(struct wiphy *wiphy, struct net_device *dev,
                          struct ieee80211_channel *channel);
};
```

### 2.2 struct wiphy — 无线 PHY 设备

```c
// include/net/cfg80211.h — wiphy
struct wiphy {
    // 设备信息
    struct device           *dev;              // 所属设备
    char                  *priv;             // 驱动私有数据

    // 频段
    struct ieee80211_supported_band *bands[NUM_NL80211_BANDS];
    //   NL80211_BAND_2GHZ
    //   NL80211_BAND_5GHZ
    //   NL80211_BAND_6GHZ
    //   NL80211_BAND_60GHZ

    // 接口类型
    enum nl80211_iftype  *interface_modes;    // BIT(NL80211_IFTYPE_*)
    //   NL80211_IFTYPE_STATION
    //   NL80211_IFTYPE_AP
    //   NL80211_IFTYPE_ADHOC
    //   NL80211_IFTYPE_MONITOR

    // 特性
    u32                   features;              // NL80211_FEATURE_*

    // 操作
    const struct cfg80211_ops *ops;
};
```

## 3. mac80211 核心结构

### 3.1 struct ieee80211_hw — mac80211 硬件

```c
// net/mac80211/ieee80211_i.h — ieee80211_hw
struct ieee80211_hw {
    struct wiphy           *wiphy;             // 导出 cfg80211 wiphy

    // 帧处理
    const struct ieee80211_ops *ops;           // 硬件操作

    // 硬件信息
    u32                   queues;              // TX 队列数
    u16                   max_rx_ampdu_len;   // 最大 AMPDU 长度
    u16                   max_tx_ampdu_len;
    u16                   max_listen_interval;

    // 本地
    struct ieee80211_local *local;             // 软件 MAC 状态
};
```

### 3.2 struct ieee80211_local — 本地 MAC 状态

```c
// net/mac80211/ieee80211_i.h — ieee80211_local
struct ieee80211_local {
    struct ieee80211_hw   *hw;

    // 帧处理
    struct sta_info       *sta_list;          // 已关联的 STA
    struct ps_filter      *ps_filter;         // 功率节省过滤

    // TX
    struct ieee80211_txq *txqs[IEEE80211_NUM_ACS]; // TX 队列
    struct tasklet_struct tx_pending_tasklet;   // TX 底部

    // 接收
    struct tasklet_struct rx_tasklet;          // RX 底部
    struct sk_buff_head  skb_queue;            // 待处理帧
};
```

## 4. 帧处理流程

### 4.1 RX 路径

```
硬件接收帧：
    ↓
ieee80211_rx_napi()  ← NAPI 轮询
    ↓
ieee80211_invoke_rx_handlers()  ← 调用 RX handlers
    ↓
drv_rx() → 驱动回调
    ↓
ieee80211_deliver_skb()  ← 交给协议栈
    ↓
netif_receive_skb()  ← 进入普通网络栈
```

### 4.2 TX 路径

```
普通帧：
  dev_queue_xmit() → ieee80211_tx() → drv_tx() → 硬件

Mgmt 帧：
  cfg80211_mgmt_tx() → ieee80211_tx_mgmt() → drv_tx()
```

## 5. nl80211 消息类型

```bash
# 用户空间工具：iw
iw dev wlan0 scan                    # 扫描
iw dev wlan0 connect SSID             # 连接
iw dev wlan0 disconnect              # 断开
iw dev wlan0 link                   # 查看状态

# Hostapd（AP 模式）：
hostapd /etc/hostapd.conf

# WPA_Supplicant：
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
```

## 6. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/net/cfg80211.h` | `struct cfg80211_ops`、`struct wiphy` |
| `net/mac80211/ieee80211_i.h` | `struct ieee80211_hw`、`struct ieee80211_local` |
| `net/mac80211/main.c` | `ieee80211_register_hw` |
| `net/wireless/core.c` | `cfg80211_init`、`wiphy_register` |

## 7. 西游记类喻

**cfg80211 + mac80211** 就像"天庭的无线驿站系统"——

> cfg80211 像无线驿站的前台，负责接待（配置）和分配任务（扫描、连接）。mac80211 像驿站的内部运作部门（软件 MAC），负责处理各种无线协议——加密、速率控制、帧分段。每个硬件驱动（如 Intel WiFi）就像一个具体的快递员，有的能自己处理所有事务（FullMAC），有的需要驿站内部协调（mac80211）。nl80211 像驿站和天庭通信的专线（Netlink），前台收到任务后，通过这条专线传给内部部门处理。

## 8. 关联文章

- **netdevice**（article 137）：无线网卡也是 netdevice
- **无线安全**（相关）：WPA/WPA2 在 cfg80211 层面实现

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

