#lang racket

;; ============================================
;; Day 4: 基础验证实战
;; 目标：使用基本测试技术验证AI生成代码
;; ============================================

(require rackunit
         rackunit/text-ui)

(printf "🎯 Day 4: AI代码验证实战\n")
(printf "============================================\n\n")

;; ==================== 1. 基础测试 ====================

(printf "=== 1. 基础测试 ===\n")

;; 测试加法函数
(define (test-addition)
  (printf "测试加法函数...\n")
  
  (check-equal? (+ 1 2) 3 "1+2=3")
  (check-equal? (+ 0 0) 0 "0+0=0")
  (check-equal? (+ -5 5) 0 "-5+5=0")
  (check-equal? (+ 100 200) 300 "100+200=300")
  
  (printf "✅ 加法测试通过\n"))

(test-addition)

;; ==================== 2. 验证AI生成的排序算法 ====================

(printf "\n=== 2. 验证AI生成的排序算法 ===\n")

;; AI生成的排序函数
(define (ai-sort lst)
  (if (null? lst)
      '()
      (let ([min-elem (apply min lst)])
        (cons min-elem (ai-sort (remove min-elem lst))))))

;; 测试排序算法
(define (test-sort-algorithm)
  (printf "测试排序算法...\n")
  
  ;; 测试用例
  (define test-cases
    '((() ())                    ; 空列表
      ((1) (1))                  ; 单元素
      ((3 1 2) (1 2 3))         ; 正常情况
      ((5 5 5) (5 5 5))         ; 重复元素
      ((-3 0 3) (-3 0 3))       ; 负数
      ((9 8 7 6 5 4 3 2 1) (1 2 3 4 5 6 7 8 9)))) ; 逆序
  
  (for ([test test-cases])
    (let ([input (first test)]
          [expected (second test)])
      (check-equal? (ai-sort input) expected 
                    (format "排序: ~a -> ~a" input expected))))
  
  ;; 验证性质
  (printf "验证排序性质...\n")
  
  ;; 性质1: 排序是幂等的
  (let ([test-list '(5 2 8 1 9)])
    (check-equal? (ai-sort test-list) 
                  (ai-sort (ai-sort test-list))
                  "排序幂等性"))
  
  ;; 性质2: 排序后列表有序
  (let ([sorted (ai-sort '(3 1 4 1 5 9 2 6))])
    (check-true (apply <= sorted) "排序后有序"))
  
  (printf "✅ 排序算法验证通过\n"))

(test-sort-algorithm)

;; ==================== 3. 边界条件测试 ====================

(printf "\n=== 3. 边界条件测试 ===\n")

;; 有潜在问题的函数
(define (safe-divide a b)
  (if (zero? b)
      (error "除零错误")
      (/ a b)))

(define (test-boundary-conditions)
  (printf "测试边界条件...\n")
  
  ;; 正常情况
  (check-equal? (safe-divide 10 2) 5 "10/2=5")
  (check-equal? (safe-divide 0 5) 0 "0/5=0")
  (check-equal? (safe-divide -10 2) -5 "-10/2=-5")
  
  ;; 边界情况：除零
  (check-exn exn:fail? (λ () (safe-divide 10 0)) "除零应报错")
  
  ;; 边界情况：大数
  (check-equal? (safe-divide 1000000 2) 500000 "大数除法")
  
  (printf "✅ 边界条件测试通过\n"))

(test-boundary-conditions)

;; ==================== 4. 随机测试 ====================

(printf "\n=== 4. 随机测试 ===\n")

(define (random-test func num-tests)
  (printf "运行随机测试 (~a次)...\n" num-tests)
  
  (let ([failures 0])
    (for ([i (in-range num-tests)])
      (let ([a (random -100 100)]
            [b (random -100 100)])
        (when (not (zero? b))  ; 避免除零
          (let ([result (func a b)])
            (unless (rational? result)
              (set! failures (+ failures 1)))))))
    
    (printf "随机测试结果: ~a次测试，~a次失败\n" num-tests failures)
    (if (zero? failures)
        (printf "✅ 随机测试通过\n")
        (printf "⚠️  发现 ~a 个问题\n" failures))))

;; 测试除法函数
(random-test / 100)

;; ==================== 5. AI代码验证框架 ====================

(printf "\n=== 5. AI代码验证框架 ===\n")

;; 简单的验证框架
(struct test-spec
  (name           ; 测试名称
   test-cases     ; 测试用例
   properties)    ; 需要验证的性质
  #:transparent)

;; 创建max函数的测试规约
(define max-spec
  (test-spec
   'max-function
   '(((1 2) 2)     ; 测试用例: 输入 -> 期望输出
     ((5 3) 5)
     ((0 0) 0)
     ((-5 5) 5)
     ((-10 -20) -10))
   (list (λ (f)    ; 性质: 结果不小于任一参数
           (for ([a (in-range -10 10)]
                 [b (in-range -10 10)])
             (let ([result (f a b)])
               (check-true (>= result a) (format "max(~a,~a) >= ~a" a b a))
               (check-true (>= result b) (format "max(~a,~a) >= ~a" a b b)))))
         (λ (f)    ; 性质: 交换律
           (for ([a (in-range -5 5)]
                 [b (in-range -5 5)])
             (check-equal? (f a b) (f b a) 
                           (format "max(~a,~a) = max(~a,~a)" a b b a)))))))

;; 运行测试规约
(define (run-test-spec spec func)
  (match-let ([(test-spec name test-cases properties) spec])
    (printf "运行测试规约: ~a\n" name)
    
    ;; 运行测试用例
    (for ([test test-cases])
      (let ([args (first test)]
            [expected (second test)])
        (check-equal? (apply func args) expected
                      (format "~a~a = ~a" name args expected))))
    
    ;; 验证性质
    (for ([prop properties])
      (prop func))
    
    (printf "✅ 测试规约通过\n")))

;; 正确的max函数
(define (correct-max a b)
  (if (> a b) a b))

;; 运行测试
(run-test-spec max-spec correct-max)

;; ==================== 6. 错误注入测试 ====================

(printf "\n=== 6. 错误注入测试 ===\n")

(define (test-error-handling)
  (printf "测试错误处理...\n")
  
  ;; 测试1: 无效输入
  (check-equal? (string->number "不是数字") #f "无效字符串应返回#f")
  
  ;; 测试2: 索引越界
  (check-exn exn:fail:contract? 
             (λ () (list-ref '(1 2 3) 5))
             "列表索引越界")
  
  ;; 测试3: 文件不存在
  (check-exn exn:fail:filesystem? 
             (λ () (file->string "/不存在的文件.txt"))
             "文件不存在")
  
  (printf "✅ 错误处理测试通过\n"))

(test-error-handling)

;; ==================== 7. 性能测试 ====================

(printf "\n=== 7. 性能测试 ===\n")

(define (test-performance)
  (printf "测试算法性能...\n")
  
  (define (time-operation op)
    (define start (current-inexact-milliseconds))
    (op)
    (define end (current-inexact-milliseconds))
    (- end start))
  
  ;; 测试排序性能
  (define small-list (build-list 100 (λ (_) (random 1000))))
  (define large-list (build-list 10000 (λ (_) (random 1000))))
  
  (define small-time (time-operation (λ () (ai-sort small-list))))
  (define large-time (time-operation (λ () (ai-sort large-list))))
  
  (printf "小列表(~a元素)排序时间: ~a ms\n" 
          (length small-list) (exact-round small-time))
  (printf "大列表(~a元素)排序时间: ~a ms\n"
          (length large-list) (exact-round large-time))
  
  (when (> large-time (* 100 small-time))
    (printf "⚠️  注意: 大列表性能可能不是线性的\n"))
  
  (printf "✅ 性能测试完成\n"))

(test-performance)

;; ==================== 学习总结 ====================

(printf "\n=== 学习总结 ===\n")
(printf "1. 单元测试: 验证特定输入输出\n")
(printf "2. 边界测试: 测试极端情况\n")
(printf "3. 随机测试: 发现隐藏错误\n")
(printf "4. 性质测试: 验证代码性质\n")
(printf "5. 错误测试: 验证错误处理\n")
(printf "6. 性能测试: 验证性能特征\n")

(printf "\n=== 测试金字塔 ===\n")
(printf "🔺 单元测试: 快速、隔离、大量\n")
(printf "🔶 集成测试: 模块间交互\n")
(printf "🔷 系统测试: 完整系统验证\n")
(printf "🏔️  验收测试: 用户需求验证\n")

(printf "\n=== AI代码测试策略 ===\n")
(printf "1. 语法测试: 确保代码可解析\n")
(printf "2. 功能测试: 验证基本功能\n")
(printf "3. 边界测试: 测试极端输入\n")
(printf "4. 性质测试: 验证数学性质\n")
(printf "5. 错误测试: 验证错误处理\n")
(printf "6. 性能测试: 确保合理性能\n")

(printf "\n=== 测试最佳实践 ===\n")
(printf "• 测试驱动开发(TDD): 先写测试，再写代码\n")
(printf "• 持续集成(CI): 自动运行测试\n")
(printf "• 测试覆盖率: 确保代码被充分测试\n")
(printf "• 回归测试: 防止修复引入新错误\n")

(printf "\n=== 实际应用 ===\n")
(printf "• 验证AI生成的API实现\n")
(printf "• 测试机器学习数据预处理\n")
(printf "• 验证算法实现正确性\n")
(printf "• 确保代码重构不破坏功能\n")

(printf "\n🎉 Day 4 实战完成！\n")
(printf "你已掌握AI代码验证的核心测试技术！🚀\n")
(printf "现在你可以用系统化测试验证AI生成的代码了！\n")

;; ==================== 运行完整测试套件 ====================

(printf "\n=== 运行完整测试套件 ===\n")

(define all-tests
  (test-suite
   "AI代码验证完整测试套件"
   
   (test-case "基础算术测试"
     (check-equal? (+ 1 2) 3)
     (check-equal? (* 3 4) 12)
     (check-equal? (- 10 5) 5))
   
   (test-case "排序算法测试"
     (check-equal? (ai-sort '(3 1 2)) '(1 2 3))
     (check-equal? (ai-sort '()) '())
     (check-true (apply <= (ai-sort '(5 3 8 1 9)))))
   
   (test-case "max函数测试"
     (check-equal? (correct-max 1 2) 2)
     (check-equal? (correct-max 5 3) 5)
     (check-equal? (correct-max -5 5) 5))
   
   (test-case "错误处理测试"
     (check-exn exn:fail? (λ () (safe-divide 10 0))))))

(run-tests all-tests)

(printf "\n✅ 所有测试完成！代码验证通过！\n")