# Linux Kernel DRM / KMS (Display Mode Setting) 深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/gpu/drm/`）
> 工具：doom-lsp（clangd LSP）+ 原始源码对照

---

## 0. DRM / KMS 概述

**DRM（Direct Rendering Manager）** 是 Linux 图形驱动框架，KMS（Kernel Mode Setting）允许用户空间设置显示分辨率和模式。

---

## 1. 核心结构

```c
// drivers/gpu/drm/drm_mode_object.c — drm_mode_object
struct drm_mode_object {
    __u32     id;               // 对象 ID
    __u32     type;             // DRM_MODE_OBJECT_CONNECTOR / CRTC / ENCODER / FB
    void      *ptr;             // 指向具体对象
};

// drm_connector — 显示连接器（HDMI/DP/VGA）
struct drm_connector {
    struct drm_mode_object base;
    int                    connector_type;   // DRM_MODE_CONNECTOR_HDMI
    int                    connector_type_id;
    struct drm_display_mode *display_mode;  // 当前模式
    enum drm_connector_status status;         // 连接状态
};

// drm_crtc — 显示控制器
struct drm_crtc {
    struct drm_mode_object base;
    struct drm_display_mode *mode;         // 当前模式
    __u32                    x, y;            // 位置
    struct drm_framebuffer *fb;             // 帧缓冲
};

// drm_framebuffer — 帧缓冲
struct drm_framebuffer {
    struct drm_device *dev;
    __u32             width, height;         // 分辨率
    __u32             *formats;             // 像素格式
    struct dma_buf   *obj[4];              // GEM 对象（平面）
};
```

---

## 2. GEM — Graphics Execution Manager

```c
// GEM 管理 GPU 可访问的内存：
struct drm_gem_object {
    struct kref         refcount;
    struct file         *filp;              // 所有者文件
    size_t              size;               // 对象大小
    struct sg_table     *sgt;               // scatterlist（DMA 映射）
    void                *vaddr;             // 虚拟地址
};

// DRM_IOCTL_MODE_MAP_DUMB：映射 GPU 内存到用户空间
// DRM_IOCTL_MODE_CREATE_DUMB：创建 DMA 可访问的 dumb buffer
```

---

## 3. 参考

| 文件 | 内容 |
|------|------|
| `drivers/gpu/drm/drm_mode_object.c` | mode object 管理 |
| `drivers/gpu/drm/drm_crtc.c` | CRTC/connector/encoder |
| `drivers/gpu/drm/drm_gem.c` | GEM 对象管理 |
