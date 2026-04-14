#lang rosette

;; ============================================
;; Day 4: Rosette形式验证简单示例
;; 使用符号执行验证AI生成代码
;; ============================================

(require rosette/lib/angelic)

(printf "🎯 Day 4: Rosette形式验证简单示例\n")
(printf "============================================\n\n")

;; ==================== 1. 基础符号执行 ====================

(printf "=== 1. 基础符号执行 ===\n")

;; 定义符号整数变量
(define-symbolic x y integer?)

(printf "创建符号变量: x, y (整数)\n")

;; 验证加法交换律
(define (verify-addition-commutative)
  (printf "验证加法交换律: x + y = y + x\n")
  
  ;; 创建断言
  (assert (equal? (+ x y) (+ y x)))
  
  ;; 验证断言
  (define sol (verify (assert (equal? (+ x y) (+ y x)))))
  
  (if (unsat? sol)
      (printf "✅ 加法交换律成立（对所有整数）\n")
      (printf "❌ 找到反例: ~a\n" (evaluate (list x y) sol))))

(verify-addition-commutative)

;; ==================== 2. 验证AI生成的max函数 ====================

(printf "\n=== 2. 验证AI生成的max函数 ===\n")

;; AI可能生成的有错误的max函数
(define (ai-max a b)
  ;; 错误：总是返回第一个参数
  a)

;; 正确的max函数
(define (correct-max a b)
  (if (> a b) a b))

(define (verify-max-function)
  (printf "验证max函数性质...\n")
  
  (define-symbolic a b integer?)
  
  ;; 性质1: max(a,b) >= a 且 max(a,b) >= b
  (printf "性质1: max(a,b) >= a 且 max(a,b) >= b\n")
  (let ([sol1 (verify (assert (and (>= (ai-max a b) a)
                                   (>= (ai-max a b) b))))])
    (if (unsat? sol1)
        (printf "  ✅ AI-max满足性质1\n")
        (let ([counter (evaluate (list a b) sol1)])
          (printf "  ❌ 反例: a=~a, b=~a, ai-max=~a\n" 
                  (first counter) (second counter) (ai-max (first counter) (second counter))))))
  
  ;; 性质2: max(a,b) == a 或 max(a,b) == b
  (printf "性质2: max(a,b) == a 或 max(a,b) == b\n")
  (let ([sol2 (verify (assert (or (equal? (ai-max a b) a)
                                  (equal? (ai-max a b) b))))])
    (if (unsat? sol2)
        (printf "  ✅ AI-max满足性质2\n")
        (let ([counter (evaluate (list a b) sol2)])
          (printf "  ❌ 反例: a=~a, b=~a\n" (first counter) (second counter)))))
  
  ;; 验证正确max函数的性质
  (printf "\n验证正确max函数的性质...\n")
  (let ([sol3 (verify (assert (and (>= (correct-max a b) a)
                                   (>= (correct-max a b) b)
                                   (or (equal? (correct-max a b) a)
                                       (equal? (correct-max a b) b)))))])
    (if (unsat? sol3)
        (printf "✅ 正确max函数满足所有性质\n")
        (printf "❌ 意外反例\n"))))

(verify-max-function)

;; ==================== 3. 验证排序算法的不变式 ====================

(printf "\n=== 3. 验证排序算法的不变式 ===\n")

;; 简单的排序函数（选择排序）
(define (selection-sort lst)
  (if (null? lst)
      '()
      (let ([min-elem (apply min lst)])
        (cons min-elem (selection-sort (remove min-elem lst))))))

(define (verify-sort-invariants)
  (printf "验证排序算法不变式...\n")
  
  ;; 创建符号列表（限制大小为3以控制复杂度）
  (define-symbolic a b c integer?)
  (define lst (list a b c))
  
  ;; 不变式1: 输出是输入的排列（通过长度和元素和验证）
  (printf "不变式1: 输出包含相同元素\n")
  (let ([sorted (selection-sort lst)])
    (assert (equal? (length lst) (length sorted)))
    (assert (equal? (apply + lst) (apply + sorted))))
  
  ;; 不变式2: 输出是有序的
  (printf "不变式2: 输出是有序的\n")
  (let ([sorted (selection-sort lst)])
    (assert (or (null? sorted)
                (null? (rest sorted))
                (<= (first sorted) (second sorted)))))
  
  (define sol (verify (assert (and (equal? (length lst) (length (selection-sort lst)))
                                   (equal? (apply + lst) (apply + (selection-sort lst)))
                                   (let ([s (selection-sort lst)])
                                     (or (null? s)
                                         (null? (rest s))
                                         (<= (first s) (second s))))))))
  
  (if (unsat? sol)
      (printf "✅ 排序算法满足不变式\n")
      (printf "❌ 找到反例: ~a\n" (evaluate lst sol))))

(verify-sort-invariants)

;; ==================== 4. 边界条件验证 ====================

(printf "\n=== 4. 边界条件验证 ===\n")

;; 有潜在边界错误的函数
(define (safe-reciprocal n)
  ;; AI可能忘记检查除零
  (/ 1 n))

(define (verify-boundary-conditions)
  (printf "验证边界条件...\n")
  
  (define-symbolic n integer?)
  
  ;; 假设n不为0
  (assume (not (equal? n 0)))
  
  ;; 验证在n≠0时函数安全
  (let ([sol (verify (assert (rational? (safe-reciprocal n))))])
    (if (unsat? sol)
        (printf "✅ 当n≠0时，函数安全\n")
        (printf "❌ 找到问题: n=~a\n" (evaluate n sol))))
  
  ;; 显式测试n=0的情况
  (printf "测试n=0的边界情况...\n")
  (with-handlers ([exn:fail:contract:divide-by-zero?
                   (λ (e) (printf "✅ 正确抛出除零异常\n"))])
    (safe-reciprocal 0)
    (printf "❌ 未处理除零错误\n")))

(verify-boundary-conditions)

;; ==================== 学习总结 ====================

(printf "\n=== 学习总结 ===\n")
(printf "1. 符号执行: 使用符号变量进行推理\n")
(printf "2. 程序验证: 验证代码满足规约\n")
(printf "3. 不变式验证: 验证循环和递归不变式\n")
(printf "4. 边界分析: 发现边界条件错误\n")

(printf "\n=== Rosette核心特性 ===\n")
(printf "• define-symbolic: 创建符号变量\n")
(printf "• assert/assume: 断言和假设\n")
(printf "• verify: 验证断言是否成立\n")
(printf "• evaluate: 获取反例的具体值\n")

(printf "\n=== 形式验证层次 ===\n")
(printf "1. 测试: 验证特定输入输出\n")
(printf "2. 属性测试: 验证随机输入的性质\n")
(printf "3. 符号执行: 验证所有可能输入\n")
(printf "4. 定理证明: 数学证明正确性\n")

(printf "\n=== 实际应用 ===\n")
(printf "• 验证AI生成的算法实现\n")
(printf "• 验证编译器优化的正确性\n")
(printf "• 验证安全协议实现\n")
(printf "• 验证硬件设计\n")

(printf "\n🎉 Day 4 Rosette实战完成！\n")
(printf "你已掌握形式验证的核心技术！🚀\n")
(printf "现在你可以用数学方法验证AI生成代码的正确性了！\n")