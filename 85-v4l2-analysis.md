# Linux Kernel V4L2 (Video4Linux2) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/media/v4l2-core/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. V4L2 概述

**V4L2** 是 Linux 视频子系统（Camera、Video Capture、TV tuner）。

---

## 1. 核心结构

```c
// drivers/media/v4l2-core/v4l2-dev.c — video_device
struct video_device {
    const char          *name;             // 设备名
    int                  minor;             // 次设备号
    struct v4l2_device  *v4l2_dev;        // V4L2 设备
    struct v4l2_file_operations *fops;    // 文件操作
    struct v4l2_ioctl_ops *ioctl_ops;     // ioctl 操作

    /* 缓冲区管理 */
    struct vb2_queue    *queue;            // videobuf2 队列
    enum v4l2_buf_type   type;              // V4L2_BUF_TYPE_VIDEO_CAPTURE

    struct device       *dev;              // 底层设备
};

// vb2_queue — 视频缓冲区队列
struct vb2_queue {
    enum v4l2_memory    memory;             // V4L2_MEMORY_MMAP / USERPTR / DMABUF
    unsigned int        num_buffers;         // 缓冲区数量
    struct vb2_buffer   *bufs[VIDEO_MAX_FRAME];
    struct list_head    queued_list;        // 已排队的缓冲区
};
```

---

## 2. 参考

| 文件 | 内容 |
|------|------|
| `drivers/media/v4l2-core/v4l2-dev.c` | video_device 注册 |
| `drivers/media/v4l2-core/videobuf2-core.c` | vb2_queue 实现 |
