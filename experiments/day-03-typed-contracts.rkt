#lang typed/racket

;; ============================================
;; Day 3: Typed Racket + 高阶契约实战
;; 目标：让AI生成代码"自我验证"
;; ============================================

(require racket/contract
         racket/match)

(printf "🎯 Day 3: Typed Racket与AI代码验证\n")
(printf "============================================\n\n")

;; ==================== 1. Typed Racket基础 ====================

(printf "=== 1. Typed Racket基础类型 ===\n")

;; 基础类型注解
(: add-integers (-> Integer Integer Integer))
(define (add-integers x y)
  (+ x y))

(: concatenate-strings (-> String String String))
(define (concatenate-strings s1 s2)
  (string-append s1 s2))

;; 测试
(printf "整数相加: ~a + ~a = ~a\n" 5 3 (add-integers 5 3))
(printf "字符串连接: ~a + ~a = ~a\n" "Hello, " "World!" (concatenate-strings "Hello, " "World!"))

;; ==================== 2. 复合类型 ====================

(printf "\n=== 2. 复合类型 ===\n")

;; 列表类型
(: sum-list (-> (Listof Integer) Integer))
(define (sum-list lst)
  (apply + lst))

;; 可选类型
(: safe-first (-> (Listof Integer) (U Integer #f)))
(define (safe-first lst)
  (if (null? lst) #f (car lst)))

;; 测试
(define numbers (list 1 2 3 4 5))
(printf "列表求和: ~a = ~a\n" numbers (sum-list numbers))
(printf "安全取首元素: ~a = ~a\n" numbers (safe-first numbers))
(printf "空列表安全取首: ~a = ~a\n" '() (safe-first '()))

;; ==================== 3. 多态类型 ====================

(printf "\n=== 3. 多态类型（泛型） ===\n")

;; 泛型函数
(: identity (All (A) (-> A A)))
(define (identity x) x)

(: map-list (All (A B) (-> (-> A B) (Listof A) (Listof B))))
(define (map-list f lst)
  (map f lst))

;; 测试
(printf "泛型恒等函数: ~a → ~a\n" 42 (identity 42))
(printf "泛型恒等函数: ~a → ~a\n" "hello" (identity "hello"))

(define doubled (map-list (λ ([x : Integer]) (* x 2)) numbers))
(printf "泛型映射: ~a → ~a\n" numbers doubled)

;; ==================== 4. 结构体类型 ====================

(printf "\n=== 4. 结构体类型 ===\n")

;; 定义类型化结构体
(struct person ([name : String] [age : Integer]) #:transparent)

(: create-person (-> String Integer person))
(define (create-person name age)
  (person name age))

(: person-adult? (-> person Boolean))
(define (person-adult? p)
  (>= (person-age p) 18))

;; 测试
(define alice (create-person "Alice" 25))
(printf "创建人物: ~a\n" alice)
(printf "是否成年: ~a\n" (person-adult? alice))

;; ==================== 5. 契约系统基础 ====================

(printf "\n=== 5. 契约系统基础 ===\n")

;; 简单契约
(define/contract (safe-divide x y)
  (-> number? (and/c number? (not/c zero?)) number?)
  (/ x y))

;; 测试契约
(printf "安全除法: 10 / 2 = ~a\n" (safe-divide 10 2))

;; 契约违反（会被捕获）
(with-handlers ([exn:fail:contract? 
                 (λ (e) (printf "✅ 契约正确捕获错误: ~a\n" (exn-message e)))])
  (safe-divide 10 0))

;; ==================== 6. 高阶契约 ====================

(printf "\n=== 6. 高阶契约（函数契约） ===\n")

;; 验证函数行为的契约
(define/contract (apply-with-validation f x validator)
  (-> (-> any/c any/c) any/c (-> any/c boolean?) any/c)
  (let ([result (f x)])
    (unless (validator result)
      (error "结果验证失败"))
    result))

;; 使用示例
(define/contract (double x)
  (-> number? number?)
  (* 2 x))

(define result (apply-with-validation double 5 (λ (r) (> r 0))))
(printf "带验证的函数应用: double(5) = ~a\n" result)

;; ==================== 7. 自定义契约 ====================

(printf "\n=== 7. 自定义契约 ===\n")

;; 自定义契约
(define non-empty-string?
  (and/c string? (λ (s) (> (string-length s) 0))))

(define valid-age?
  (integer-in 0 150))

(define/contract (create-valid-person name age)
  (-> non-empty-string? valid-age? (hash/c 'name string? 'age integer?))
  (hash 'name name 'age age))

;; 测试
(printf "创建有效人物: ~a\n" (create-valid-person "Bob" 30))

;; 契约违反
(with-handlers ([exn:fail:contract?
                 (λ (e) (printf "✅ 自定义契约捕获: ~a\n" (exn-message e)))])
  (create-valid-person "" 30))

;; ==================== 8. AI代码验证框架 ====================

(printf "\n=== 8. AI代码验证框架 ===\n")

;; AI代码验证器结构
(struct ai-validator
  ([type-sig : Any]          ; 类型签名
   [pre-cond : (-> Any Boolean)]    ; 前置条件
   [post-cond : (-> Any Boolean)]   ; 后置条件
   [test-cases : (Listof Any)])     ; 测试用例
  #:transparent)

;; 验证AI生成的函数
(: validate-ai-function (-> String ai-validator Boolean))
(define (validate-ai-function code validator)
  (match-let ([(ai-validator type-sig pre post tests) validator])
    (printf "验证AI函数代码...\n")
    (printf "代码长度: ~a 字符\n" (string-length code))
    
    ;; 这里可以添加实际的编译和验证逻辑
    ;; 为了演示，我们假设验证通过
    #t))

;; 创建验证器示例
(define simple-validator
  (ai-validator
   '(-> Integer Integer Integer)  ; 类型签名
   (λ (args) (and (integer? (car args)) (integer? (cadr args))))  ; 前置条件
   (λ (result) (integer? result))  ; 后置条件
   '(((1 2) 3) ((5 3) 8))))       ; 测试用例

(printf "创建AI验证器: ~a\n" simple-validator)

;; ==================== 9. 混合类型环境 ====================

(printf "\n=== 9. 混合类型环境 ===\n")

;; 从无类型Racket导入函数
(require/typed racket/base
  [displayln (-> String Void)])

;; 调用无类型函数
(displayln "这是从Typed Racket调用的无类型函数")

;; ==================== 10. 错误处理与恢复 ====================

(printf "\n=== 10. 错误处理与恢复 ===\n")

(: safe-process (-> Integer (U Integer 'error)))
(define (safe-process n)
  (if (negative? n)
      'error
      (* n n)))

(define/contract (robust-ai-operation input handler)
  (-> any/c (-> any/c any/c) any/c)
  (with-handlers ([exn:fail? handler])
    ;; AI生成的操作
    (if (zero? (random 5))
        (error "模拟AI操作失败")
        (format "AI操作成功: ~a" input))))

;; 测试
(printf "安全处理正数: ~a → ~a\n" 5 (safe-process 5))
(printf "安全处理负数: ~a → ~a\n" -5 (safe-process -5))

(define result2 (robust-ai-operation "测试数据" (λ (e) "优雅降级")))
(printf "鲁棒AI操作: ~a\n" result2)

;; ==================== 11. 完整的AI代码生成与验证 ====================

(printf "\n=== 11. 完整的AI代码生成与验证 ===\n")

;; 模拟AI生成的代码
(define ai-generated-code
  "(lambda (x y) (+ x y))")

;; 为AI代码添加类型安全包装
(define/contract (type-safe-ai-function code)
  (-> string? (-> integer? integer? integer?))
  (let ([proc (eval (read (open-input-string code)))])
    (contract (-> integer? integer? integer?)
              proc
              'ai-generated
              'caller)))

;; 创建类型安全的AI函数
(define safe-add (type-safe-ai-function ai-generated-code))
(printf "类型安全的AI函数: ~a + ~a = ~a\n" 7 8 (safe-add 7 8))

;; ==================== 学习总结 ====================

(printf "\n=== 学习总结 ===\n")
(printf "1. Typed Racket提供编译期类型安全\n")
(printf "2. 契约系统提供运行时行为验证\n")
(printf "3. 渐进式类型化支持从脚本到生产\n")
(printf "4. 混合类型环境实现无缝集成\n")
(printf "5. AI代码可以通过类型+契约双重验证\n")

(printf "\n=== AI代码验证层次 ===\n")
(printf "1. 语法层: 解析器检查\n")
(printf "2. 类型层: 静态类型检查\n")
(printf "3. 契约层: 运行时行为验证\n")
(printf "4. 测试层: 用例覆盖验证\n")
(printf "5. 形式层: 数学证明验证\n")

(printf "\n=== 实际应用场景 ===\n")
(printf "• 金融AI: 交易算法类型安全\n")
(printf "• 医疗AI: 诊断逻辑契约验证\n")
(printf "• 自动驾驶: 控制代码形式验证\n")
(printf "• 代码生成: AI输出自动验证\n")

(printf "\n=== 明日学习方向 ===\n")
(printf "Day 4: Rosette与形式验证\n")
(printf "• 符号执行验证AI代码\n")
(printf "• 自动发现边界条件\n")
(printf "• 程序合成与验证\n")
(printf "• 完整的形式验证案例\n")

(printf "\n🎉 Day 3 实战完成！\n")
(printf "你已掌握Typed Racket和契约系统的核心概念！🚀\n")
(printf "现在你可以为AI生成代码添加多层安全验证了！\n")

;; ==================== 扩展练习建议 ====================

(printf "\n=== 扩展练习 ===\n")
(printf "1. 为JSON解析器添加完整类型签名\n")
(printf "2. 创建验证HTTP API响应的契约\n")
(printf "3. 实现AI代码的自动测试生成\n")
(printf "4. 设计混合类型项目的架构\n")
(printf "5. 探索Typed Racket的性能影响\n")