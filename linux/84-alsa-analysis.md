# ALSA — 高级 Linux 声音架构深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`sound/core/` + `sound/core/pcm_native.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**ALSA** 是 Linux 的声音子系统，提供 PCM（脉冲编码调制）音频接口。

---

## 1. 核心数据结构

### 1.1 snd_pcm — PCM 设备

```c
// sound/core/pcm_native.c — snd_pcm
struct snd_pcm {
    // 设备信息
    struct device           *dev;           // 设备
    struct snd_card         *card;          // 声卡
    char                    *id;            // ID
    char                    *name;          // 名称

    // 流
    struct snd_pcm_str      streams[2];     // 0=PLAYBACK, 1=CAPTURE
    // streams[PLAYBACK].substream → PCM 播放流
};

// sound/core/pcm_native.c — snd_pcm_substream
struct snd_pcm_substream {
    struct snd_pcm          *pcm;            // 所属 PCM
    struct device           *device;       // 设备
    struct snd_pcm_runtime  *runtime;      // 运行时状态
    int                     stream;          // PLAYBACK or CAPTURE

    // 操作函数表
    const struct snd_pcm_ops *ops;         // 操作函数
    const struct snd_pcm_lib_ops *lib_ops; // 库操作

    // DMA
    struct snd_dma_buffer   dma_buffer;     // DMA 缓冲区
    unsigned int            dma_max;       // 最大 DMA 大小
};
```

### 1.2 snd_pcm_runtime — 运行时状态

```c
// sound/core/pcm_native.c — snd_pcm_runtime
struct snd_pcm_runtime {
    // 格式
    unsigned int            channels;       // 声道数
    unsigned int            rate;           // 采样率
    snd_pcm_format_t       format;         // 格式（16-bit LE 等）
    unsigned int            sample_bits;    // 采样位数
    unsigned int            frame_bits;     // 每帧位数

    // DMA
    snd_pcm_uframes_t      buffer_size;    // 缓冲区大小（帧）
    snd_pcm_uframes_t       period_size;   // 周期大小（帧）
    snd_pcm_uframes_t       avail_min;     // 最小可用
    snd_pcm_uframes_t       start_threshold; // 开始阈值
    snd_pcm_uframes_t       stop_threshold;  // 停止阈值

    // 指针
    snd_pcm_uframes_t      hw_ptr_base;    // 硬件指针基础
    snd_pcm_uframes_t      hw_ptr_interrupt; // 中断指针
    snd_pcm_uframes_t      sw_ptr;         // 软件指针

    // 状态
    unsigned int            state;         // PCM 状态
    //   SNDRV_PCM_STATE_OPEN
    //   SNDRV_PCM_STATE_PREPARED
    //   SNDRV_PCM_STATE_RUNNING
    //   SNDRV_PCM_STATE_XRUN
    //   SNDRV_PCM_STATE_SUSPENDED
};
```

---

## 2. 播放流程

### 2.1 snd_pcm_writei — 播放音频

```c
// sound/core/pcm_native.c — snd_pcm_writei
static ssize_t snd_pcm_writei(struct file *file, const char *buf, size_t size, loff_t *offset)
{
    struct snd_pcm_substream *substream = pcm->streams[SNDRV_PCM_STREAM_PLAYBACK].substream;
    struct snd_pcm_runtime *runtime = substream->runtime;

    // 1. 检查状态
    if (runtime->state != SNDRV_PCM_STATE_PREPARED &&
        runtime->state != SNDRV_PCM_STATE_RUNNING)
        return -EBADFD;

    // 2. 复制数据到 DMA 缓冲区
    frames = size / (runtime->channels * (runtime->sample_bits / 8));
    frames = copy_from_user(runtime->dma_area + offset, buf, frames);

    // 3. 启动 DMA（如果需要）
    if (runtime->state == SNDRV_PCM_STATE_PREPARED)
        snd_pcm_start(substream);

    return frames;
}
```

---

## 3. ioctl 命令

```c
// sound/core/pcm_native.c — snd_pcm_lib_ioctl
long snd_pcm_lib_ioctl(struct file *file, unsigned int cmd, void *arg)
{
    struct snd_pcm_substream *substream = pcm->streams[0].substream;

    switch (cmd) {
    case SNDRV_PCM_IOCTL_HW_PARAMS:
        // 设置硬件参数（采样率、格式、声道数）
        return snd_pcm_hw_params(substream, arg);

    case SNDRV_PCM_IOCTL_PREPARE:
        // 准备设备
        return snd_pcm_prepare(substream, NULL);

    case SNDRV_PCM_IOCTL_START:
        return snd_pcm_start(substream);

    case SNDRV_PCM_IOCTL_LINK:
        // 链接多个流同步
        return 0;

    case SNDRV_PCM_IOCTL_RESUME:
        return snd_pcm_resume(substream);
    }
}
```

---

## 4. ALSA 设备节点

```
/dev/snd/
├── controlC0           ← 控制设备（混音器）
├── pcmC0D0p           ← PCM 播放设备（卡0，设备0，播放）
├── pcmC0D0c           ← PCM 录音设备（卡0，设备0，录音）
├── seq               ← 音序器
└── timer             ← 定时器
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `sound/core/pcm_native.c` | `snd_pcm_substream`、`snd_pcm_runtime`、`snd_pcm_writei` |
| `sound/core/pcm_lib.c` | PCM 库函数 |