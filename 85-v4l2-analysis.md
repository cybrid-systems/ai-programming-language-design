# V4L2 — 视频4 Linux 2 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/media/v4l2-core/videobuf2-core.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**V4L2** 是 Linux 的视频捕获/输出框架，支持摄像头、视频编解码、TV 调谐器等。

---

## 1. 核心数据结构

### 1.1 video_device — 视频设备

```c
// include/media/v4l2-dev.h — video_device
struct video_device {
    struct device           dev;           // 设备
    const char              *name;          // 设备名

    // 文件操作
    const struct v4l2_file_operations *fops; // 文件操作

    // ioctl
    const struct v4l2_ioctl_ops *ioctl_ops; // ioctl 操作

    // 设备节点
    int                     minor;         // 次设备号
    u32                     device_caps;   // 设备能力

    // 队列
    struct vb2_queue        *queue;        // 视频缓冲队列
    struct v4l2_prio_state  *prio;        // 优先级状态

    // 调试
    const char              *debug;        // 调试标志
};
```

### 1.2 vb2_queue — 视频缓冲队列

```c
// include/media/videobuf2-core.h — vb2_queue
struct vb2_queue {
    enum v4l2_buf_type      type;          // BUFFER 类型
    unsigned int            num_buffers;   // 缓冲数量

    // 内存
    unsigned int            memory;       // V4L2_MEMORY_*（MMAP/USERPTR/DMABUF）

    // 队列
    struct list_head        queued_list;   // 已排队的缓冲
    struct vb2_buffer       *bufs[VIDEO_MAX_FRAME]; // 缓冲数组
    unsigned int            index;        // 当前缓冲索引

    // 操作
    const struct vb2_ops    *ops;         // 队列操作
    const struct vb2_mem_ops *mem_ops;   // 内存操作

    // 状态
    unsigned int            queued_count; // 已排队的缓冲数
    unsigned int            streaming;   // 是否正在流式传输
};
```

### 1.3 v4l2_buffer — 缓冲

```c
// include/uapi/linux/videodev2.h — v4l2_buffer
struct v4l2_buffer {
    __u32                   index;         // 缓冲索引
    __u32                   type;         // V4L2_BUF_TYPE_VIDEO_CAPTURE
    __u32                   bytesused;    // 已用字节数
    __u32                   flags;        // V4L2_BUF_FLAG_*
    enum v4l2_memory         memory;       // MMAP / USERPTR / DMABUF
    union {
        __u32               offset;       // MMAP: 偏移
        unsigned long       userptr;      // USERPTR: 用户指针
        __s32               fd;          // DMABUF: 文件描述符
    };
    __u64                   timestamp;     // 时间戳
    struct v4l2_plane       planes[VIDEO_MAX_PLANES]; // 多平面
    __u32                   num_planes;   // 平面数
};
```

---

## 2. 捕获流程

```c
// 1. 打开设备
int fd = open("/dev/video0", O_RDWR);

// 2. 设置格式
struct v4l2_format fmt = {
    .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
    .fmt.pix = { .width = 1920, .height = 1080, .pixelformat = V4L2_PIX_FMT_YUYV }
};
ioctl(fd, VIDIOC_S_FMT, &fmt);

// 3. 请求缓冲
struct v4l2_requestbuffers req = { .count = 4, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP };
ioctl(fd, VIDIOC_REQBUFS, &req);

// 4. 映射缓冲
for (i = 0; i < 4; i++) {
    struct v4l2_buffer buf = { .index = i, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP };
    ioctl(fd, VIDIOC_QUERYBUF, &buf);
    addrs[i] = mmap(NULL, buf.length, PROT_READ|PROT_WRITE, MAP_SHARED, fd, buf.m.offset);
}

// 5. 入队并启动
for (i = 0; i < 4; i++)
    ioctl(fd, VIDIOC_QBUF, &buf[i]);

ioctl(fd, VIDIOC_STREAMON, &type);

// 6. 采集
while (running) {
    struct v4l2_buffer buf;
    ioctl(fd, VIDIOC_DQBUF, &buf);  // 阻塞直到有帧
    process(addrs[buf.index]);
    ioctl(fd, VIDIOC_QBUF, &buf);   // 归还缓冲
}
```

---

## 3. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `include/media/v4l2-dev.h` | `video_device` |
| `include/media/videobuf2-core.h` | `vb2_queue`、`vb2_buffer` |
| `include/uapi/linux/videodev2.h` | `v4l2_buffer` |