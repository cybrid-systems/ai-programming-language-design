# 电路DSL语法设计文档

## 🎯 **设计理念**

### **核心原则**
1. **极简声明式**: 像描述电路图一样写代码
2. **直观自然**: 语法应该自解释，无需大量注释
3. **渐进增强**: 从最简单开始，逐步添加高级功能
4. **一致性**: 所有语法元素遵循统一模式

### **设计目标**
- 让电路工程师一看就懂
- 让新手也能快速上手
- 保持足够的表达能力
- 易于扩展和维护

## 📝 **基础语法规范**

### **1. 电路定义**
```racket
(define-circuit 电路名
  #:title "电路标题"          ; 可选
  #:analysis (分析类型 ...)   ; 可选，默认 dc
  
  (元件类型 元件标识 值 (nodes 节点1 节点2))
  ...
  
  (probe 测量类型 测量名 节点))
```

### **2. 节点表示**
```racket
;; 支持两种节点表示法
(nodes 1 0)      ; 数字节点，0为地
(nodes vin vout) ; 符号节点，自动编号
```

### **3. 元件语法**
```racket
;; 基础元件
(vsource V1 5.0 (nodes 1 0))      ; 电压源
(resistor R1 1000 (nodes 1 2))    ; 电阻
(capacitor C1 1e-6 (nodes 2 0))   ; 电容
(inductor L1 10e-6 (nodes 1 2))   ; 电感

;; 半导体元件
(diode D1 (nodes 1 2))            ; 二极管
(mosfet M1 (nodes drain source gate)) ; MOSFET
(opamp U1 (nodes in- in+ out))    ; 运算放大器

;; 开关和控制
(switch S1 (nodes 1 2) #:duty 0.5) ; 开关
(adc ADC1 (nodes in out) #:bits 8) ; ADC
```

### **4. 分析类型**
```racket
#:analysis (dc)                    ; 直流分析
#:analysis (transient #:stop-time 0.01 #:step 1e-6) ; 瞬态分析
#:analysis (ac #:freq-range (1 1e6)) ; 交流分析
#:analysis (noise #:freq 1e3)      ; 噪声分析
```

### **5. 测量点**
```racket
(probe voltage Vout 2)            ; 电压测量
(probe current I_R1 R1)           ; 电流测量
(probe power P_V1 V1)             ; 功率测量
(probe noise Vn_out 2)            ; 噪声测量
```

## 🔧 **语法扩展设计**

### **阶段1：基础完善（当前）**
```racket
;; 1. 更多基础元件
(inductor L1 10e-6 (nodes 1 2))
(diode D1 (nodes 1 2))
(opamp U1 (nodes 2 0 3))

;; 2. 参数化值
(resistor R1 (* 1k param))        ; 参数化电阻
(capacitor C1 (/ 1 (* 2 pi f R))) ; 表达式计算

;; 3. 命名节点
#:nodes ((vin 1) (vout 2) (gnd 0))
```

### **阶段2：中级功能**
```racket
;; 1. 子电路定义
(define-subcircuit rc-filter
  (resistor R1 1000 (nodes in out))
  (capacitor C1 1e-6 (nodes out 0)))

;; 2. 参数扫描
#:sweep (resistance (100 10000 100))

;; 3. 约束条件
#:constraint (voltage Vout > 2.5 < 3.3)
#:constraint (power P_total < 100m)
```

### **阶段3：高级功能**
```racket
;; 1. 概率类型
(resistor R1 1000 (nodes 1 2) #:tolerance 0.05)
(capacitor C1 1e-6 (nodes 2 0) #:distribution (normal 1e-6 0.1e-6))

;; 2. 优化目标
#:optimize (minimize power)
#:optimize (maximize bandwidth)

;; 3. 布局提示
#:pcb-hint "power-compact"
#:pcb-hint "mixed-signal"
```

## 🎨 **语法美学考虑**

### **可读性优先**
```racket
;; 好：清晰易读
(define-circuit buck-converter
  #:title "同步Buck降压转换器"
  #:analysis (transient #:stop-time 100e-6)
  
  (vsource Vin 12 (nodes 1 0))
  (mosfet HighSide (nodes 1 2 3) #:type nmos)
  (mosfet LowSide (nodes 2 4 5) #:type nmos)
  (inductor L1 22e-6 (nodes 2 6))
  (capacitor Cout 100e-6 (nodes 6 0))
  
  (probe voltage Vout 6))

;; 不好：过于紧凑
(define-circuit b (v Vin 12 (n 1 0))(m HS (n 1 2 3))(m LS (n 2 4 5))(l L1 22e-6 (n 2 6))(c Cout 100e-6 (n 6 0)))
```

### **一致性设计**
```racket
;; 所有元件遵循相同模式
(类型 标识 值 (nodes 节点1 节点2) #:选项 ...)

;; 所有分析类型统一格式
#:analysis (类型 #:参数1 值1 #:参数2 值2 ...)

;; 所有测量点统一格式
(probe 类型 名称 目标)
```

## 🔍 **语法验证规则**

### **静态检查**
1. **节点连续性**: 每个节点至少连接两个元件
2. **接地检查**: 必须有节点0（地）
3. **参数范围**: 电阻、电容值必须>0
4. **标识唯一性**: 元件标识不能重复

### **语义检查**
1. **KCL验证**: 每个节点电流和为0
2. **KVL验证**: 每个回路电压和为0
3. **功率平衡**: 输入功率=输出功率+损耗
4. **稳定性检查**: 避免奇异矩阵

## 📚 **示例库设计**

### **基础电路**
```racket
;; 1. RC滤波器
(define-circuit rc-lowpass ...)

;; 2. 分压器
(define-circuit voltage-divider ...)

;; 3. 运放放大器
(define-circuit opamp-inverting ...)

;; 4. LC谐振电路
(define-circuit lc-resonator ...)
```

### **中级电路**
```racket
;; 1. 开关电源
(define-circuit buck-converter ...)

;; 2. 传感器接口
(define-circuit photodiode-amplifier ...)

;; 3. 数据转换器
(define-circuit adc-frontend ...)
```

### **高级电路**
```racket
;; 1. 控制系统
(define-circuit pid-controller ...)

;; 2. 射频电路
(define-circuit lna-2ghz ...)

;; 3. 电源管理
(define-circuit pmic-design ...)
```

## 🛠️ **工具链集成**

### **代码生成**
```bash
# SPICE netlist
racket circuit-dsl.rkt --format spice

# C++仿真器
racket circuit-dsl.rkt --format cpp26

# Verilog/SystemVerilog
racket circuit-dsl.rkt --format verilog

# VHDL
racket circuit-dsl.rkt --format vhdl
```

### **可视化输出**
```bash
# 生成电路图
racket circuit-dsl.rkt --visualize schematic

# 生成波形图
racket circuit-dsl.rkt --visualize waveform

# 生成布局图
racket circuit-dsl.rkt --visualize layout
```

### **验证工具**
```bash
# 语法检查
racket circuit-dsl.rkt --validate syntax

# 语义检查
racket circuit-dsl.rkt --validate semantic

# 性能分析
racket circuit-dsl.rkt --validate performance
```

## 🔄 **工作流程设计**

### **设计阶段**
```racket
;; 1. 快速原型
(define-circuit prototype ...)

;; 2. 参数优化
#:sweep (R1 (100 10000 100))
#:optimize (maximize bandwidth)

;; 3. 验证确认
#:constraint (voltage Vout > 2.5 < 3.3)
#:constraint (power < 100m)
```

### **实现阶段**
```bash
# 生成生产代码
racket circuit-dsl.rkt --target cpp26 --optimize speed

# 运行仿真
./circuit_simulator

# 分析结果
python analyze_results.py
```

### **部署阶段**
```bash
# 生成制造文件
racket circuit-dsl.rkt --manufacture pcb

# 生成文档
racket circuit-dsl.rkt --documentation pdf

# 打包发布
tar -czf circuit-design.tar.gz *
```

## 🎯 **语法设计决策**

### **已确定的设计**
1. **节点表示**: `(nodes 1 0)` 优于 `(1 0)`，更明确
2. **元件语法**: `(类型 标识 值 节点)` 统一模式
3. **分析配置**: `#:analysis` 关键字前缀
4. **测量点**: `(probe 类型 名称 目标)` 统一格式

### **待讨论的设计**
1. **子电路语法**: 如何定义和引用子电路？
2. **参数传递**: 如何传递参数给子电路？
3. **条件语句**: 是否需要支持条件电路？
4. **循环结构**: 是否需要支持重复结构？

### **扩展方向**
1. **AI辅助**: 自然语言到DSL的转换
2. **形式验证**: 集成形式化验证工具
3. **协同设计**: 多人协作设计支持
4. **云集成**: 云端仿真和优化

## 📈 **演进路线图**

### **v1.0 - 基础版**
- 基础元件：电压源、电阻、电容、电感
- 基础分析：DC、瞬态
- 基础输出：SPICE、简单C++
- 基础验证：节点检查、参数范围

### **v1.5 - 增强版**
- 半导体元件：二极管、MOSFET、BJT、运放
- 高级分析：AC、噪声、温度
- 高级输出：优化C++、Verilog
- 高级验证：KCL/KVL、稳定性

### **v2.0 - 专业版**
- 系统元件：ADC、DAC、PLL、滤波器
- 系统分析：蒙特卡洛、灵敏度、良率
- 系统输出：生产级代码、制造文件
- 系统验证：形式验证、安全验证

### **v3.0 - AI版**
- AI辅助设计：自然语言接口
- AI优化：自动参数优化
- AI验证：智能错误检测
- AI生成：创新电路拓扑

## 🏁 **总结**

这个电路DSL语法设计遵循**渐进增强**的原则：

1. **从简单开始**: 最基本、最核心的语法元素
2. **保持一致性**: 所有扩展遵循相同模式
3. **注重可读性**: 让代码像电路图一样直观
4. **支持工具链**: 完整的开发、验证、部署流程

**核心价值**: 让电路设计从繁琐的netlist编写中解放出来，回归到**描述电路本质**的创造性工作中。

通过这个DSL，电路工程师可以：
- 更快速地表达设计意图
- 更可靠地验证设计正确性
- 更高效地生成生产代码
- 更轻松地探索设计空间

**这不是另一个电路描述语言，而是电路设计思维的升华。**