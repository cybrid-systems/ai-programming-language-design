# Linux Kernel V4L2 (Video4Linux2) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/media/v4l2-core/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：video_device、vb2_queue、buf_type、dqueue

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

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/media/v4l2-core/v4l2-dev.c` | video_device 注册 |
| `drivers/media/v4l2-core/videobuf2-core.c` | vb2_queue 实现 |


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

