# Linux Kernel ALSA (Advanced Linux Sound Architecture) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`sound/core/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：PCM、substream、hw_params、hw_pointer、DMA

## 0. ALSA 架构

```
用户空间（alsa-lib）
     ↓
alsa-driver（kernel）
     ↓
  ├─ PCM（音频流）
  ├─ Mixer（混音器）
  └─ Raw MIDI（MIDI 设备）
     ↓
硬件驱动（AC97、Intel HDA、USB Audio）
```

## 1. 核心数据结构

### 1.1 snd_pcm — PCM 设备

```c
// sound/core/pcm.c — snd_pcm
struct snd_pcm {
    struct snd_card   *card;             // 声卡
    int               device;             // 设备号
    unsigned int      info_flags;         // SNDRV_PCM_INFO_* 标志
    struct snd_pcm_str streams[2];       // [0]=playback, [1]=capture
    void             *private_data;       // 驱动私有数据
};
```

### 1.2 snd_pcm_str — PCM 流

```c
// sound/core/pcm.c — snd_pcm_str
struct snd_pcm_str {
    int               stream;              // SNDRV_PCM_STREAM_PLAYBACK
    struct snd_pcm_substream *substream;  // 当前活跃的 substream
    struct snd_pcm_ops *ops;             // 流操作
    struct snd_pcm_hw_constraints *hw_constraints; // 硬件约束
};
```

### 1.3 snd_pcm_substream — 子流

```c
// sound/core/pcm_native.c — snd_pcm_substream
struct snd_pcm_substream {
    struct snd_pcm     *pcm;              // PCM 设备
    int                stream;             // playback / capture
    const char         *name;             // "front" / "rear" 等
    size_t             buffer_bytes_max;   // 最大缓冲区
    struct snd_dma_buffer self_buffer;   // DMA 缓冲区
    struct snd_pcm_runtime *runtime;     // 运行时配置（设置后有效）
    void               *private_data;      // 驱动私有数据
    struct snd_pcm_ops *ops;             // substream 操作
};
```

### 1.4 snd_pcm_runtime — 运行时配置

```c
// include/sound/pcm.h — snd_pcm_runtime
struct snd_pcm_runtime {
    /* 格式信息 */
    snd_pcm_format_t   format;            // SNDRV_PCM_FORMAT_S16_LE
    unsigned int        channels;         // 声道数（1/2）
    unsigned int        rate;             // 采样率（44100/48000 Hz）
    snd_pcm_subformat  subformat;         // 格式子类型

    /* 缓冲区信息 */
    snd_pcm_uframes_t  buffer_size;     // 缓冲区大小（帧数）
    snd_pcm_uframes_t  period_size;      // 周期大小（帧数）
    unsigned int        period_bytes;      // 周期字节数
    unsigned int        buffer_bytes;      // 缓冲区字节数

    /* 指针 */
    snd_pcm_uframes_t  hw_ptr;          // 硬件指针（DMA 已写入位置）
    snd_pcm_uframes_t  hw_ptr_base;     // 硬件指针基址
    snd_pcm_uframes_t  appl_ptr;        // 应用指针（已消费位置）
    snd_pcm_sframes_t  avail_max;       // 最大可用帧数

    /* DMA 缓冲区 */
    void               *dma_area;        // DMA 缓冲区虚拟地址
    snd_pcm_uframes_t  boundary;         // 环形缓冲边界

    /* DMA 访问 */
    struct snd_dma_buffer *dma_buffer_p; // DMA 缓冲区描述
};
```

## 2. PCM 操作流程

### 2.1 hw_params — 设置硬件参数

```c
// sound/core/pcm_native.c — snd_pcm_hw_params
static int snd_pcm_hw_params(struct snd_pcm_substream *substream,
                struct snd_pcm_hw_params *params)
{
    // 1. 复制参数到 runtime
    substream->runtime->format = params_format(params);
    substream->runtime->channels = params_channels(params);
    substream->runtime->rate = params_rate(params);
    substream->runtime->buffer_size = params_buffer_size(params);
    substream->runtime->period_size = params_period_size(params);

    // 2. 调用驱动设置
    if (substream->ops->hw_params)
        substream->ops->hw_params(substream, params);

    // 3. 分配 DMA 缓冲区
    snd_pcm_lib_malloc_pages(substream, params_buffer_bytes(params));
}
```

### 2.2 writei — 播放

```c
// sound/core/pcm_native.c — snd_pcm_writei
static snd_pcm_sframes_t snd_pcm_writei(struct snd_pcm_substream *substream,
                const void *buffer, snd_pcm_uframes_t size)
{
    struct snd_pcm_runtime *runtime = substream->runtime;

    // 1. 计算可用空间
    avail = snd_pcm_avail_update(substream);
    if (avail < size) {
        // 空间不足，等待
        wait_event_interruptible_timeout(runtime->sleep, ...);
    }

    // 2. 复制数据到 DMA 缓冲区
    //    驱动通过 runtime->dma_area 访问
    //    runtime->dma_area + runtime->appl_ptr * frame_bytes

    // 3. 更新应用指针
    runtime->appl_ptr += size;

    // 4. 启动 DMA
    if (substream->ops->trigger)
        substream->ops->trigger(substream, SNDRV_PCM_TRIGGER_START);

    return size;
}
```

## 3. 中断与 DMA

```c
// DMA 完成后触发中断：
// → snd_pcm_period_elapsed(substream)
// → 唤醒等待的应用（runtime->sleep）
// → 更新 runtime->hw_ptr

// 环形缓冲区管理：
// DMA 指针（hw_ptr）：已写入位置
// 应用指针（appl_ptr）：已消费位置
// 可用 = (hw_ptr - appl_ptr) mod boundary
```

## 4. 参考

| 文件 | 函数 |
|------|------|
| `sound/core/pcm.c` | PCM 核心 |
| `sound/core/pcm_native.c` | `snd_pcm_hw_params`、`snd_pcm_writei` |
| `include/sound/pcm.h` | `struct snd_pcm_runtime` |


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

