# Linux Kernel ALSA (Advanced Linux Sound Architecture) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`sound/core/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. ALSA 概述

**ALSA** 是 Linux 音频子系统，提供：
- PCM（Pulse Code Modulation）音频流
- Mixer（混音器）控制
- MIDI（Musical Instrument Digital Interface）
- 用户空间库（libasound）

---

## 1. 核心数据结构

### 1.1 snd_card — 声卡

```c
// sound/core/init.c — snd_card
struct snd_card {
    int             number;              // 声卡编号
    char            id[16];              // 标识符
    char            driver[16];           // 驱动名
    struct device   *dev;                 // 设备
    struct snd_info_entry *proc_root;     // /proc/asound/ 入口
    struct list_head    devices;          // 此声卡的设备链表
    struct snd_pcm *pcm;                 // PCM 设备
    struct snd_ctl *ctl;                 // 控制设备
};
```

### 1.2 snd_pcm — PCM 设备

```c
// sound/core/pcm.c — snd_pcm
struct snd_pcm {
    struct snd_card   *card;             // 所属声卡
    struct list_head  list;              // PCM 链表
    int               device;             // 设备号
    unsigned int      info_flags;         // SNDRV_PCM_INFO_* 标志
    struct snd_pcm_ops *ops;             // 操作函数表
    struct snd_pcm_str streams[2];       // playback + capture
};

// snd_pcm_str — PCM 流（播放或录音）
struct snd_pcm_str {
    int               stream;              // SNDRV_PCM_STREAM_PLAYBACK/CAPTURE
    struct snd_pcm_substream *substream; // 子流（多个应用可同时打开）
};
```

### 1.3 snd_pcm_substream — 子流

```c
// sound/core/pcm_native.c — snd_pcm_substream
struct snd_pcm_substream {
    struct snd_pcm     *pcm;              // PCM 设备
    int                stream;             // 播放或录音
    struct file        *file;             // 关联的用户空间文件
    void               *private_data;      // 驱动私有数据
    struct snd_pcm_runtime *runtime;     // 运行时配置
    size_t             buffer_bytes_max;   // 最大缓冲区大小
    struct snd_dma_buffer self_buffer;    // DMA 缓冲区
};
```

### 1.4 snd_pcm_runtime — 运行时

```c
// include/sound/pcm.h — snd_pcm_runtime
struct snd_pcm_runtime {
    __u64             boundary;            // 缓冲区边界（ wrap point）
    unsigned int      buffer_size;         // 缓冲区大小（帧数）
    unsigned int      period_size;         // 周期大小（帧数）
    unsigned int      sample_bits;         // 采样位数（8/16/24/32）
    unsigned int      channels;            // 声道数（1=单声，2=立体声）
    unsigned int      rate;               // 采样率（44100/48000 Hz）
    snd_pcm_format_t  format;               // 格式（S16_LE/S32_LE 等）
    __u64             appl_ptr;            // 应用指针（已消费位置）
    __u64             hw_ptr;              // 硬件指针（已生产位置）
    struct snd_pcm_access_t  *access;      // 访问模式（MMAP/INTERLEAVED等）
    struct snd_pcm_substream *trigger_master; // 触发主设备
};
```

---

## 2. PCM 操作流程

### 2.1 open

```c
// sound/core/pcm_native.c — snd_pcm_open
static int snd_pcm_open(struct file *file, struct snd_pcm *pcm, int stream)
{
    // 1. 分配 substream
    struct snd_pcm_substream *ss = kzalloc(sizeof(*ss), GFP_KERNEL);

    // 2. 关联到 PCM 流
    ss->pcm = pcm;
    ss->stream = stream;

    // 3. 调用驱动初始化
    substream->ops->open(substream);

    file->private_data = substream;
}
```

### 2.2 writei / readi — 音频数据传输

```c
// sound/core/pcm_native.c — snd_pcm_writei
static snd_pcm_sframes_t snd_pcm_writei(struct snd_pcm_substream *substream,
                   const void __user *buffer, snd_pcm_uframes_t size)
{
    // 1. 计算可用空间
    avail = snd_pcm_avail_update(substream);

    // 2. 如果可用空间不足，等待（阻塞模式）
    while (avail < size) {
        if (wait_for_avail(substream, &avail) < 0)
            return -EAGAIN;
    }

    // 3. DMA 传输（驱动实现）
    //    substream->ops->copy_user(substream, buffer, size);
    //    或 substream->ops->page(substream) 返回物理页供 DMA

    // 4. 更新应用指针
    runtime->appl_ptr += size;

    return size;
}
```

---

## 3. 中断与 DMA

```c
// DMA 完成后触发中断：
// → snd_pcm_period_elapsed(ss)  // 周期结束
// → wake_up(&runtime->sleep)   // 唤醒等待数据的应用
// → kill_fasync()               // 发送 SIGIO（如果使用 async）

// ALSA DMA 环形缓冲区：
// [period 0][period 1][period 2][period 3]
// 每个 period 触发一次中断 → 用户空间读取一个 period
```

---

## 4. 环形缓冲区管理

```
硬件指针 (hw_ptr)：DMA 已经写到哪（生产端）
应用指针 (appl_ptr)：用户空间已经消费到哪（消费端）

可用空间 = buffer_size - (hw_ptr - appl_ptr) mod boundary
```

---

## 5. 参考

| 文件 | 内容 |
|------|------|
| `sound/core/init.c` | `snd_card` 创建 |
| `sound/core/pcm.c` | PCM 核心结构 |
| `sound/core/pcm_native.c` | `snd_pcm_open`、`snd_pcm_writei` |
| `include/sound/pcm.h` | `struct snd_pcm_runtime` |
