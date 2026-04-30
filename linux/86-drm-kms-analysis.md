# DRM / KMS — 显示渲染深度源码分析

> 基于 Linux 7.0-rc1 主线源码（`drivers/gpu/drm/drm_crtc.c` + `drivers/gpu/drm/drm_fb_helper.c`)
> 工具：doom-lsp（clangd LSP）+ 原始源码逐行对照

---

## 0. 概述

**DRM/KMS** 是 Linux 的显示驱动框架（Direct Rendering Manager / Kernel Mode Setting）。

---

## 1. 核心数据结构

### 1.1 drm_device — DRM 设备

```c
// drivers/gpu/drm/drm_device.h — drm_device
struct drm_device {
    // 设备
    struct device           *dev;           // 底层设备
    char                    *driver_name;   // 驱动名

    // 模式设置
    struct drm_mode_config  *mode_config;  // 模式配置
    struct drm_master        *master;       // 主设备

    // 资源
    struct list_head        ctxlist;       // 上下文链表
    struct list_head        vmalist;       // VM 映射链表

    // 文件描述符
    struct drm_file         *file;         // 当前文件

    // CRTC
    struct drm_crtc         *crtc;         // CRT 控制器
    struct drm_encoder     *encoder;       // 编码器
    struct drm_connector   *connector;     // 连接器（HDMI/VGA）
    struct drm_plane       *plane;         // 平面（图像层）
};
```

### 1.2 drm_crtc — CRT 控制器

```c
// drivers/gpu/drm/drm_crtc.h — drm_crtc
struct drm_crtc {
    struct device           *dev;           // 设备
    struct drm_device       *dev;           // DRM 设备

    // CRTC ID
    int                     base.id;        // 标识符
    const char              *name;          // 名称

    // 模式
    struct drm_display_mode  mode;         // 当前模式
    struct drm_display_mode  *hwmode;       // 硬件模式

    // 帧缓冲
    struct drm_framebuffer   *fb;           // 当前帧缓冲
    struct drm_fb_helper    *fb_helper;    // FB 辅助

    // 平面
    struct drm_plane        *plane;        // 主平面
};
```

### 1.3 drm_connector — 连接器

```c
// drivers/gpu/drm/drm_connector.h — drm_connector
struct drm_connector {
    // 标识
    int                     connector_type; // DRM_MODE_CONNECTOR_*（HDMI/VGA/eDP）
    char                    *name;           // 连接器名

    // 状态
    enum drm_connector_status status;       // 连接状态
    //   connector_status_connected    → 已连接
    //   connector_status_disconnected → 断开
    //   connector_status_unknown     → 未知

    // 编码器
    struct drm_encoder      *encoder;       // 连接的编码器

    // 模式
    struct drm_display_mode *modes;        // 支持的模式列表
    int                     num_modes;       // 模式数

    // 变量
    struct drm_property_blob *EDID;         // EDID 信息（显示器标识）
};
```

---

## 2. mode_config — 模式配置

```c
// drivers/gpu/drm/drm_modeset.c — drm_mode_config
struct drm_mode_config {
    // FB
    struct drm_mode_config_funcs *funcs;  // 函数
    struct drm_framebuffer        *fb;    // 帧缓冲

    // 模式
    struct list_head        modes;          // 模式列表

    // CRTC/encoder/connector
    struct list_head        crtc_list;      // CRTC 链表
    struct list_head        encoder_list;   // 编码器链表
    struct list_head        connector_list;  // 连接器链表
    struct list_head        plane_list;      // 平面链表

    // 最小/最大分辨率
    int                     min_width;       // 最小宽度
    int                     max_width;       // 最大宽度
    int                     min_height;      // 最小高度
    int                     max_height;      // 最大高度
};
```

---

## 3. page_flip — 页面翻转

```c
// drivers/gpu/drm/drm_crtc.c — drm_mode_page_flip
int drm_mode_page_flip(struct drm_crtc *crtc, ...)
{
    // 1. 检查 CRTC 是否忙
    if (crtc->funcs->page_flip_target) {
        // 异步翻转（立即返回，等 VSYNC 完成后切换）
        return crtc->funcs->page_flip_target(crtc, fb, target_vblank, flags, context);
    }

    // 2. 同步翻转（等 VBLANK）
    crtc->fb = fb;
    crtc->target_vblank = target_vblank;

    // 3. 等待 VBLANK
    wait_vblank(crtc, target_vblank);

    // 4. 切换
    crtc->fb = fb;

    return 0;
}
```

---

## 4. DRM 设备节点

```
/dev/dri/
├── card0              ← 主要显示设备
├── renderD128         ← 渲染节点（无权限问题）
├── controlD64         ← 控制节点
```

---

## 5. 完整文件索引

| 文件 | 函数/结构 |
|------|----------|
| `drivers/gpu/drm/drm_crtc.h` | `drm_crtc`、`drm_connector` |
| `drivers/gpu/drm/drm_modeset.c` | `drm_mode_config` |
| `drivers/gpu/drm/drm_crtc.c` | `drm_mode_page_flip` |