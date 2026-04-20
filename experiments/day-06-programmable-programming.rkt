#lang racket

;; ============================================
;; Day 6: Racket - Programmable Programming for AI Agents
;; 基于Volodymyr Pavlyshyn文章的完整实现
;; ============================================

(require syntax/parse
         racket/contract
         rosette
         racket/datalog)

(printf "🎯 Day 6: Racket - Programmable Programming for AI Agents\n")
(printf "============================================\n\n")

;; ==================== 1. 基础CNL实现 ====================

(printf "=== 1. 基础CNL（约束自然语言）实现 ===\n")

;; 1.1 简单CNL规则宏
(define-syntax (cnl-rule stx)
  (syntax-parse stx
    [(_ "when" condition:expr "then" action:expr)
     #'(λ (state)
         (when condition
           action))]
    [(_ "if" condition:expr "do" action:expr "else" alternative:expr)
     #'(λ (state)
         (if condition
             action
             alternative))]
    [(_ "for" duration:expr "seconds" "do" action:expr)
     #'(λ (state)
         (let ([start (current-seconds)])
           (let loop ()
             (when (< (- (current-seconds) start) duration)
               action
               (sleep 0.1)
               (loop)))))]))

;; 测试CNL规则
(printf "测试CNL规则...\n")

(define battery-rule
  (cnl-rule "when" (< (hash-ref (car state) 'battery) 20)
            "then" (hash-set! (car state) 'mode 'power-saving)))

(define test-state (list (make-hash '((battery . 15) (mode . normal)))))
(battery-rule test-state)
(printf "电池规则应用后状态: ~a\n" (car test-state))

;; 1.2 更复杂的CNL DSL
(define-syntax (ai-agent-dsl stx)
  (syntax-parse stx
    [(_ #:name name:id
        #:rules [("when" condition:expr "then" action:expr) ...]
        #:goals [goal:expr ...])
     #'(begin
         (define name
           (let ([state (make-hash)])
             (λ (event)
               (cond
                 [condition (action state event)] ...
                 [else #f]))))
         (define (name-achieve-goals)
           (for ([g (list goal ...)])
             (printf "尝试达成目标: ~a\n" g)))
         (provide name name-achieve-goals)))]))

;; ==================== 2. 自定义#lang机制实验 ====================

(printf "\n=== 2. 自定义#lang机制实验 ===\n")

;; 2.1 简单自然语言解析器
(define (parse-natural-language str)
  (match str
    [(regexp #rx"when (.+) then (.+)" (list _ condition action))
     `(rule ,condition ,action)]
    [(regexp #rx"if (.+) do (.+) else (.+)" (list _ condition action alternative))
     `(conditional ,condition ,action ,alternative)]
    [else `(unknown ,str)]))

(printf "解析自然语言规则...\n")
(printf "  'when battery low then save power': ~a\n" 
        (parse-natural-language "when battery low then save power"))
(printf "  'if obstacle detected do avoid else continue': ~a\n"
        (parse-natural-language "if obstacle detected do avoid else continue"))

;; 2.2 编译自然语言到Racket代码
(define (compile-cnl-to-racket parsed)
  (match parsed
    [`(rule ,condition ,action)
     `(lambda (state)
        (when ,(string->symbol condition)
          ,(string->symbol action)))]
    [`(conditional ,condition ,action ,alternative)
     `(lambda (state)
        (if ,(string->symbol condition)
            ,(string->symbol action)
            ,(string->symbol alternative)))]
    [else #f]))

;; ==================== 3. 渐进类型系统实战 ====================

(printf "\n=== 3. 渐进类型系统实战 ===\n")

;; 3.1 动态类型原型
(define (agent-decide-dynamic state)
  (cond
    [(< (hash-ref state 'energy 100) 20) 'save-energy]
    [(> (hash-ref state 'distance 0) 50) 'move]
    [(hash-ref state 'message #f) 'communicate]
    [else 'wait]))

(printf "动态类型Agent决策测试...\n")
(define test-state1 (make-hash '((energy . 15) (distance . 30))))
(printf "  状态: ~a → 决策: ~a\n" test-state1 (agent-decide-dynamic test-state1))

;; 3.2 添加契约保护
(define/contract (agent-decide-contract state)
  (-> (hash/c symbol? any/c) symbol?)
  (cond
    [(< (hash-ref state 'energy 100) 20) 'save-energy]
    [(> (hash-ref state 'distance 0) 50) 'move]
    [(hash-ref state 'message #f) 'communicate]
    [else 'wait]))

(printf "契约保护Agent决策测试...\n")
(printf "  状态: ~a → 决策: ~a\n" test-state1 (agent-decide-contract test-state1))

;; 3.3 模拟Typed Racket风格
(struct typed-agent-state ([energy #:mutable] [distance #:mutable] [message #:mutable])
  #:transparent)

(define (agent-decide-typed state)
  (cond
    [(< (typed-agent-state-energy state) 20) 'save-energy]
    [(> (typed-agent-state-distance state) 50) 'move]
    [(typed-agent-state-message state) 'communicate]
    [else 'wait]))

(printf "类型化Agent决策测试...\n")
(define typed-state (typed-agent-state 15 30 #f))
(printf "  状态: ~a → 决策: ~a\n" typed-state (agent-decide-typed typed-state))

;; ==================== 4. Rosette约束求解实战 ====================

(printf "\n=== 4. Rosette约束求解实战 ===\n")

;; 4.1 简单约束求解
(printf "简单约束求解示例...\n")

(define-symbolic x y z integer?)

(define simple-constraints
  (and (>= x 0) (<= x 100)
       (>= y 0) (<= y 100)
       (= (+ (* x 2) y) z)
       (< z 150)))

(define simple-solution (solve simple-constraints))

(if (sat? simple-solution)
    (let-values ([(sx sy sz) (apply values (evaluate (list x y z) simple-solution))])
      (printf "✅ 找到解: x=~a, y=~a, z=~a\n" sx sy sz))
    (printf "❌ 无解\n"))

;; 4.2 AI Agent路径规划
(printf "\nAI Agent路径规划...\n")

(define-symbolic* start-x start-y end-x end-y integer?)
(define-symbolic* obstacle-x obstacle-y integer?)

;; 约束：在网格内
(define grid-constraints
  (and (>= start-x 0) (<= start-x 100)
       (>= start-y 0) (<= start-y 100)
       (>= end-x 0) (<= end-x 100)
       (>= end-y 0) (<= end-y 100)
       (>= obstacle-x 0) (<= obstacle-x 100)
       (>= obstacle-y 0) (<= obstacle-y 100)))

;; 约束：避开障碍物
(define obstacle-constraints
  (>= (+ (abs (- start-x obstacle-x))
         (abs (- start-y obstacle-y)))
      10))

;; 约束：起点≠终点
(define distinct-constraints
  (not (and (= start-x end-x) (= start-y end-y))))

;; 求解
(define path-solution
  (solve (assert (and grid-constraints 
                      obstacle-constraints 
                      distinct-constraints
                      (= end-x 80) (= end-y 80)))))

(if (sat? path-solution)
    (let-values ([(sx sy ex ey ox oy) 
                  (apply values (evaluate (list start-x start-y end-x end-y obstacle-x obstacle-y) 
                                          path-solution))])
      (printf "✅ 路径规划成功！\n")
      (printf "  起点: (~a, ~a)\n" sx sy)
      (printf "  终点: (~a, ~a)\n" ex ey)
      (printf "  障碍物: (~a, ~a)\n" ox oy)
      (printf "  安全距离: ~a\n" 
              (+ (abs (- sx ox)) (abs (- sy oy)))))
    (printf "❌ 无法找到安全路径\n"))

;; 4.3 资源分配问题
(printf "\n资源分配问题求解...\n")

(define-symbolic* cpu memory storage cost integer?)

(define resource-constraints
  (and (>= cpu 1) (<= cpu 16)        ; 1-16核
       (>= memory 2) (<= memory 64)  ; 2-64GB
       (>= storage 50) (<= storage 1000) ; 50-1000GB
       (= cost (+ (* cpu 100) (* memory 10) storage)) ; 成本计算
       (<= cost 2000)))              ; 总成本限制

(define resource-solution
  (solve (assert (and resource-constraints
                      (>= cpu 4)     ; 至少4核
                      (>= memory 8)  ; 至少8GB内存
                      (>= storage 200))))) ; 至少200GB存储

(if (sat? resource-solution)
    (let-values ([(c m s co) (apply values (evaluate (list cpu memory storage cost) 
                                                     resource-solution))])
      (printf "✅ 资源分配方案找到！\n")
      (printf "  CPU: ~a核\n" c)
      (printf "  内存: ~aGB\n" m)
      (printf "  存储: ~aGB\n" s)
      (printf "  总成本: ~a元\n" co))
    (printf "❌ 无满足约束的资源分配方案\n"))

;; ==================== 5. Datalog逻辑推理实战 ====================

(printf "\n=== 5. Datalog逻辑推理实战 ===\n")

;; 5.1 简单Datalog知识库
(printf "构建AI Agent知识库...\n")

;; 模拟Datalog推理
(define knowledge-base (make-hash))

;; 添加事实
(hash-set! knowledge-base 'knows '(("robot1" "battery-low")
                                   ("robot1" "near-charger")
                                   ("robot2" "package-ready")
                                   ("robot2" "has-delivery-address")))

(hash-set! knowledge-base 'precondition '(("charge" "near-charger")
                                          ("deliver" "package-ready")
                                          ("deliver" "has-delivery-address")))

;; 推理函数
(define (can-do? agent action)
  (let ([known-facts (filter (λ (fact) (equal? (car fact) agent))
                             (hash-ref knowledge-base 'knows))]
        [preconditions (filter (λ (pre) (equal? (car pre) action))
                               (hash-ref knowledge-base 'precondition))])
    (for/and ([pre preconditions])
      (member (list agent (cadr pre)) known-facts))))

;; 查询
(printf "推理查询...\n")
(printf "  robot1能充电吗？ ~a\n" (can-do? "robot1" "charge"))
(printf "  robot2能送货吗？ ~a\n" (can-do? "robot2" "deliver"))
(printf "  robot1能送货吗？ ~a\n" (can-do? "robot1" "deliver"))

;; 5.2 目标达成推理
(define (achieve-goal? agent goal)
  (case goal
    [("charged") (can-do? agent "charge")]
    [("delivered") (can-do? agent "deliver")]
    [else #f]))

(printf "\n目标达成推理...\n")
(printf "  robot1能达成'charged'目标吗？ ~a\n" (achieve-goal? "robot1" "charged"))
(printf "  robot2能达成'delivered'目标吗？ ~a\n" (achieve-goal? "robot2" "delivered"))

;; ==================== 6. 综合应用：智能家居Agent ====================

(printf "\n=== 6. 综合应用：智能家居Agent ===\n")

;; 6.1 定义家居状态
(struct smart-home (temperature humidity lights energy-mode occupants)
  #:transparent #:mutable)

;; 6.2 CNL规则定义
(define-syntax (home-rule stx)
  (syntax-parse stx
    [(_ "when" time:expr "and" condition:expr "then" action:expr)
     #'(λ (home current-time)
         (when (and (equal? current-time time) condition)
           action home))]))

;; 6.3 定义规则
(define morning-rule
  (home-rule "when" "07:00" "and" (> (smart-home-occupants home) 0)
             "then" (λ (h) (set-smart-home-lights! h 'on))))

(define energy-rule  
  (home-rule "when" "23:00" "and" (= (smart-home-occupants home) 0)
             "then" (λ (h) (set-smart-home-energy-mode! h 'power-saving))))

(define temp-rule
  (home-rule "when" "any" "and" (> (smart-home-temperature home) 26)
             "then" (λ (h) (set-smart-home-temperature! h 24))))

;; 6.4 测试
(printf "测试智能家居Agent...\n")
(define my-home (smart-home 25 60 'off 'normal 2))

(printf "初始状态: ~a\n" my-home)
(morning-rule my-home "07:00")
(printf "早上7点后: ~a\n" my-home)

(set-smart-home-temperature! my-home 28)
(temp-rule my-home "14:00")
(printf "高温调节后: ~a\n" my-home)

(set-smart-home-occupants! my-home 0)
(energy-rule my-home "23:00")
(printf "夜间节能模式: ~a\n" my-home)

;; ==================== 7. 程序合成示例 ====================

(printf "\n=== 7. 程序合成示例 ===\n")

;; 7.1 简单程序合成：根据输入输出示例生成函数
(define (synthesize-from-examples examples)
  (printf "尝试从示例合成程序...\n")
  (printf "示例: ~a\n" examples)
  
  ;; 简单启发式：检查是否为线性关系
  (let* ([xs (map car examples)]
         [ys (map cadr examples)]
         [n (length examples)])
    
    (when (>= n 2)
      ;; 尝试线性函数 y = ax + b
      (let ([x1 (first xs)] [y1 (first ys)]
            [x2 (second xs)] [y2 (second ys)])
        (when (not (= x1 x2))
          (let ([a (/ (- y2 y1) (- x2 x1))]
                [b (- y1 (* a x1))])
            ;; 验证是否匹配所有示例
            (when (for/and ([x xs] [y ys])
                    (approx-equal? y (+ (* a x) b) 0.01))
              (printf "✅ 合成线性函数: y = ~ax + ~a\n" a b)
              (λ (x) (+ (* a x) b))))))))
  
  (printf "❌ 无法合成简单函数\n")
  #f)

;; 辅助函数：近似相等
(define (approx-equal? a b epsilon)
  (< (abs (- a b)) epsilon))

;; 测试程序合成
(define linear-examples '((1 2) (2 4) (3 6) (4 8)))
(define linear-fn (synthesize-from-examples linear-examples))

(when linear-fn
  (printf "测试合成函数: f(5) = ~a (期望: 10)\n" (linear-fn 5))
  (printf "测试合成函数: f(10) = ~a (期望: 20)\n" (linear-fn 10)))

;; ==================== 学习总结 ====================

(printf "\n=== 学习总结 ===\n")
(printf "1. CNL基础实现: 自然语言到代码的转换\n")
(printf "2. 自定义#lang: 创建领域专用语言\n")
(printf "3. 渐进类型: 从动态到静态的安全迁移\n")
(printf "4. Rosette约束求解: 路径规划、资源分配\n")
(printf "5. Datalog推理: 知识库和逻辑推理\n")
(printf "6. 综合应用: 智能家居Agent系统\n")
(printf "7. 程序合成: 从示例生成代码\n")

(printf "\n=== Racket的AI编程优势 ===\n")
(printf "• 同像性: 代码即数据，便于AI操作\n")
(printf "• 宏系统: 编译期代码转换\n")
(printf "• 渐进类型: 原型到生产的平滑过渡\n")
(printf "•