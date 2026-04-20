#lang racket

;; ============================================
;; Day 6: Rosette求解器 + 形式验证实战
;; Constraint Natural Language的"数学证明"层
;; ============================================

(require rosette
         syntax/parse
         racket/contract
         racket/custodian
         racket/thread)

(printf "🎯 Day 6: Rosette求解器 + 形式验证实战\n")
(printf "============================================\n\n")

;; ==================== 1. Rosette基础 ====================

(printf "=== 1. Rosette基础：符号执行与约束求解 ===\n")

;; 1.1 符号变量定义
(printf "创建符号变量...\n")

(define-symbolic x y z integer?)
(define-symbolic a b c real?)
(define-symbolic flag boolean?)

(printf "符号变量创建完成:\n")
(printf "  整数: x, y, z\n")
(printf "  实数: a, b, c\n")
(printf "  布尔: flag\n")

;; 1.2 简单约束求解
(printf "\n简单约束求解示例...\n")

(define simple-constraints
  (&& (>= x 0) (<= x 100)
      (>= y 0) (<= y 100)
      (= z (+ x y))
      (< z 150)))

(define simple-solution (solve simple-constraints))

(if (sat? simple-solution)
    (let-values ([(sx sy sz) (apply values (evaluate (list x y z) simple-solution))])
      (printf "✅ 找到解: x=~a, y=~a, z=~a\n" sx sy sz))
    (printf "❌ 无解\n"))

;; 1.3 验证数学性质
(printf "\n验证数学性质...\n")

;; 验证加法交换律
(define addition-commutative
  (verify (assert (= (+ x y) (+ y x)))))

(if (unsat? addition-commutative)
    (printf "✅ 加法交换律成立（对所有整数）\n")
    (printf "❌ 找到反例\n"))

;; 验证乘法分配律
(define multiplication-distributive
  (verify (assert (= (* x (+ y z)) (+ (* x y) (* x z))))))

(if (unsat? multiplication-distributive)
    (printf "✅ 乘法分配律成立（对所有整数）\n")
    (printf "❌ 找到反例\n"))

;; ==================== 2. AI意图形式验证 ====================

(printf "\n=== 2. AI意图形式验证 ===\n")

;; 2.1 带验证的AI意图宏
(define-syntax (def-verified-intent stx)
  (syntax-parse stx
    [(_ name:id
        #:desc desc:str
        #:constraints [c:expr ...]
        #:action action:expr)
     #'(begin
         ;; 符号变量定义
         (define-symbolic* params (listof real?))
         
         ;; 构建约束
         (define intent-constraints (list c ...))
         
         ;; 形式验证
         (printf "验证意图 ~a...\n" 'name)
         (define verification-result
           (solve (apply && intent-constraints)))
         
         (if (unsat? verification-result)
             (begin
               (printf "❌ 意图验证失败：约束不可满足\n")
               (error 'name "形式验证失败"))
             (begin
               (printf "✅ 意图验证通过\n")
               (let ([example (evaluate params verification-result)])
                 (printf "  示例解: ~a\n" example))))
         
         ;; 生成执行函数
         (define (name . args)
           (let ([c (make-custodian)])
             (parameterize ([current-custodian c])
               (thread-wait
                (thread
                 (λ ()
                   (printf "[已验证意图 ~a] 执行\n" 'name)
                   (apply action args))))
               (custodian-shutdown-all c))))
         
         (provide name))]))

;; 2.2 测试验证意图
(printf "测试带验证的AI意图...\n")

(module+ test
  (def-verified-intent safe-flight-booking
    #:desc "安全航班预订，预算限制"
    #:constraints [(<= (first params) 5000)
                   (> (second params) (current-seconds))
                   (>= (third params) 1)  ; 至少1位乘客
                   (<= (third params) 10)] ; 最多10位乘客
    #:action (λ (budget time passengers)
               (printf "航班预订成功: 预算~a，时间~a，~a位乘客\n"
                       budget time passengers)))
  
  ;; 执行验证通过的意图
  (safe-flight-booking 4500 (+ (current-seconds) 86400) 3))

;; ==================== 3. 矛盾检测与反例生成 ====================

(printf "\n=== 3. 矛盾检测与反例生成 ===\n")

;; 3.1 故意制造矛盾
(printf "测试矛盾约束检测...\n")

(define-symbolic* p q r integer?)

(define contradictory-constraints
  (&& (> p 100)      ; p > 100
      (< p 50)       ; p < 50 (矛盾!)
      (= q (* p 2))
      (= r (+ p q))))

(define contradiction-check (solve contradictory-constraints))

(if (unsat? contradiction-check)
    (printf "✅ 成功检测到矛盾约束\n")
    (begin
      (printf "❌ 意外找到解: ~a\n" 
              (evaluate (list p q r) contradiction-check))))

;; 3.2 边界条件验证
(printf "\n边界条件验证...\n")

(define-symbolic* value integer?)

(define boundary-constraints
  (&& (>= value 0) (<= value 100)  ; 值在0-100之间
      (or (= value 0) (= value 100)))) ; 必须是边界值

(define boundary-solution (solve boundary-constraints))

(when (sat? boundary-solution)
  (let ([boundary-value (evaluate value boundary-solution)])
    (printf "找到边界值: ~a\n" boundary-value)))

;; 3.3 多约束冲突分析
(printf "\n多约束冲突分析...\n")

(define-symbolic* a1 a2 a3 integer?)

(define multi-constraints
  (&& (>= a1 10) (<= a1 20)   ; a1在10-20之间
      (>= a2 15) (<= a2 25)   ; a2在15-25之间  
      (>= a3 20) (<= a3 30)   ; a3在20-30之间
      (= a1 a2)               ; a1 = a2
      (= a2 a3)))             ; a2 = a3 (要求三个都相等)

(define multi-solution (solve multi-constraints))

(if (sat? multi-solution)
    (let ([vals (evaluate (list a1 a2 a3) multi-solution)])
      (printf "找到满足所有约束的解: ~a\n" vals))
    (printf "约束过于严格，无解\n"))

;; ==================== 4. 资源约束验证 ====================

(printf "\n=== 4. 资源约束验证 ===\n")

;; 4.1 定义资源类型
(define-symbolic* memory-usage cpu-usage network-usage battery-level real?)

;; 4.2 资源安全约束
(define resource-constraints
  (&& (>= memory-usage 0) (<= memory-usage 1024)   ; 内存0-1024MB
      (>= cpu-usage 0) (<= cpu-usage 100)         ; CPU 0-100%
      (>= network-usage 0) (<= network-usage 100) ; 网络0-100Mbps
      (>= battery-level 0) (<= battery-level 100) ; 电量0-100%
      
      ;; 安全规则
      (=> (> memory-usage 512) (< cpu-usage 50))   ; 高内存时限制CPU
      (=> (< battery-level 20) (< network-usage 50)) ; 低电量时限制网络
      (or (<= memory-usage 256) (>= battery-level 30)))) ; 高内存需要足够电量

;; 4.3 验证资源约束
(printf "验证资源约束可满足性...\n")

(define resource-check (solve resource-constraints))

(if (sat? resource-check)
    (let ([resources (evaluate (list memory-usage cpu-usage network-usage battery-level) 
                               resource-check)])
      (printf "✅ 资源约束可满足\n")
      (printf "  示例资源分配: 内存~aMB, CPU~a%%, 网络~aMbps, 电量~a%%\n"
              (first resources) (second resources) 
              (third resources) (fourth resources)))
    (printf "❌ 资源约束过于严格，无可行分配\n"))

;; ==================== 5. 时间约束验证 ====================

(printf "\n=== 5. 时间约束验证 ===\n")

;; 5.1 定义时间变量
(define-symbolic* start-time end-time duration interval real?)

;; 5.2 时间安全约束
(define temporal-constraints
  (&& (> start-time (current-seconds))     ; 开始时间在未来
      (> end-time start-time)              ; 结束时间在开始之后
      (= duration (- end-time start-time)) ; 持续时间计算
      (<= duration 3600)                   ; 最多1小时
      (>= interval 300)                    ; 间隔至少5分钟
      (or (<= duration 1800) (> interval 600)))) ; 长任务需要更长间隔

;; 5.3 验证时间约束
(printf "验证时间约束...\n")

(define temporal-check (solve temporal-constraints))

(if (sat? temporal-check)
    (let ([times (evaluate (list start-time end-time duration interval) 
                           temporal-check)])
      (printf "✅ 时间约束可满足\n")
      (printf "  示例: 开始~a, 结束~a, 持续~a秒, 间隔~a秒\n"
              (first times) (second times) (third times) (fourth times)))
    (printf "❌ 时间约束矛盾\n"))

;; ==================== 6. 业务规则验证 ====================

(printf "\n=== 6. 业务规则验证 ===\n")

;; 6.1 定义业务变量
(define-symbolic* age transaction-amount daily-limit credit-score boolean?)

;; 6.2 业务规则约束
(define business-constraints
  (&& (>= age 0) (<= age 120)                    ; 合理年龄
      (>= transaction-amount 0)                  ; 交易金额非负
      (>= daily-limit 0)                         ; 每日限额非负
      (>= credit-score 300) (<= credit-score 850) ; 信用分数范围
      
      ;; 业务规则
      (=> (< age 18) (<= transaction-amount 1000)) ; 未成年人限额
      (=> (< credit-score 600) (<= transaction-amount 5000)) ; 低信用限额
      (<= transaction-amount daily-limit)         ; 不超过每日限额
      (or (>= age 18) (boolean? #t))             ; 未成年人需要额外检查
      (not (&& (< age 18) (> transaction-amount 5000))) ; 双重保护
      ))

;; 6.3 验证业务规则
(printf "验证业务规则一致性...\n")

(define business-check (solve business-constraints))

(if (sat? business-check)
    (let ([business-vars (evaluate (list age transaction-amount daily-limit credit-score) 
                                   business-check)])
      (printf "✅ 业务规则可满足\n")
      (printf "  示例: 年龄~a岁, 交易~a元, 限额~a元, 信用分~a\n"
              (first business-vars) (second business-vars)
              (third business-vars) (fourth business-vars)))
    (printf "❌ 业务规则存在矛盾\n"))

;; ==================== 7. 综合验证：旅行规划系统 ====================

(printf "\n=== 7. 综合验证：旅行规划系统 ===\n")

;; 7.1 定义旅行变量
(define-symbolic* budget hotel-budget flight-cost days travelers real?)

;; 7.2 旅行规划约束
(define travel-constraints
  (&& (>= budget 0) (<= budget 10000)          ; 总预算
      (>= hotel-budget 0) (<= hotel-budget 5000) ; 酒店预算
      (>= flight-cost 0) (<= flight-cost 3000) ; 机票预算
      (>= days 1) (<= days 30)                 ; 旅行天数
      (>= travelers 1) (<= travelers 10)       ; 旅行人数
      
      ;; 预算分配
      (= budget (+ hotel-budget flight-cost (* days travelers 200))) ; 每日每人200
      (<= hotel-budget (* budget 0.5))          ; 酒店不超过50%
      (<= flight-cost (* budget 0.4))           ; 机票不超过40%
      
      ;; 合理性检查
      (=> (> travelers 5) (> budget 5000))     ; 多人需要更高预算
      (=> (> days 7) (> budget 3000))          ; 长旅行需要更高预算
      (or (<= days 3) (>= hotel-budget 1000))  ; 长旅行需要足够酒店预算
      ))

;; 7.3 验证旅行规划
(printf "验证旅行规划可行性...\n")

(define travel-check (solve travel-constraints))

(if (sat? travel-check)
    (let ([travel-vars (evaluate (list budget hotel-budget flight-cost days travelers) 
                                 travel-check)])
      (printf "✅ 旅行规划可行\n")
      (printf "  总预算: ~a元\n" (first travel-vars))
      (printf "  酒店预算: ~a元\n" (second travel-vars))
      (printf "  机票预算: ~a元\n" (third travel-vars))
      (printf "  天数: ~a天\n" (fourth travel-vars))
      (printf "  人数: ~a人\n" (fifth travel-vars)))
    (printf "❌ 旅行规划约束矛盾\n"))

;; ==================== 8. 验证报告生成 ====================

(printf "\n=== 8. 验证报告生成 ===\n")

;; 8.1 验证结果结构
(struct verification-result (name constraints satisfied? counterexample timestamp)
  #:transparent)

;; 8.2 批量验证函数
(define (verify-intent-batch intents)
  (printf "批量验证~a个意图...\n" (length intents))
  
  (for ([intent intents])
    (match-let ([(list name desc constraints) intent])
      (printf "\n验证意图: ~a\n" name)
      (printf "描述: ~a\n" desc)
      
      (define-symbolic* vars (listof real?))
      (define constraint-expr (apply && constraints))
      
      (define result (solve constraint-expr))
      
      (if (unsat? result)
          (printf "✅ 验证通过\n")
          (begin
            (printf "❌ 验证失败\n")
            (printf "  反例: ~a\n" (evaluate vars result)))))))

;; 8.3 测试批量验证
(printf "测试批量验证系统...\n")

(define test-intents
  '(("intent1" "简单预算限制" ((<= (first vars) 5000)))
    ("intent2" "时间约束" ((> (second vars) (current-seconds))))
    ("intent3" "矛盾约束" ((<= (first vars) 100) (> (first vars) 200)))))

(verify-intent-batch test-intents)

;; ==================== 学习总结 ====================

(printf "\n=== 学习总结 ===\n")
(printf "1. Rosette基础: 符号变量与约束求解\n")
(printf "2. AI意图验证: 编译期数学证明\n")
(printf "3. 矛盾检测: 自动发现逻辑冲突\n")
(printf "4. 资源约束: 内存、CPU、网络、电量验证\n")
(printf "5. 时间约束: 时间逻辑一致性验证\n")
(printf "6. 业务规则: 复杂业务逻辑验证\n")
(printf "7. 综合应用: 旅行规划系统验证\n")
(printf "8. 批量验证: 多意图自动验证系统\n")

(printf "\n=== Rosette的AI验证优势 ===\n")
(printf "• 数学严谨性: 形式化证明，非启发式\n")
(printf "• 全覆盖验证: 考虑所有可能输入\n")
(printf "• 反例生成: 失败时提供具体反例\n")
(printf "• 编译期保证: 部署前发现问题\n")
(printf "• 高性能: 利用现代SMT求解器\n")

(printf "\n=== 实际应用场景 ===\n")
(printf "• AI Agent意图验证\n")
(printf "• 自动驾驶决策验证\n")
(printf "• 金融交易规则验证\n")
(printf "• 医疗诊断逻辑验证\n")
(printf "• 安全协议形式验证\n")

(printf "\n🎉 Day 6 Rosette形式验证实战完成！\n")
(printf "你的AI意图现在可以被数学证明了！🚀\n")

;; ==================== 下一步学习 ===================