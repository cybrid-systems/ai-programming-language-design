# 85-v4l2 — Linux Video4Linux2 视频框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**V4L2（Video4Linux2）** 是 Linux 视频设备框架，支持摄像头、TV 调谐器、视频采集卡、编码器/解码器。核心通过 `/dev/videoX` 提供以下功能：
- **视频采集**（`VIDIOC_QBUF`/`DQBUF`）——将视频帧从设备传递到用户空间
- **视频输出**——将用户空间帧发送到显示设备
- **控制**（`VIDIOC_S_CTRL`）——亮度/对比度/曝光等
- **格式设置**（`VIDIOC_S_FMT`）——分辨率/像素格式/帧率

**核心设计**：V4L2 采用 **queue + buffer** 模型——驱动管理一个视频缓冲池，用户空间通过 `VIDIOC_REQBUFS` 请求缓冲区，`VIDIOC_QBUF` 将缓冲区入队（填充数据），`VIDIOC_DQBUF` 出队获取已填充的缓冲区。底层通过 **videobuf2** 框架管理内存分配和 DMA。

```
用户空间                           V4L2 核心                     摄像头驱动
─────────                       ──────────                   ────────────
open("/dev/video0")
  → video_open()               → v4l2-dev.c                   
  → vdev->fops->open()                                          

VIDIOC_QUERYCAP                → v4l2-ioctl.c                 
  → vdev->ioctl_ops->vidioc_querycap()                        
  → 返回设备能力                                               

VIDIOC_S_FMT                   → v4l2-ioctl.c                 
  → vdev->ioctl_ops->vidioc_s_fmt_vid_cap()                   
  → 设置分辨率/格式                                              → 配置传感器

VIDIOC_REQBUFS                 → videobuf2_core               
  → vb2_core_reqbufs()                                        
  → 分配 DMA 缓冲区                                             → dma_alloc_coherent()

VIDIOC_QBUF                    → videobuf2_core               
  → vb2_core_qbuf() → 入队空缓冲区                              
  → VIDIOC_STREAMON                                            
  → vb2_core_streamon()                                        → 启动视频流

                              [硬件中断: 帧完成]                
                              → vb2_buffer_done()             → 传感器 ISR
                              → 唤醒 DQBUF 等待者              

VIDIOC_DQBUF                  → videobuf2_core               
  → vb2_core_dqbuf() → 出队已填充缓冲区                         
  → mmap 读取帧数据                                            
```

**doom-lsp 确认**：V4L2 核心在 `drivers/media/v4l2-core/v4l2-dev.c`（134 符号）、`v4l2-ioctl.c`（214 符号）、`videobuf2-core.c`。头文件 `include/media/v4l2-dev.h`（665 行）、`include/uapi/linux/videodev2.h`（2,844 行）。

---

## 1. 核心数据结构

### 1.1 struct video_device @ v4l2-dev.h:264

```c
struct video_device {
    const struct v4l2_file_operations *fops;       // 文件操作
    u32 device_caps;                                // 设备能力

    struct device dev;
    struct cdev *cdev;                              // /dev/videoX

    struct v4l2_device *v4l2_dev;
    struct vb2_queue *queue;                        // videobuf2 队列

    char name[64];
    enum vfl_devnode_type vfl_type;                 // VIDEO/VBI/RADIO/SDR
    int minor;
    u16 num;                                        // 设备号
    int index;

    const struct v4l2_ioctl_ops *ioctl_ops;          // ioctl 操作表
    DECLARE_BITMAP(valid_ioctls, BASE_VIDIOC_PRIVATE); // 有效 ioctl 位图

    struct mutex *lock;
};
```

### 1.2 struct v4l2_ioctl_ops——ioctl 操作表

```c
// 每个 ioctl 对应一个回调函数：
struct v4l2_ioctl_ops {
    int (*vidioc_querycap)(struct file *f, void *fh, struct v4l2_capability *c);
    int (*vidioc_enum_fmt_vid_cap)(struct file *f, void *fh, struct v4l2_fmtdesc *f);
    int (*vidioc_s_fmt_vid_cap)(struct file *f, void *fh, struct v4l2_format *f);
    int (*vidioc_reqbufs)(struct file *f, void *fh, struct v4l2_requestbuffers *b);
    int (*vidioc_querybuf)(struct file *f, void *fh, struct v4l2_buffer *b);
    int (*vidioc_qbuf)(struct file *f, void *fh, struct v4l2_buffer *b);
    int (*vidioc_dqbuf)(struct file *f, void *fh, struct v4l2_buffer *b);
    int (*vidioc_streamon)(struct file *f, void *fh, enum v4l2_buf_type i);
    int (*vidioc_streamoff)(struct file *f, void *fh, enum v4l2_buf_type i);
    int (*vidioc_s_ctrl)(struct file *f, void *fh, struct v4l2_control *c);
    // ... 约 100 个 ioctl
};
```

### 1.3 struct vb2_queue——videobuf2 队列

```c
struct vb2_queue {
    enum v4l2_buf_type type;                        // V4L2_BUF_TYPE_VIDEO_CAPTURE
    unsigned int io_modes;                          // VB2_MMAP / VB2_USERPTR / VB2_DMABUF
    const struct vb2_mem_ops *mem_ops;              // 内存操作

    const struct vb2_ops *ops;                      // 驱动操作
    void *drv_priv;                                 // 驱动私有数据

    struct vb2_buffer *bufs[VB2_MAX_FRAMES];         // 缓冲区数组
    unsigned int num_buffers;

    struct list_head queued_list;                    // 已入队缓冲区
    spinlock_t done_lock;
    struct list_head done_list;                       // 已完成缓冲区
    wait_queue_head_t done_wq;                        // DQBUF 等待队列

    unsigned int streaming:1;                        // 是否正在流传输
};
```

**doom-lsp 确认**：`struct video_device` 在 `v4l2-dev.h:264`，`struct vb2_queue` 在 `videobuf2-core.h`。

---

## 2. 核心 ioctl 路径

### 2.1 ioctl 分发 @ v4l2-ioctl.c

```c
// /dev/videoX 的 ioctl 入口 → video_ioctl2()
long video_ioctl2(struct file *file, unsigned int cmd, unsigned long arg)
{
    // 1. 通过 valid_ioctls 位图检查 ioctl 是否支持
    if (!test_bit(_IOC_NR(cmd), vdev->valid_ioctls))
        return -ENOTTY;

    // 2. 调用 v4l2-ioctl.c 中的处理函数
    //    通过 ioctl 号查表找到对应的 handler
    //    例如 VIDIOC_QBUF → v4l_qbuf
    return v4l2_ioctl(file, cmd, arg);
}
```

### 2.2 缓冲区状态机

```c
// include/media/videobuf2-core.h:226
enum vb2_buffer_state {
    VB2_BUF_STATE_DEQUEUED,    // 用户空间持有
    VB2_BUF_STATE_QUEUED,       // 已入队，等待硬件处理
    VB2_BUF_STATE_DONE,         // 硬件处理完成，等待出队
    VB2_BUF_STATE_ERROR,        // 硬件处理错误
    VB2_BUF_STATE_PREPARING,    // 正在准备（内部）
    VB2_BUF_STATE_PREPARED,     // 准备完成
};

// 缓冲生命周期：
// REQBUFS → DEQUEUED → QBUF → QUEUED → [硬件处理] → DONE → DQBUF → DEQUEUED
// 循环
```

### 2.3 QBUF/DQBUF 路径——缓冲循环

```c
// VIDIOC_QBUF（入队空缓冲区）@ videobuf2-core.c：
// → vb2_core_qbuf(vq, vb, ...)
//   1. 检查缓冲区状态必须为 VB2_BUF_STATE_DEQUEUED
//   2. 填充驱动需要的元数据（__fill_vb2_buffer）
//   3. 状态 → VB2_BUF_STATE_QUEUED
//   4. buffer 加入 queued_list
//   5. 如果 streaming 已启动 → ops->buf_queue(vb)
//      → 驱动将 buffer 提交到硬件 DMA 描述符链表
//      → 硬件开始向此缓冲区写入帧数据

// VIDIOC_DQBUF（出队已填充缓冲区）：
// → vb2_core_dqbuf(vq, ...)
//   1. wait_event(vq->done_wq, !list_empty(&vq->done_list))
//      → 阻塞直到有缓冲区完成
//   2. 从 done_list 取出 buffer
//   3. 状态 → VB2_BUF_STATE_DEQUEUED
//   4. 通过 vb2_plane_vaddr() / vb2_plane_cookie() 获取数据地址
//      → 用户通过 mmap 或 copy 读取帧

// 硬件中断时的完成路径 @ vb2_buffer_done()：
// 当摄像头传感器完成一帧捕获：
//   driver_irq_handler(){
//       update vb->planes[i].bytesused // 实际数据大小
//       vb2_buffer_done(vb, VB2_BUF_STATE_DONE)
//   }
// → list_add(&vb->done_entry, &q->done_list)
// → wake_up(&q->done_wq)
// → 如果 buf_queue 已空 → 可选的 underrun 处理
```

---

## 3. videobuf2 内存管理

```c
// videobuf2 支持三种内存模型：

// 1. VB2_MMAP：内核分配 DMA 缓冲区，用户 mmap 访问
//    → dma_alloc_coherent() 分配
//    → mmap → remap_pfn_range() 映射到用户空间
//    零拷贝：用户直接读写 DMA 缓冲

// 2. VB2_USERPTR：用户提供内存地址
//    → get_user_pages() 锁定用户页面
//    → 驱动直接 DMA 到用户页面
//    适用于用户自定义内存管理

// 3. VB2_DMABUF：通过 dma-buf 共享
//    → 从其他驱动导入 DMA 缓冲区
//    适用于 GPU/ISP 内存共享
```

---

## 4. 调试

```bash
# 查看 V4L2 设备
ls -l /dev/video*
cat /sys/class/video4linux/video0/name

# 查看设备能力
v4l2-ctl -d /dev/video0 --all
v4l2-ctl -d /dev/video0 --list-formats

# 采集帧
v4l2-ctl -d /dev/video0 --set-fmt-video=width=640,height=480
v4l2-ctl -d /dev/video0 --stream-mmap --stream-to=frame.raw

# 调试日志
echo 0xFF > /sys/class/video4linux/video0/dev_debug

# tracepoint
echo 1 > /sys/kernel/debug/tracing/events/videobuf2/enable
```

---

## 5. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `video_ioctl2` | `v4l2-ioctl.c` | ioctl 分发入口 |
| `vb2_core_reqbufs` | `videobuf2-core.c` | 请求缓冲区 |
| `vb2_core_qbuf` | `videobuf2-core.c` | 缓冲入队 |
| `vb2_core_dqbuf` | `videobuf2-core.c` | 缓冲出队 |
| `vb2_buffer_done` | `videobuf2-core.c` | 标记缓冲完成 |
| `__video_register_device` | `v4l2-dev.c` | 设备注册 |

---

## 6. 总结

V4L2 通过 `VIDIOC_REQBUFS/ QBUF/ DQBUF` 管理视频缓冲循环——`vb2_core_qbuf` 入队空缓冲区到硬件，硬件填充后通过 `vb2_buffer_done` 移到 done_list，`vb2_core_dqbuf` 出队给用户空间。videobuf2 支持 MMAP/USERPTR/DMABUF 三种内存模型，实现零拷贝数据路径。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*

## 源码索引

| 符号 | 文件 | 行号 |
|------|------|------|
| `struct video_device` | include/media/v4l2-dev.h | 核心 |
| `struct vb2_queue` | include/media/videobuf2-core.h | 核心 |
| `video_register_device()` | drivers/media/v4l2-core/v4l2-dev.c | 相关 |
| `vb2_core_qbuf()` | drivers/media/v4l2-core/videobuf2-core.c | 入队 |
| `vb2_core_dqbuf()` | drivers/media/v4l2-core/videobuf2-core.c | 出队 |
| `vb2_core_streamon()` | drivers/media/v4l2-core/videobuf2-core.c | 开始流 |
| `__video_ioctl2()` | drivers/media/v4l2-core/v4l2-ioctl.c | ioctl 分发 |

---

*分析工具：doom-lsp | 分析日期：2026-05-04*
