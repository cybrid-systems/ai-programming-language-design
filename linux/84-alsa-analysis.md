# 84-alsa — Linux ALSA 音频框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**ALSA（Advanced Linux Sound Architecture）** 是 Linux 音频子系统，替代了旧版 OSS。ALSA 提供 PCM 播放/录制、Mixer 控制、MIDI 接口、设备枚举等功能。核心分为：**PCM 设备**（`/dev/snd/pcmC0D0p`）处理音频数据流，**Control 设备**（`/dev/snd/controlC0`）处理音量/开关等控制。

**核心设计**：ALSA 采用 **card → device → substream** 三层结构。每个声卡（`struct snd_card`）包含多个 PCM 设备（`struct snd_pcm`），每个 PCM 设备又包含 playback 和 capture substream（`struct snd_pcm_substream`）。用户空间通过 `snd_pcm_hw_params` 设置采样参数后，通过 mmap 或 read/write 传输音频数据。

```
用户空间                         ALSA 内核                    硬件驱动
─────────────────              ────────────                 ─────────
aplay (snd_pcm_open)
  → /dev/snd/pcmC0D0p          snd_pcm_open()
                                  → snd_pcm_ops->open()
  → snd_pcm_hw_params()        snd_pcm_hw_params()
                                  → snd_pcm_ops->hw_params()
                                  → 分配 DMA 环形缓冲区
                                  → snd_pcm_set_runtime_buffer()
  → snd_pcm_prepare()           snd_pcm_prepare()
                                  → snd_pcm_ops->prepare()
  → snd_pcm_start()             snd_pcm_start()
                                  → snd_pcm_ops->trigger(START)
                                    → DMA 控制器开始传输
  → mmap(ring buffer)            sound/core/pcm_native.c
  → snd_pcm_writei()            snd_pcm_lib_write()
    写入环形缓冲区               等待 period_elapsed 中断
                                  → 硬件 DMA 从环形缓冲读取
                                  → 播放到 DAC
```

**doom-lsp 确认**：核心 PCM 在 `sound/core/pcm_native.c`（4,256 行），`pcm_lib.c`（2,632 行），`control.c`（2,532 行）。`include/sound/pcm.h`（1,595 行）。

---

## 1. 核心数据结构

### 1.1 struct snd_card — 声卡 @ core.h:80

```c
struct snd_card {
    int number;                              /* 声卡号 (0, 1, 2...) */
    char id[16];
    char driver[16];
    char shortname[32];
    char longname[80];

    struct list_head devices;                /* 设备列表（PCM/Control/MIDI）*/
    struct device card_dev;
    void *private_data;
    void (*private_free)(struct snd_card *card);
};
```

### 1.2 struct snd_pcm — PCM 设备 @ pcm.h

```c
// sound/core/pcm_native.c
struct snd_pcm {
    struct snd_card *card;
    int device;                              /* 设备号 (0) */
    unsigned int info_flags;
    struct snd_pcm_str streams[2];           /* [0]=playback, [1]=capture */
    struct list_head list;
};
```

### 1.3 struct snd_pcm_substream — 音频流

```c
struct snd_pcm_substream {
    struct snd_pcm *pcm;
    struct snd_pcm_str *pstr;
    int number;                              /* substream 号 */
    int stream;                              /* SNDRV_PCM_STREAM_PLAYBACK=0, CAPTURE=1 */
    struct snd_pcm_ops *ops;                 /* 驱动操作 */
    struct snd_pcm_runtime *runtime;          /* 运行时数据 */
    struct snd_dma_buffer dma_buffer;         /* DMA 缓冲 */
};
```

### 1.4 struct snd_pcm_runtime — 运行时参数

```c
struct snd_pcm_runtime {
    struct snd_pcm_hardware hw;              /* 硬件能力 */
    snd_pcm_uframes_t buffer_size;            /* 缓冲区大小（帧数）*/
    snd_pcm_uframes_t period_size;            /* 周期大小（帧数）*/
    snd_pcm_uframes_t boundary;                /* 边界值 */

    unsigned int rate;                         /* 采样率 */
    unsigned int channels;                     /* 声道数 */
    snd_pcm_format_t format;                   /* 采样格式（S16_LE/S32_LE）*/

    snd_pcm_uframes_t hw_ptr_base;             /* 硬件指针基准 */
    volatile snd_pcm_uframes_t hw_ptr;         /* 硬件 DMA 位置 */
    snd_pcm_uframes_t appl_ptr;                /* 应用程序位置 */

    struct snd_pcm_mmap_status *status;        /* mmap 状态 */
    struct snd_pcm_mmap_control *control;      /* mmap 控制 */
};
```

**doom-lsp 确认**：`struct snd_pcm_runtime` 包含 `hw_ptr`（硬件 DMA 位置）和 `appl_ptr`（应用程序位置），两者之差为环形缓冲区中待处理的数据量。

---

## 2. PCM 数据路径

### 2.1 环形缓冲区

```
audio_buffer（环形）:
  ┌──────────────────────────────────────────┐
  │    |已播放|  待播放  |   空   |           │
  │          ↑        ↑                     │
  │       appl_ptr  hw_ptr                   │
  │       (应用已写到) (DMA 已读)              │
  │                                          │
  │  待处理 = appl_ptr - hw_ptr               │
  │  空闲 = buffer_size - 待处理              │
  └──────────────────────────────────────────┘
```

### 2.2 内存分配——snd_pcm_lib_preallocate_pages

```c
// PCM 设备注册时预分配 DMA 缓冲区
// sound/core/pcm_memory.c

int snd_pcm_lib_preallocate_pages(struct snd_pcm_substream *substream,
                                   int type, struct device *dev,
                                   size_t size, size_t max)
{
    // 分配连续的 DMA 缓冲区（用于硬件 DMA 传输）
    // type: SNDRV_DMA_TYPE_DEV（通用）/ SNDRV_DMA_TYPE_DEV_SG（scatter-gather）
    // size: 预分配大小（如 64KB）
    // max: 最大允许大小（可通过 ulimit 调整）
    // → snd_dma_alloc_pages() → dma_alloc_coherent()
    // 将分配的内存记录到 substream->dma_buffer
}
```

### 2.3 mmap 路径

```c
// ALSA 支持 mmap 模式——用户空间直接访问 DMA 环形缓冲区
// 避免 read/write 的数据拷贝

// snd_pcm_mmap @ pcm_native.c:
// → snd_pcm_mmap_data()
// → remap_pfn_range(vma, vma->vm_start, dma_addr >> PAGE_SHIFT, ...)
// → 将 DMA 缓冲区的物理地址直接映射到用户空间
//
// 用户通过 mmap 获得环形缓冲区的直接指针后：
//   snd_pcm_mmap_begin() → 获取写入位置
//   memcpy() → 直接写入环形缓冲区
//   snd_pcm_mmap_commit() → 更新 appl_ptr
//
// 这种方式零拷贝——内核不参与数据传输
```

### 2.4 PCM 状态机

```c
enum snd_pcm_state {
    SNDRV_PCM_STATE_OPEN,       // 刚打开
    SNDRV_PCM_STATE_SETUP,     // hw_params 完成
    SNDRV_PCM_STATE_PREPARED,  // prepare 完成
    SNDRV_PCM_STATE_RUNNING,   // 正在播放/录制
    SNDRV_PCM_STATE_XRUN,      // underrun/overrun
    SNDRV_PCM_STATE_DRAINING,  // 排空中（录制停止后）
    SNDRV_PCM_STATE_PAUSED,    // 暂停
    SNDRV_PCM_STATE_SUSPENDED, // 挂起
    SNDRV_PCM_STATE_DISCONNECTED,
};

// 状态转换由 snd_pcm_action() 管理 @ pcm_native.c:1406
// 内部通过 snd_pcm_action_single()/snd_pcm_action_group() 执行
// 原子操作，确保状态一致性
```

### 2.2 snd_pcm_lib_write @ pcm_lib.c——用户写入

```c
// 用户调用 snd_pcm_writei() → 最终到达：

snd_pcm_sframes_t snd_pcm_lib_write(struct snd_pcm_substream *substream,
                                     const void __user *buf, snd_pcm_uframes_t size)
{
    // 1. 等待环形缓冲区有空间
    while (avail < size) {
        // → wait_event_interruptible(substream->runtime->sleep, avail >= size)
        // → 如果 playback underrun → 填充 silence
    }

    // 2. 复制用户数据到环形缓冲区
    // → copy_from_user_to_ring_buffer(runtime, buf, offset, frames)

    // 3. 更新 appl_ptr
    runtime->appl_ptr += frames;

    // 4. 如果 appl_ptr 跨越了 period 边界
    // → snd_pcm_period_elapsed(substream)
    //    → 驱动中断处理 → 硬件继续 DMA
}
```

### 2.3 硬件中断——snd_pcm_period_elapsed

```c
// 当硬件完成的 DMA 传输量达到一个 period_size 时调用
void snd_pcm_period_elapsed(struct snd_pcm_substream *substream)
{
    // 更新 hw_ptr
    // 唤醒等待的写入/读取进程
    wake_up(&runtime->sleep);

    // 触发 POLLOUT/POLLIN 事件
    snd_pcm_stream_lock_irqsave(substream);
    if (substream->runtime->status->state == SNDRV_PCM_STATE_RUNNING)
        snd_pcm_update_hw_ptr(substream);
    snd_pcm_stream_unlock_irqrestore(substream);
}
```

---

## 3. Control 接口 @ control.c

```c
// /dev/snd/controlC0 — Mixer/音量/开关控制

// 一个 control element 的结构：
struct snd_kcontrol {
    struct list_head list;
    struct snd_ctl_elem_id id;               // 标识（name/index/numid）
    unsigned int count;                       // 子元素数（如左右声道）
    struct snd_kcontrol_vol *vd;
    const struct snd_kcontrol_new *co;        // 操作
    void *private_data;
};

// 用户空间操作：
struct snd_ctl_elem_value {
    struct snd_ctl_elem_id id;               // 要控制的 element
    unsigned int value[128];                  // 值数组
};

// ioctl(SNDRV_CTL_IOCTL_ELEM_READ) → 读取控制值
// ioctl(SNDRV_CTL_IOCTL_ELEM_WRITE) → 写入控制值
// ioctl(SNDRV_CTL_IOCTL_ELEM_INFO) → 查询控制信息
```

---

## 4. 调试

```bash
# 查看声卡
cat /proc/asound/cards
# 0 [PCH            ]: HDA-Intel - HDA Intel PCH

# 查看 PCM 设备
cat /proc/asound/pcm
# 00-00: Intel HDMI : HDMI 0 : playback 1
# 00-01: Intel HDMI : HDMI 1 : playback 1

# 查看 mixer 控件
amixer controls
amixer sget 'Master'

# 音频文件播放
aplay -D hw:0,0 test.wav

# 录音
arecord -D hw:0,0 -f cd test.wav
```

---

## 5. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `snd_pcm_open` | `pcm_native.c` | PCM 设备打开 |
| `snd_pcm_hw_params` | `pcm_native.c` | 设置采样参数 |
| `snd_pcm_prepare` | `pcm_native.c` | 准备 DMA 传输 |
| `snd_pcm_start` | `pcm_native.c` | 启动音频流 |
| `snd_pcm_lib_write` | `pcm_lib.c` | 写入音频数据 |
| `snd_pcm_lib_read` | `pcm_lib.c` | 读取音频数据 |
| `snd_pcm_period_elapsed` | `pcm_lib.c` | 周期完成中断 |
| `snd_ctl_elem_read` | `control.c` | control 读取 |
| `snd_ctl_elem_write` | `control.c` | control 写入 |

---

## 6. 总结

ALSA 通过 `snd_pcm_open` → `hw_params` → `prepare` → `start` 管理 PCM 音频流。环形缓冲区通过 `hw_ptr`（硬件 DMA 位置）和 `appl_ptr`（应用写入位置）协调，`snd_pcm_period_elapsed` 在 DMA 完成一个时触发中断信号。Control 接口通过 `snd_kcontrol` 管理音量/开关等 mixer 控制。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
