# Linux Kernel V4L2 (Video4Linux2) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/media/v4l2-core/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：video_device、vb2_queue、buf_type、dqueue

---

## 1. 核心数据结构

### 1.1 video_device — 视频设备

```c
// drivers/media/v4l2-core/v4l2-dev.c — video_device
struct video_device {
    // 设备名称
    const char            *name;              // "uvcvideo"

    // 设备节点
    struct device         *dev;               // 设备
    int                   minor;              // 次设备号

    // 文件操作
    const struct v4l2_file_operations *fops; // 文件操作

    // ioctl 操作
    const struct v4l2_ioctl_ops *ioctl_ops;  // ioctl

    // 缓冲队列
    struct vb2_queue      *queue;             // vb2 队列

    // 设备类型
    enum v4l2_buf_type   vfl_type;          // V4L2_BUF_TYPE_VIDEO_CAPTURE
    struct v4l2_prio_state *prio;            // 优先级状态

    // 链表
    struct list_head       devnode_list;       // 设备节点链表

    // 调试
    u32                   debug;              // 调试标志
};
```

### 1.2 vb2_queue — 视频缓冲队列

```c
// drivers/media/v4l2-core/videobuf2-core.c — vb2_queue
struct vb2_queue {
    // 类型
    enum v4l2_memory       memory;          // V4L2_MEMORY_MMAP / USERPTR / DMABUF
    enum v4l2_buf_type     type;            // V4L2_BUF_TYPE_VIDEO_CAPTURE

    // 缓冲区
    unsigned int            num_buffers;      // 缓冲区数量

    // 数组
    struct vb2_buffer      *bufs[VIDEO_MAX_FRAME]; // 缓冲区指针

    // 已排队缓冲区链表
    struct list_head        queued_list;       // 已排队的缓冲区

    // 当前正在 DMA 的缓冲区
    struct vb2_buffer      *cur;

    // 驱动回调
    const struct vb2_ops   *ops;              // vb2 操作
    const struct vb2_mem_ops *mem_ops;       // 内存操作
    void                   *drv_priv;         // 驱动私有数据

    // 等待队列
    wait_queue_head_t      done_wq;          // 完成等待队列
};
```

### 1.3 vb2_buffer — 单个缓冲区

```c
// drivers/media/v4l2-core/videobuf2-core.c — vb2_buffer
struct vb2_buffer {
    // 队列引用
    struct vb2_queue       *vb2_queue;        // 所属队列

    // 缓冲区索引
    unsigned int            index;             // 索引

    // 状态
    enum vb2_buffer_state  state;            // VB2_BUF_STATE_QUEUED 等

    // 时间戳
    struct timeval          timestamp;        // 帧时间戳

    // 已排队节点
    struct list_head        queued_entry;     // 接入 queued_list

    // 平面信息
    struct {
        unsigned int        length;           // 平面大小
        void               *mem_priv;        // 内存私有数据
    } planes[VIDEO_MAX_PLANES];
};
```

---

## 2. buf_type 和 ioctl

```c
// 缓冲区类型：
V4L2_BUF_TYPE_VIDEO_CAPTURE        // 视频捕获
V4L2_BUF_TYPE_VIDEO_OUTPUT          // 视频输出
V4L2_BUF_TYPE_VIDEO_OVERLAY         // 视频覆盖
V4L2_BUF_TYPE_VBI_CAPTURE           // VBI 捕获
V4L2_BUF_TYPE_SDR_CAPTURE           // 软件定义无线电

// 内存类型：
V4L2_MEMORY_MMAP                    // mmap 映射
V4L2_MEMORY_USERPTR                 // 用户空间指针
V4L2_MEMORY_DMABUF                  // DMA buf
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/media/v4l2-core/v4l2-dev.c` | video_device 注册 |
| `drivers/media/v4l2-core/videobuf2-core.c` | vb2_queue 实现 |
