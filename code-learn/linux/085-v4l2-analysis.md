# 085-v4l2 — Linux Video4Linux2 视频框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码 | 使用 doom-lsp 进行逐行符号解析

## 0. 概述

**V4L2（Video4Linux2）** 是 Linux 内核的视频设备驱动框架，覆盖摄像头、电视调谐器、视频编解码器等。用户空间通过 `/dev/videoN` 设备的 ioctl 接口控制设备。

**doom-lsp 确认**：`drivers/media/v4l2-core/v4l2-dev.c`（设备注册），`drivers/media/v4l2-core/v4l2-ioctl.c`（ioctl 处理）。

---

## 1. 核心数据结构

### 1.1 `struct video_device`——V4L2 设备

```c
struct video_device {
    const struct v4l2_file_operations *fops;   // 文件操作（open/release/read/write/ioctl/mmap）
    const struct v4l2_ioctl_ops       *ioctl_ops; // ioctl 操作表（querycap/s_fmt/s_buf/qbuf/dqbuf...）
    struct device                     dev;     // 嵌入式 device 结构
    struct v4l2_device                *v4l2_dev; // 父 V4L2 设备
    unsigned int                      index;   // 设备索引（/dev/videoN 的 N）
    atomic_t                          prio;    // 优先级
    unsigned long                     flags;   // V4L2_FL_* 标志
};
```

### 1.2 `struct vb2_queue`——视频缓冲区队列

V4L2 的核心是**缓冲区队列**机制（`videobuf2`）：

```c
struct vb2_queue {
    enum v4l2_buf_type         type;           // V4L2_BUF_TYPE_VIDEO_CAPTURE 等
    unsigned int               io_modes;       // VB2_MMAP / VB2_USERPTR / VB2_DMABUF
    const struct vb2_ops       *ops;           // queue_setup/buf_prepare/buf_queue/start_streaming/stop_streaming

    struct vb2_buffer          *bufs[VB2_MAX_FRAMES]; // 缓冲区数组
    unsigned int               num_buffers;    // 缓冲区数量

    struct list_head           queued_list;    // 已入队（等待硬件）缓冲区
    unsigned int               queued_count;
    struct list_head           done_list;      // 已完成（等待用户空间）缓冲区
    unsigned int               done_count;
    spinlock_t                 done_lock;
    wait_queue_head_t          done_wq;        // DQBUF 等待队列

    unsigned int               streaming:1;    // 是否正在流媒体传输
    ...
};
```

## 2. 完整数据流

### 2.1 摄像头捕获循环

```
用户空间：
  fd = open("/dev/video0")
  ioctl(VIDIOC_QUERYCAP, &cap)              // 查询设备能力
  ioctl(VIDIOC_S_FMT, &fmt)                 // 设置格式（1920x1080, YUYV）
  ioctl(VIDIOC_REQBUFS, &req)               // 分配缓冲区（4 个 MMAP buffer）

  for (i = 0; i < 4; i++)
      ioctl(VIDIOC_QUERYBUF, &buf)          // 查询缓冲区地址
      mmap(NULL, buf.length, PROT_READ, MAP_SHARED, fd, buf.m.offset)

  ioctl(VIDIOC_STREAMON, &type)             // 开始流传输

  for (;;) {
      ioctl(VIDIOC_DQBUF, &buf)             // 取出已完成缓冲区
      // 处理图像数据（已在 mmap 区域中）
      ioctl(VIDIOC_QBUF, &buf)              // 重新入队
  }
```

### 2.2 内核侧缓冲区流转

```
QBUF（入队） → 排队列表 → 硬件处理 → 完成列表 → DQBUF（出队）

qbui:                               dequeue:
  vb2_qbuf()                          vb2_dqbuf()
    → buf->state = QUEUED               → wait_event(done_wq, done_list not empty)
    → list_add_tail(&queued_list)        → buf = list_first_entry(&done_list)
    → ops->buf_queue(buf)                → buf->state = DEQUEUED
    → 驱动将 buf 地址写入硬件的 DMA 描述符  → 返回用户空间

硬件中断：
  irq_handler(dev)
    → dev->ops->process_frame(buf)
    → buf->state = DONE
    → list_add_tail(&done_list)
    → wake_up(&done_wq)
```

## 3. 三种缓冲区模式

| 模式 | 分配者 | 用户空间访问 | 适用场景 |
|------|--------|------------|---------|
| MMAP | 内核驱动 | mmap(fd, ...) | 标准摄像头 |
| USERPTR | 用户空间 | 传入用户地址 | GPU 互操作（旧） |
| DMABUF | 内核导出 | dma_buf 共享 | GPU/VPU 互操作（新） |

## 4. 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct video_device` | include/media/v4l2-dev.h | 核心 |
| `struct vb2_queue` | include/media/videobuf2-core.h | 缓冲区队列 |
| `vb2_qbuf()` | drivers/media/common/videobuf2/videobuf2-core.c | 缓冲区入队 |
| `vb2_dqbuf()` | drivers/media/common/videobuf2/videobuf2-core.c | 缓冲区出队 |
| `vb2_streamon()` | drivers/media/common/videobuf2/videobuf2-core.c | 开始流 |
| `__video_register_device()` | drivers/media/v4l2-core/v4l2-dev.c | 设备注册 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
