# 49-thermal — 热管理深度源码分析

> 使用 doom-lsp（clangd LSP）进行逐行符号解析

---

## 0. 概述

**thermal 框架** 管理设备温度，当温度超过阈值时触发冷却措施。核心概念：thermal zone（温度区）、cooling device（冷却设备）、governor（调节策略）。

---

## 1. 核心路径

```
温度更新：
  thermal_zone_device_update(tz, THERMAL_EVENT_TEMP_SENSOR)
    │
    ├─ 读取当前温度
    ├─ 选择 governor
    │    ├─ step_wise:     逐级升高/降低冷却
    │    ├─ fair_share:    按权重分配冷却
    │    ├─ user_space:    通知用户空间处理
    │    └─ power_allocator: PID 温控
    │
    └─ governor->throttle(tz)
         └─ 调整 cooling device 状态
```

---

*分析工具：doom-lsp（clangd LSP）*
