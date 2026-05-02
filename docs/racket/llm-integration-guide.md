# LLM集成使用指南

## 🎯 **概述**

本系统集成了真实LLM（OpenAI GPT-4o），实现了**自然语言到电路DSL的完整转换**。用户可以用自然语言描述电路需求，LLM自动生成合法的Racket DSL代码。

## 🔧 **快速开始**

### **1. 环境设置**
```bash
# 设置API密钥
export OPENAI_API_KEY=sk-XXXXXXXXXXXXXXXXXXXXXXXX

# 安装依赖
raco pkg install json net
```

### **2. 基本使用**
```racket
;; 加载系统
(require "circuit-dsl-llm-integration.rkt")

;; 用自然语言生成电路
(define intent "设计一个RC低通滤波器，输入5V，电阻1k，电容1uF")
(define raw-stx (llm-generate-circuit intent))

;; 验证和生成代码
(define circ (eval raw-stx))
(validate-circuit circ)
(generate-spice circ "output.cir")
(generate-cpp-simulator circ "output.cpp")
```

### **3. 运行示例**
```bash
# 运行LLM示例
racket -e '(require "circuit-dsl-llm-integration.rkt") (test-llm)'
```

## 📝 **支持的意图类型**

### **基础电路**
```racket
;; RC滤波器
"设计一个RC低通滤波器，输入5V，电阻1k，电容1uF"

;; 分压器
"设计一个电阻分压器，输入12V，输出5V"

;; 运算放大器
"设计一个反相运算放大器，增益10倍，输入1V"
```

### **带参数的电路**
```racket
;; 带容差
"设计一个带5%容差的电阻分压器"

;; 带分布
"设计一个电容值为正态分布的RC滤波器"

;; 带优化目标
"设计一个功耗最小的LED驱动电路"
```

### **带子电路的电路**
```racket
;; 使用子电路
"设计一个使用运算放大器子电路的放大器"

;; 复杂系统
"设计一个带滤波器和放大器的传感器接口电路"
```

## 🎨 **LLM提示工程**

### **系统提示**
```racket
;; 当前系统提示
"你是电路DSL专家。请只输出合法的Racket代码（define-subcircuit 和 define-circuit），不要任何解释、markdown或额外文字。"
```

### **用户提示结构**
```racket
;; 标准提示结构
(format "请根据以下需求生成合法的Racket电路DSL代码，支持子电路、参数化、概率类型、命名节点。

需求：~a

支持语法：
1. 子电路定义：
   (define-subcircuit 名称 (nodes 节点...) 元件...)
2. 电路定义：
   (define-circuit 名称 #:title \"标题\" #:analysis (类型) 元件... 实例... 探测点...)
3. 元件语法：
   (元件类型 标识 值 (nodes 节点...) #:选项 ...)
4. 实例语法：
   (instance 标识 子电路名 (nodes 节点...))
5. 探测点：
   (probe 类型 名称 节点)

只输出代码，不要任何解释。" intent)
```

### **改进提示（可选）**
```racket
;; 更详细的提示
(format "你是一个专业的电路设计专家。请根据以下需求生成Racket DSL代码。

电路需求：~a

要求：
1. 使用合法的Racket语法
2. 支持以下元件：vsource, resistor, capacitor, inductor, diode, mosfet, opamp, switch
3. 支持子电路定义和使用
4. 支持参数化值（如 (* 1k R)）
5. 支持概率类型（如 #:tolerance 0.05）
6. 包含必要的探测点
7. 包含适当的分析类型（dc, transient, ac）

请只输出代码，不要任何解释。" intent)
```

## 🔧 **配置选项**

### **LLM提供商**
```racket
;; 当前支持OpenAI，可扩展其他提供商
(define LLM-PROVIDER 'openai)  ; 可改为 'anthropic, 'grok等

;; OpenAI配置
(define MODEL "gpt-4o")        ; 可改为 "gpt-4-turbo", "gpt-3.5-turbo"
(define MAX_TOKENS 1024)
(define TEMPERATURE 0.1)       ; 低温度确保代码一致性
```

### **API调用参数**
```racket
;; 调用参数
(define (call-llm prompt)
  (define body (jsexpr->string
                (hasheq 'model MODEL
                        'max_tokens MAX_TOKENS
                        'temperature TEMPERATURE
                        'messages ...)))
  ...)
```

### **错误处理**
```racket
;; 增强的错误处理
(define (safe-llm-generate-circuit intent)
  (with-handlers ([exn:fail? 
                   (λ (e) 
                     (printf "❌ LLM调用失败：~a\n" (exn-message e))
                     #f)])
    (llm-generate-circuit intent)))
```

## 📊 **性能优化**

### **缓存机制**
```racket
;; 实现响应缓存
(define response-cache (make-hash))

(define (cached-llm-generate-circuit intent)
  (define cache-key (sha256 intent))
  (cond
    [(hash-has-key? response-cache cache-key)
     (printf "📦 使用缓存响应\n")
     (hash-ref response-cache cache-key)]
    [else
     (define response (llm-generate-circuit intent))
     (hash-set! response-cache cache-key response)
     response]))
```

### **批量处理**
```racket
;; 批量生成多个电路
(define (batch-generate-circuits intents)
  (for/list ([intent intents])
    (printf "处理意图：~a\n" intent)
    (define circ (llm-generate-circuit intent))
    (validate-circuit circ)
    circ))
```

### **并发处理**
```racket
;; 使用future并发处理
(define (parallel-generate intents)
  (define futures
    (for/list ([intent intents])
      (future (λ () (llm-generate-circuit intent)))))
  
  (for/list ([f futures])
    (touch f)))
```

## 🚀 **高级用法**

### **迭代优化**
```racket
;; 迭代优化电路设计
(define (optimize-circuit initial-intent iterations)
  (let loop ([intent initial-intent] [i 0])
    (when (< i iterations)
      (printf "迭代 ~a: ~a\n" (+ i 1) intent)
      (define circ (llm-generate-circuit intent))
      (validate-circuit circ)
      
      ;; 分析结果并生成新的意图
      (define new-intent (analyze-and-improve circ intent))
      (loop new-intent (+ i 1)))))
```

### **多LLM投票**
```racket
;; 使用多个LLM投票选择最佳设计
(define (multi-llm-vote intent)
  (define responses
    (list (call-llm-provider 'openai intent)
          (call-llm-provider 'anthropic intent)
          (call-llm-provider 'grok intent)))
  
  ;; 选择最一致的响应
  (select-best-response responses))
```

### **约束引导生成**
```racket
;; 带约束的生成
(define (generate-with-constraints intent constraints)
  (define prompt
    (format "~a\n\n约束条件：\n~a\n\n请确保设计满足所有约束。" 
            intent 
            (string-join constraints "\n")))
  
  (llm-generate-circuit prompt))
```

## 🔍 **调试和故障排除**

### **常见问题**
```racket
;; 1. API密钥错误
;; 症状：LLM调用失败
;; 解决：检查 OPENAI_API_KEY 环境变量

;; 2. 语法错误
;; 症状：eval失败
;; 解决：检查LLM返回的代码语法

;; 3. 网络问题
;; 症状：连接超时
;; 解决：检查网络连接，增加超时时间
```

### **调试工具**
```racket
;; 保存LLM响应
(define (debug-llm-response intent)
  (define response (call-llm intent))
  (with-output-to-file "llm-debug.log" #:exists 'append
    (λ ()
      (printf "=== Intent: ~a ===\n" intent)
      (printf "Response: ~a\n\n" response)))
  response)

;; 验证LLM输出
(define (validate-llm-output code)
  (with-handlers ([exn:fail:syntax?
                   (λ (e) 
                     (printf "❌ 语法错误：~a\n" (exn-message e))
                     #f)])
    (read-syntax 'llm-input (open-input-string code))
    #t))
```

### **性能监控**
```racket
;; 监控LLM调用性能
(define (monitored-llm-generate intent)
  (define start-time (current-inexact-milliseconds))
  (define response (llm-generate-circuit intent))
  (define end-time (current-inexact-milliseconds))
  
  (printf "⏱️ LLM调用耗时：~a ms\n" (- end-time start-time))
  response)
```

## 📈 **最佳实践**

### **意图描述技巧**
```racket
;; 好：清晰具体
"设计一个输入5V，输出3.3V的LDO稳压器，最大负载电流500mA"

;; 不好：模糊
"设计一个电源电路"

;; 好：包含约束
"设计一个带过流保护的Buck转换器，效率>90%，输入12-24V，输出5V/2A"

;; 好：包含性能指标
"设计一个带宽100kHz，增益40dB，噪声<10µV的仪表放大器"
```

### **代码生成优化**
```racket
;; 1. 分步生成
;; 先生成子电路，再生成主电路

;; 2. 验证后修复
;; 如果生成的代码有错误，让LLM修复

;; 3. 示例引导
;; 提供类似电路的示例作为参考
```

### **错误处理策略**
```racket
;; 1. 重试机制
(define (llm-generate-with-retry intent max-retries)
  (let loop ([retry 0])
    (with-handlers ([exn:fail? 
                     (λ (e) 
                       (when (< retry max-retries)
                         (printf "重试 ~a/~a\n" (+ retry 1) max-retries)
                         (loop (+ retry 1))))])
      (llm-generate-circuit intent))))

;; 2. 降级策略
;; 如果GPT-4o失败，降级到GPT-3.5

;; 3. 本地回退
;; 如果LLM不可用，使用本地规则引擎
```

## 🏭 **生产部署**

### **环境配置**
```bash
# 生产环境配置
export OPENAI_API_KEY=sk-prod-...
export OPENAI_BASE_URL=https://api.openai.com/v1
export REQUEST_TIMEOUT=30000  # 30秒超时
export MAX_RETRIES=3
```

### **监控和日志**
```racket
;; 生产日志
(define (log-llm-request intent response success?)
  (with-output-to-file "/var/log/circuit-dsl/llm.log" #:exists 'append
    (λ ()
      (printf "[~a] Intent: ~a | Success: ~a | Response: ~a\n"
              (current-date-string)
              intent
              success?
              (if success? "OK" "FAILED")))))
```

### **限流和配额**
```racket
;; 实现限流
(define request-counter 0)
(define last-reset-time (current-seconds))

(define (check-rate-limit)
  (define now (current-seconds))
  (when (> (- now last-reset-time) 3600)  ; 每小时重置
    (set! request-counter 0)
    (set! last-reset-time now))
  
  (when (>= request-counter 100)  ; 每小时最多100次
    (error 'rate-limit "每小时请求次数超限"))
  
  (set! request-counter (+ request-counter 1)))
```

## 🔮 **未来扩展**

### **多模态支持**
```racket
;; 支持图像输入
(define (generate-from-image image-path)
  ;; 使用多模态LLM分析电路图
  ...)

;; 支持语音输入
(define (generate-from-speech audio-path)
  ;; 语音转文本 + LLM生成
  ...)
```

### **知识库增强**
```racket
;; 集成电路知识库
(define (enhanced-llm-generate intent)
  (define context (fetch-circuit-knowledge intent))
  (define prompt (format "~a\n\n相关知识：\n~a" intent context))
  (llm-generate-circuit prompt))
```

### **协作设计**
```racket
;; 多人协作
(define (collaborative-design intents users)
  ;; 合并多个用户的需求
  ;; 生成协作设计
  ...)
```

## 🏁 **总结**

### **核心价值**
1. **自然语言接口**: 让电路设计更直观
2. **智能生成**: LLM理解复杂需求
3. **代码质量**: 生成合法的DSL代码
4. **生产效率**: 大幅减少手动编码

### **使用建议**
1. **从简单开始**: 先尝试基础电路
2. **逐步复杂**: 逐步增加需求复杂度
3. **验证始终**: 始终运行验证检查
4. **迭代优化**: 基于结果优化意图

### **成功案例**
```racket
;; 案例1：快速原型
"设计一个温度传感器接口电路" → 完整DSL代码

;; 案例2：优化设计
"优化这个RC滤波器的相位响应" → 改进的DSL代码

;; 案例3：系统设计
"设计一个完整的电源管理系统" → 包含多个子电路的DSL
```

**通过LLM集成，电路设计从专业技能变成了自然语言对话。** 🚀