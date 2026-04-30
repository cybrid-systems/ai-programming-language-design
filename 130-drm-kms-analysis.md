# Linux Kernel DRM / KMS (Display Mode Setting) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/gpu/drm/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照
> 关键词：GEM、DRM framebuffer、CRTC、connector、encoder、mode setting

---

## 0. DRM / KMS 架构

```
用户空间（libdrm / Mesa）
     ↓
DRM driver（内核）
     ↓
 ├─ DRM core（drm_*）
 ├─ Driver（i915 / amdgpu / nouveau）
 └─ Hardware（GPU）
     ↓
Display（CRTC → encoder → connector → monitor）
```

---

## 1. 核心数据结构

### 1.1 drm_device — DRM 设备

```c
// drivers/gpu/drm/drm_device.c — drm_device
struct drm_device {
    // 设备信息
    struct device           *dev;              // 平台设备
    struct drm_driver       *driver;           // 驱动
    struct drm_master       *master;           // 主设备

    // 模式设置
    struct drm_mode_config  *mode_config;     // 模式配置

    // 调度
    struct workqueue_struct *vblank_event_queue; // VBLANK 事件队列

    // 资源
    struct list_head        unmanaged;         // 资源链表
    struct idr              object_idr;        // 对象 IDR
    struct mutex            object_name_lock;
    struct idr              tile_idr;           // 瓦片 IDR
};
```

### 1.2 drm_mode_config — 模式配置

```c
// drivers/gpu/drm/drm_mode_config.c — drm_mode_config
struct drm_mode_config {
    // connector 列表
    struct list_head        connector_list;     // 行 62

    // encoder 列表
    struct list_head        encoder_list;      // 行 63

    // CRTC 列表
    struct list_head        crtc_list;        // 行 64

    // framebuffer 列表
    struct list_head        fb_list;          // 行 65

    // 最小/最大分辨率
    int                     min_width;         // 行 70
    int                     max_width;         // 行 71
    int                     min_height;        // 行 72
    int                     max_height;        // 行 73

    // 辅助函数
    int (*fb_create)(struct drm_device *dev, struct drm_file *file,
             const struct drm_mode_fb_cmd2 *mode_cmd, struct drm_framebuffer **fb);
};
```

### 1.3 drm_connector — 显示连接器

```c
// drivers/gpu/drm/drm_connector.c — drm_connector
struct drm_connector {
    struct drm_mode_object base;            // 基类
    char                  name[DRM_CONNECTOR_NAME_LEN]; // "HDMI-A-1"

    // 类型
    int                   connector_type;    // DRM_MODE_CONNECTOR_HDMI
    int                   connector_type_id;  // 连接器编号

    // 状态
    enum drm_connector_status status;       // connected / disconnected

    // 当前模式
    struct drm_display_mode *display_mode;  // 当前模式

    // 编码器
    struct drm_encoder  *encoder;           // 当前编码器

    // 属性
    struct list_head      Propertys;         // 属性列表
    struct drm_object_properties properties; // 对象属性
};
```

### 1.4 drm_crtc — 显示控制器

```c
// drivers/gpu/drm/drm_crtc.c — drm_crtc
struct drm_crtc {
    struct drm_mode_object base;            // 基类

    // 位置
    int                    x, y;            // 位置

    // 当前模式
    struct drm_display_mode *mode;        // 当前模式
    struct drm_display_modehw_mode;      // 硬件模式

    // 帧缓冲
    struct drm_framebuffer *fb;           // 当前帧缓冲

    // 管道
    int                    pipe;            // 管道编号（0, 1, 2...）
    int                    primary_plane;  // 主平面

    // VBLANK
    struct drm_vblank_crtc vblank;        // VBLANK 状态

    // 翻转队列
    struct drm_pending_vblank_event *event; // 待处理 VBLANK 事件
};
```

### 1.5 drm_framebuffer — 帧缓冲

```c
// drivers/gpu/drm/drm_framebuffer.c — drm_framebuffer
struct drm_framebuffer {
    struct drm_mode_object base;            // 基类
    struct drm_device     *dev;             // DRM 设备

    // 格式
    int                   pixel_format;      // 像素格式（DRM_FORMAT_XRGB8888）
    int                   width, height;     // 分辨率

    // 平面
    struct {
        unsigned int       pitch;           // 步长（字节）
        dma_addr_t         dma;            // DMA 地址
        void               *vm;            // 虚拟地址
    } pitches[4];                          // 最多 4 个平面

    // GEM 对象
    struct drm_gem_object *obj[4];         // GEM 对象（RGB 分量）
};
```

---

## 2. GEM — Graphics Execution Manager

```c
// drivers/gpu/drm/drm_gem.c — drm_gem_object
struct drm_gem_object {
    // 引用计数
    struct kref           refcount;         // 行 30
    struct dma_resv       *resv;           // reservation/Fence

    // 内存信息
    size_t                size;              // 对象大小
    struct file            *filp;           // 所有者文件
    void                  *vmapping;        // 虚拟映射
    struct sg_table        *sgt;           // scatter-gather 表（DMA）

    // DRM 内存管理
    int                   name;             // 全局名称
    unsigned long          flags;            // 标志
};
```

---

## 3. KMS 流程

```c
// 1. 设置模式：
drmModeSetCrtc(crtc_id, fb_id, x, y, connector_ids, count, &mode);

// → drm_mode_set_internal()
//   → drm_crtc->mode = mode
//   → drm_crtc->fb = fb
//   → drm_crtc->encoder->funcs->mode_set(encoder, mode)
//     → 硬件寄存器编程（ PLL、 timing 等）

// 2. 页面翻转（Page Flip）：
drmModePageFlip(crtc_id, fb_id, DRM_MODE_PAGE_FLIP_EVENT, event);

// → drm_mode_page_flip()
//   → crtc->funcs->page_flip(crtc, fb, ...)
//   → 硬件切换扫描缓冲区
//   → VBLANK 时触发，完成后发送事件
```

---

## 4. 参考

| 文件 | 内容 |
|------|------|
| `drivers/gpu/drm/drm_device.c` | DRM 设备 |
| `drivers/gpu/drm/drm_crtc.c` | CRTC 管理 |
| `drivers/gpu/drm/drm_connector.c` | connector 管理 |
| `drivers/gpu/drm/drm_framebuffer.c` | framebuffer 管理 |
| `drivers/gpu/drm/drm_gem.c` | GEM 对象管理 |
