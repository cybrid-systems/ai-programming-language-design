#lang racket

;; ============================================
;; Day 3: 简化版契约系统实战
;; 目标：理解Racket契约如何验证AI生成代码
;; ============================================

(require racket/contract
         racket/match)

(printf "🎯 Day 3: Racket契约系统与AI代码验证\n")
(printf "============================================\n\n")

;; ==================== 1. 基础契约 ====================

(printf "=== 1. 基础契约示例 ===\n")

;; 简单数值契约
(define/contract (safe-add x y)
  (-> number? number? number?)
  (+ x y))

(printf "安全加法: ~a + ~a = ~a\n" 5 3 (safe-add 5 3))

;; 契约违反示例
(with-handlers ([exn:fail:contract?
                 (λ (e) (printf "✅ 契约正确捕获错误: ~a\n" (exn-message e)))])
  (safe-add "5" 3))

;; ==================== 2. 组合契约 ====================

(printf "\n=== 2. 组合契约 ===\n")

;; 自定义契约
(define non-empty-string?
  (and/c string? (λ (s) (> (string-length s) 0))))

(define valid-age?
  (integer-in 0 150))

(define/contract (create-person name age)
  (-> non-empty-string? valid-age? (hash/c symbol? any/c))
  (make-hash (list (cons 'name name) (cons 'age age))))

;; 测试有效输入
(printf "创建有效人物: ~a\n" (create-person "Alice" 25))

;; 测试无效输入
(with-handlers ([exn:fail:contract?
                 (λ (e) (printf "✅ 捕获无效姓名: ~a\n" (exn-message e)))])
  (create-person "" 25))

(with-handlers ([exn:fail:contract?
                 (λ (e) (printf "✅ 捕获无效年龄: ~a\n" (exn-message e)))])
  (create-person "Bob" 200))

;; ==================== 3. 高阶契约（函数契约） ====================

(printf "\n=== 3. 高阶函数契约 ===\n")

;; 验证函数行为的契约
(define/contract (apply-with-check f x)
  (-> (-> any/c any/c) any/c any/c)
  (let ([result (f x)])
    (printf "函数应用结果: ~a\n" result)
    result))

;; 使用示例
(define/contract (double n)
  (-> number? number?)
  (* 2 n))

(printf "带检查的函数应用: ~a\n" (apply-with-check double 5))

;; ==================== 4. 依赖契约 ====================

(printf "\n=== 4. 依赖契约 ===\n")

;; 输出依赖输入的契约
(define/contract (make-multiplier factor)
  (-> number? (-> number? number?))
  (λ (x) (* x factor)))

(define times3 (make-multiplier 3))
(printf "创建乘数函数: 5 * 3 = ~a\n" (times3 5))

;; ==================== 5. AI代码验证框架 ====================

(printf "\n=== 5. AI代码验证框架 ===\n")

;; AI代码验证器
(struct ai-validator
  (pre-conditions   ; 前置条件
   post-conditions  ; 后置条件
   test-cases)      ; 测试用例
  #:transparent)

;; 验证AI生成的函数
(define (validate-ai-function code validator)
  (match-let ([(ai-validator pre post tests) validator])
    (printf "验证AI函数代码...\n")
    (printf "代码: ~a\n" (substring code 0 (min 50 (string-length code))))
    
    ;; 这里可以添加实际的编译和验证逻辑
    ;; 为了演示，我们假设验证通过
    #t))

;; 创建验证器示例
(define simple-ai-validator
  (ai-validator
   (λ (args) (and (number? (car args)) (number? (cadr args))))  ; 前置条件
   (λ (result) (number? result))                                ; 后置条件
   '(((1 2) 3) ((5 3) 8))))                                     ; 测试用例

(printf "创建AI验证器成功\n")

;; ==================== 6. 错误处理与恢复 ====================

(printf "\n=== 6. 错误处理与恢复 ===\n")

;; 安全的AI操作包装器
(define/contract (safe-ai-operation input fallback)
  (-> any/c (-> any/c any/c) any/c)
  (with-handlers ([exn:fail? fallback])
    ;; 模拟AI操作（可能失败）
    (if (zero? (random 3))
        (error "AI操作失败")
        (format "AI操作成功: ~a" input))))

;; 测试
(printf "AI操作结果: ~a\n" (safe-ai-operation "测试数据" (λ (e) "优雅降级")))

;; ==================== 7. 完整的AI代码安全包装 ====================

(printf "\n=== 7. AI代码安全包装 ===\n")

;; 模拟AI生成的代码
(define ai-generated-code "(lambda (x y) (+ x y))")

;; 为AI代码添加安全包装
(define/contract (wrap-ai-code code)
  (-> string? (-> number? number? number?))
  (let ([proc (eval (read (open-input-string code)) (make-base-namespace))])
    (contract (-> number? number? number?)
              proc
              'ai-generated
              'caller)))

;; 创建安全的AI函数
(define safe-ai-add (wrap-ai-code ai-generated-code))
(printf "安全的AI加法函数: ~a + ~a = ~a\n" 7 8 (safe-ai-add 7 8))

;; 测试契约违反
(with-handlers ([exn:fail:contract?
                 (λ (e) (printf "✅ AI函数契约保护: ~a\n" (exn-message e)))])
  (safe-ai-add "7" 8))

;; ==================== 8. 实际应用：数据验证 ====================

(printf "\n=== 8. 实际应用：数据验证 ===\n")

;; 数据验证契约
(define valid-email?
  (and/c string?
         (λ (s) (regexp-match? #rx"^[^@]+@[^@]+\\.[^@]+$" s))))

(define valid-user-data?
  (hash/c symbol? any/c))

(define/contract (process-user-data data)
  (-> valid-user-data? any/c)
  (printf "处理用户数据: ~a\n" data)
  '处理成功)

;; 测试有效数据
(define good-data
  (hash 'name "张三"
        'email "zhangsan@example.com"
        'age 30))

(printf "处理有效数据: ~a\n" (process-user-data good-data))

;; 测试无效数据
(with-handlers ([exn:fail:contract?
                 (λ (e) (printf "✅ 捕获无效用户数据: ~a\n" (exn-message e)))])
  (process-user-data (hash 'name "" 'email "invalid" 'age 200)))

;; ==================== 9. 性能考虑：选择性契约 ====================

(printf "\n=== 9. 选择性契约 ===\n")

;; 只在调试时启用的契约
(define debug-mode #t)

(define (debug-contract contract)
  (if debug-mode
      contract
      any/c))

(define/contract (optimized-function x)
  (debug-contract (-> number? number?))
  (* x x))

(printf "选择性契约函数: ~a → ~a\n" 5 (optimized-function 5))

;; ==================== 学习总结 ====================

(printf "\n=== 学习总结 ===\n")
(printf "1. 基础契约: ->, and/c, or/c, not/c\n")
(printf "2. 自定义契约: 任意谓词函数\n")
(printf "3. 高阶契约: 验证函数行为\n")
(printf "4. 依赖契约: 输出依赖输入\n")
(printf "5. 错误处理: with-handlers优雅恢复\n")
(printf "6. 性能优化: 选择性启用契约\n")

(printf "\n=== AI代码验证层次 ===\n")
(printf "1. 语法验证: 解析器检查\n")
(printf "2. 契约验证: 运行时行为检查\n")
(printf "3. 类型验证: 静态类型检查（Typed Racket）\n")
(printf "4. 测试验证: 用例覆盖检查\n")

(printf "\n=== 实际应用场景 ===\n")
(printf "• API输入验证: 确保外部数据格式正确\n")
(printf "• AI生成代码: 包装不可信代码\n")
(printf "• 数据管道: 验证数据处理步骤\n")
(printf "• 配置验证: 确保配置参数有效\n")

(printf "\n=== 契约系统优势 ===\n")
(printf "• 运行时验证: 捕获动态错误\n")
(printf "• 渐进采用: 可以逐步添加契约\n")
(printf "• 错误消息: 详细的违反信息\n")
(printf "• 组合性: 可以组合复杂契约\n")

(printf "\n=== 扩展学习 ===\n")
(printf "1. 学习Typed Racket的静态类型系统\n")
(printf "2. 探索更复杂的契约组合模式\n")
(printf "3. 研究契约的性能影响和优化\n")
(printf "4. 实践契约在大型项目中的应用\n")

(printf "\n🎉 Day 3 实战完成！\n")
(printf "你已掌握Racket契约系统的核心概念！🚀\n")
(printf "现在你可以用契约保护AI生成的代码了！\n")

;; ==================== 练习建议 ====================

(printf "\n=== 练习建议 ===\n")
(printf "1. 为JSON解析器添加输入验证契约\n")
(printf "2. 创建验证HTTP响应的契约组合\n")
(printf "3. 实现AI代码的自动契约生成\n")
(printf "4. 设计选择性契约的配置系统\n")
(printf "5. 测试契约在性能关键路径的影响\n")