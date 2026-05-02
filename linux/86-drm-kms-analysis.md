# 86-drm-kms — Linux DRM/KMS 显示框架深度源码分析

> 基于 Linux 7.0-rc1 主线源码
> 使用 doom-lsp（clangd LSP）进行逐行符号解析与数据流追踪
> 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1

---

## 0. 概述

**DRM（Direct Rendering Manager）** 是 Linux 图形显示框架，分为两个子系统：**KMS（Kernel Mode Setting）** 负责显示模式设置（分辨率、刷新率、显示布局），**GEM（Graphics Execution Manager）** 负责 GPU 内存管理。KMS 的核心是**原子（atomic）modeset**——一次 ioctl 原子地更新所有显示状态（CRTC/encoder/connector/plane）。

**核心设计**：KMS 将显示管道抽象为四个对象——**CRTC**（显示定时器/扫描输出）、**Encoder**（编码器，将 CRTC 信号转换为物理接口）、**Connector**（物理接口，如 HDMI/DP/eDP）、**Plane**（硬件层，用于合成）。**atomic commit** 将所有更新打包为一个 `struct drm_atomic_state`，通过 `drm_atomic_commit` 一次性应用。

```
DRM 显示管道：
┌──────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
│Plane │   │  CRTC    │   │ Encoder  │   │Connector │
│(帧缓冲)──→│(扫描输出)──→│(TMDS/DP)──→│(HDMI/DP)──→ 显示器
│ src→dst│  │ timing   │  │ 编码     │  │ 热插拔    │
└──────┘   └──────────┘   └──────────┘   └──────────┘

Atomic 更新流程：
  用户空间                       DRM 核心                   驱动
  DRM_IOCTL_MODE_ATOMIC
    → drm_atomic_commit()       @ drm_atomic.c
      → drm_atomic_check_only() 检查可行性
      → drm_atomic_commit()     提交更新
        → drm_atomic_helper_commit()
          → 1. prepare_fb()    准备帧缓冲
          → 2. swap_state()    交换新旧状态
          → 3. commit_tail()   提交到硬件
            → crtc->enable()/disable()
            → plane->update()
            → encoder->modeset()
```

**doom-lsp 确认**：DRM 核心在 `drivers/gpu/drm/drm_crtc.c`（58 符号）、`drm_atomic.c`（166 符号）、`drm_fb_helper.c`。头文件 `include/drm/drm_crtc.h`（1,357 行）、`drm_atomic.h`（1,377 行）。

---

## 1. 核心数据结构

### 1.1 struct drm_crtc——显示定时器 @ crtc.h

```c
struct drm_crtc {
    struct drm_device *dev;
    struct drm_plane *primary;               // 主平面
    struct drm_plane *cursor;                // 光标平面

    int index;                               // 索引

    struct drm_crtc_state *state;            // 当前状态（atomic）
    struct drm_crtc_state *old_state;        // 旧状态

    const struct drm_crtc_funcs *funcs;      // 操作函数
    struct drm_crtc_helper_funcs *helper_private;
};
```

### 1.2 struct drm_plane——硬件层

```c
struct drm_plane {
    struct drm_device *dev;
    struct drm_crtc *crtc;                   // 关联的 CRTC

    uint32_t possible_crtcs;                 // 可关联的 CRTC 位图

    struct drm_plane_state *state;

    const struct drm_plane_funcs *funcs;
};
```

### 1.3 struct drm_connector@ drm_connector.h

```c
struct drm_connector {
    struct drm_device *dev;
    struct drm_encoder *encoder;             // 关联的编码器

    int connector_type;                      // DRM_MODE_CONNECTOR_HDMIA/DP/eDP
    char name[32];

    struct drm_connector_state *state;

    const struct drm_connector_funcs *funcs;
};
```

### 1.4 struct drm_encoder——编码器

```c
struct drm_encoder {
    struct drm_device *dev;
    unsigned int encoder_type;               // DRM_MODE_ENCODER_TMDS/DAC/LVDS

    struct drm_crtc *crtc;                   // 关联的 CRTC
    struct drm_connector *connector;         // 关联的连接器

    const struct drm_encoder_funcs *funcs;
};
```

### 1.5 struct drm_atomic_state——原子状态 @ atomic.h

```c
struct drm_atomic_state {
    struct drm_device *dev;
    struct drm_modeset_acquire_ctx *acquire_ctx;

    struct drm_crtc_commit *crtcs[DEVICE_MAX_CRTC];
    struct drm_crtc_state *crtc_states[DEVICE_MAX_CRTC];

    struct drm_plane_state *plane_states[DEVICE_MAX_PLANES];
    struct drm_connector_state *connector_states[DEVICE_MAX_CONNECTORS];

    bool allow_modeset;                      // 是否允许模式切换
};
```

**doom-lsp 确认**：`struct drm_crtc` @ `drm_crtc.h`，`struct drm_atomic_state` @ `drm_atomic.h`。`drm_atomic_commit` @ `drm_atomic.c:166` 符号。

---

## 2. Atomic 提交流程 @ drm_atomic.c

### 2.1 drm_atomic_state——原子状态

```c
// 一次 atomic ioctl 构建一个 drm_atomic_state，包含所有对象的新状态：
// struct drm_atomic_state {
//     struct drm_crtc_state *crtc_states[];
//     struct drm_plane_state *plane_states[];
//     struct drm_connector_state *connector_states[];
// };

// 平面状态（plane_state）关联帧缓冲：
struct drm_plane_state {
    struct drm_plane *plane;
    struct drm_framebuffer *fb;              // 关联的帧缓冲
    struct dma_fence *fence;                 // GPU 渲染完成 fence

    uint32_t src_x, src_y;                   // 源区域（帧缓冲中）
    uint32_t src_w, src_h;
    uint32_t crtc_x, crtc_y;                 // 目标区域（屏幕上）
    uint32_t crtc_w, crtc_h;

    bool visible;                            // 是否可见
};
```

### 2.2 drm_atomic_commit——四阶段提交

```c
int drm_atomic_commit(struct drm_atomic_state *state)
{
    // 阶段 1：检查（drm_atomic_check_only）
    // → 遍历所有 CRTC：crtc->funcs->atomic_check(crtc, state)
    // → 遍历所有 Plane：plane->funcs->atomic_check(plane, state)
    // → 驱动验证：带宽是否足够、PLL 是否可用、格式是否支持

    // 阶段 2：准备帧缓冲
    // → drm_atomic_helper_prepare_planes(state)
    //   → plane->funcs->prepare_fb(plane, plane_state)
    //     → drm_gem_fb_prepare_fb() — 等待 GPU fence
    //     → dma_fence_wait(plane_state->fence) — 等渲染完成

    // 阶段 3：交换状态
    // → drm_atomic_helper_swap_state(state, ...)
    //   → 将所有 obj->state 指向新状态
    //   → 旧状态保存到 old_state

    // 阶段 4：提交到硬件（commit_tail）
    // 由驱动 crtc->commit() 或异步 worker 调用：
    // → drm_atomic_helper_commit_modeset_disables()
    // → drm_atomic_helper_commit_planes()
    //   → 设置新平面（如切换帧缓冲地址、更新缩放）
    // → drm_atomic_helper_commit_modeset_enables()
    //   → 启动新模式
    // → drm_atomic_helper_wait_for_vblanks()
    //   → 等待 VBlank 确保新帧显示
}
```

### 2.3 struct drm_framebuffer @ drm_framebuffer.h:120

```c
// 帧缓冲——包含像素数据的内存区域
struct drm_framebuffer {
    struct drm_device *dev;
    const struct drm_format_info *format;     // 像素格式（XRGB8888/NV12）
    unsigned int width, height;               // 分辨率
    unsigned int pitches[4];                  // 每平面每行字节数
    unsigned int offsets[4];                  // 每平面偏移
    uint64_t modifier;                         // 修饰符（tiling/CCS）
    struct drm_gem_object *obj[4];            // GEM 对象
};
```

---

## 3. CRTC 模式设置

```c
// CRTC 的模式设置通过 drm_crtc_helper_set_mode() 完成：
struct drm_display_mode {
    u32 clock;          // 像素时钟 (kHz)
    u16 hdisplay;       // 水平可见像素
    u16 hsync_start;    // 水平同步开始
    u16 hsync_end;
    u16 htotal;
    u16 vdisplay;       // 垂直行数
    u16 vsync_start;    // 垂直同步开始
    u16 vsync_end;
    u16 vtotal;
    u32 flags;          // DRM_MODE_FLAG_*
};

// 模式设置流程：
// drm_crtc_helper_set_mode(crtc, mode, ...)
//   → 调用 connector->mode_valid(mode)  验证
//   → 调用 encoder->compute_config(mode) 计算配置
//   → 调用 crtc->mode_set(mode)        配置定时器
//   → 调用 encoder->mode_set(mode)     配置编码器
//   → 调用 connector->mode_set(mode)   配置连接器
//   → crtc->enable()                   启动输出
```

---

## 4. fb_helper——帧缓冲控制台 @ drm_fb_helper.c

```c
// framebuffer 控制台集成——在 DRM 上模拟 VGA 文本控制台
// 当 DRM 驱动注册时 → drm_fb_helper_init()
// → 创建一个 framebuffer + 关联 plane
// → 实现 struct fb_ops → /dev/fb0 显示

struct drm_fb_helper {
    struct drm_device *dev;
    struct fb_info *fbdev;                   // fbdev 控制台
    struct drm_framebuffer *fb;               // DRM 帧缓冲
    struct drm_display_mode *preferred_mode;  // 偏好模式
};
```

---

## 5. 调试

```bash
# 查看 DRM 信息
cat /sys/kernel/debug/dri/0/state
cat /sys/kernel/debug/dri/0/crtc-0

# 查看连接器
cat /sys/class/drm/card0-HDMI-A-1/status
cat /sys/class/drm/card0-HDMI-A-1/modes

# 测试模式设置
modetest -M x86 -c
modetest -M x86 -s 32:1920x1080

# atomic 测试
kmstest --atomic -c

# 跟踪 atomic 提交
echo 1 > /sys/kernel/debug/tracing/events/drm/drm_atomic_commit/enable
```

---

## 6. 关键函数索引

| 函数 | 文件 | 作用 |
|------|------|------|
| `drm_atomic_commit` | `drm_atomic.c` | Atomic 提交入口 |
| `drm_atomic_helper_check` | `drm_atomic_helper.c` | 状态验证 |
| `drm_atomic_helper_commit_tail` | `drm_atomic_helper.c` | 提交执行 |
| `drm_crtc_helper_set_mode` | `drm_crtc_helper.c` | CRTC 模式设置 |
| `drm_fb_helper_init` | `drm_fb_helper.c` | fbdev 初始 |
| `drm_mode_create` | `drm_modes.c` | 模式创建 |
| `drm_connector_init` | `drm_connector.c` | 连接器初始化 |

---

## 7. 总结

DRM/KMS 通过 **atomic modeset**（`drm_atomic_commit`）原子地更新 CRTC/Encoder/Connector/Plane 状态。`struct drm_atomic_state` 保存所有对象的更新，通过 check→prepare→swap→commit_tail 四阶段完成。帧缓冲控制台通过 `drm_fb_helper` 在 DRM 上模拟 fbdev。

---

*分析工具：doom-lsp（clangd LSP 18.x）| 分析日期：2026-05-02 | 内核版本：Linux 7.0-rc1*
