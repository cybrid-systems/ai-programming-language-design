#lang racket

;; ============================================
;; Day 2: AI约束意图DSL原型
;; 目标：使用Racket宏系统创建AI Agent专用DSL
;; ============================================

(require syntax/parse
         racket/contract)

(printf "🎯 Day 2: AI约束意图DSL原型\n")
(printf "============================================\n\n")

;; ==================== 基础宏：AI意图定义 ====================

(define-syntax (def-ai-intent stx)
  (syntax-parse stx
    [(_ name:id
        (~seq #:description desc:expr)
        (~seq #:constraints [c:expr ...])
        (~seq #:action action:expr))
     #'(begin
         ;; 1. 生成结构化Prompt（供LLM调用）
         (define name-prompt
           (format "Agent意图: ~a\n描述: ~a\n约束: ~a\n请输出符合约束的行动计划。"
                   'name desc (list c ...)))
         
         ;; 2. 编译期生成逻辑规则（知识库）
         (define name-rule
           (lambda (facts)
             (and c ... (hash-set! facts 'name #t))))
         
         ;; 3. 运行时契约保护
         (define/contract (name budget destination departure-time)
           (-> number? string? number? any/c)
           (let ([result action])
             (if (and c ...) 
                 result
                 (error 'name "违反约束: ~a" (list c ...))))))]))

(printf "=== 测试1：基础AI意图DSL ===\n")

;; 使用示例：航班预订Agent
(def-ai-intent book-flight
  #:description "为用户预订航班，必须满足预算和时间窗口"
  #:constraints [(<= budget 5000) 
                 (string? destination)
                 (> departure-time (current-seconds))]
  #:action (printf "✅ 正在调用LLM规划航班: 目的地~a 预算~a\n" destination budget))

;; 测试运行
(printf "\n测试航班预订（符合约束）:\n")
(book-flight 4500 "上海" (+ (current-seconds) 86400))

(printf "\n测试航班预订（违反预算约束）:\n")
(with-handlers ([exn:fail? (lambda (e) (printf "❌ 预期错误: ~a\n" (exn-message e)))])
  (book-flight 6000 "北京" (+ (current-seconds) 86400)))

;; ==================== 进阶宏：AI Agent状态机 ====================

(require syntax/parse)

(define-syntax (def-ai-agent stx)
  (syntax-parse stx
    [(_ agent-name:id
        #:initial-state init-state:expr
        #:states [state:id ...]
        #:transitions [(from-state:id -> to-state:id when:expr) ...]
        #:handlers [(on-state:id do:expr) ...])
     #'(begin
         (define agent-name
           (let ([current-state init-state]
                 [state-history (list init-state)])
             (lambda (event)
               (printf "🤖 Agent ~a 状态: ~a, 事件: ~a\n" 'agent-name current-state event)
               
               ;; 状态转移
               (for ([t (list (list 'from-state 'to-state when) ...)])
                 (match-let ([(list from to condition) t])
                   (when (and (eq? current-state from) condition)
                     (set! state-history (cons to state-history))
                     (set! current-state to)
                     (printf "  ↪ 状态转移: ~a → ~a\n" from to))))
               
               ;; 状态处理
               (case current-state
                 [(on-state) do] ...)
               
               ;; 返回当前状态和历史
               (list current-state (reverse state-history))))))]))

(printf "\n=== 测试2：AI Agent状态机DSL ===\n")

;; 对话Agent示例
(def-ai-agent dialog-agent
  #:initial-state 'greeting
  #:states [greeting listening processing responding farewell]
  #:transitions [(greeting -> listening (eq? event 'user-spoke))
                 (listening -> processing (eq? event 'message-received))
                 (processing -> responding (eq? event 'response-ready))
                 (responding -> listening (eq? event 'response-sent))
                 (responding -> farewell (eq? event 'conversation-ended))]
  #:handlers [(greeting (printf "   处理: 发送欢迎消息\n"))
              (listening (printf "   处理: 接收用户输入\n"))
              (processing (printf "   处理: 分析并生成回复\n"))
              (responding (printf "   处理: 发送回复给用户\n"))
              (farewell (printf "   处理: 结束对话\n"))])

;; 模拟对话流程
(printf "\n模拟对话流程:\n")
(dialog-agent 'user-spoke)
(dialog-agent 'message-received)
(dialog-agent 'response-ready)
(dialog-agent 'response-sent)
(dialog-agent 'conversation-ended)

;; ==================== 自定义语法类：自然语言约束 ====================

(require syntax/parse/define)

(define-syntax-class intent-constraint
  #:description "AI意图约束"
  (pattern (var:id op:expr value:expr)
           #:with compiled #`(op var value))
  (pattern (pred:expr var:id)
           #:with compiled #`(pred var))
  (pattern desc:str
           #:with compiled #`(printf "约束描述: ~a\n" desc)))

(define-syntax (ai-constraint stx)
  (syntax-parse stx
    [(_ name:id constraint:intent-constraint ...)
     #'(define name
         (lambda args
           (printf "🔍 检查约束: ~a\n" 'name)
           (and (constraint.compiled args) ...)))]))

(printf "\n=== 测试3：自定义语法类 ===\n")

;; 使用自定义语法类
(ai-constraint data-constraints
  "数据必须经过匿名化处理"
  (data anonymized?)
  (size <= 1000000))

;; 测试约束
(printf "\n测试数据约束:\n")
(define test-result (data-constraints #:data "user123" #:size 500000))
(printf "约束检查结果: ~a\n" test-result)

;; ==================== 完整的AI任务DSL ====================

(define-syntax (def-ai-task stx)
  (syntax-parse stx
    [(_ task-name:id
        #:goal goal:str
        #:input [input-spec ...]
        #:output output-spec:expr
        #:steps [step:expr ...])
     #'(begin
         (define task-name
           (lambda (input ...)
             (printf "🎯 开始AI任务: ~a\n" 'task-name)
             (printf "目标: ~a\n" goal)
             
             ;; 验证输入
             (for ([spec (list input-spec ...)]
                   [val (list input ...)])
               (printf "验证输入: ~a = ~a\n" spec val))
             
             ;; 执行步骤
             (let ([result (begin step ...)])
               (printf "生成输出: ~a\n" output-spec)
               result))))]))

(printf "\n=== 测试4：完整AI任务DSL ===\n")

;; 数据分析任务
(def-ai-task analyze-user-data
  #:goal "分析用户行为数据，生成个性化推荐"
  #:input [#:user-id "用户ID" 
           #:time-range "时间范围" 
           #:data-source "数据源"]
  #:output "推荐结果列表"
  #:steps [(printf "步骤1: 加载用户数据\n")
           (printf "步骤2: 分析行为模式\n")
           (printf "步骤3: 计算相似用户\n")
           (printf "步骤4: 生成推荐\n")
           '("推荐1" "推荐2" "推荐3")])

;; 执行AI任务
(printf "\n执行数据分析任务:\n")
(define recommendations (analyze-user-data "user123" "2026-04" "database"))
(printf "推荐结果: ~a\n" recommendations)

;; ==================== 宏展开可视化辅助 ====================

(printf "\n=== 宏展开辅助 ===\n")
(printf "使用DrRacket的macro-stepper工具可视化宏展开过程:\n")
(printf "1. 打开DrRacket\n")
(printf "2. 加载本文件\n")
(printf "3. 菜单: Racket → Macro Stepper\n")
(printf "4. 观察def-ai-intent宏如何展开\n")

;; ==================== 学习总结与反思 ====================

(printf "\n=== 学习总结 ===\n")
(printf "1. syntax-parse提供了强大的模式匹配能力\n")
(printf "2. 语法对象(syntax objects)携带词法作用域信息\n")
(printf "3. 卫生宏自动防止命名冲突\n")
(printf "4. 自定义语法类让DSL更自然\n")
(printf "5. 编译期生成 + 运行时验证 = AI代码安全\n")

(printf "\n=== 思考问题 ===\n")
(printf "1. 如何为不同的LLM后端（OpenAI/Claude）自动生成适配代码？\n")
(printf "2. 能否创建一个#lang专门用于AI意图描述？\n")
(printf "3. 如何将自然语言约束自动编译为Datalog规则？\n")
(printf "4. 宏系统如何帮助解决AI代码生成的"幻觉"问题？\n")

;; ==================== 明日学习计划 ====================

(printf "\n=== 明日计划（Day 3）===\n")
(printf "1. Typed Racket实战：为AI代码添加静态类型\n")
(printf "2. 高阶契约系统：实现运行时验证\n")
(printf "3. Rosette集成：形式验证AI生成代码\n")
(printf "4. 创建AI代码验证编译器\n")

(printf "\n🎉 Day 2 实验完成！\n")
(printf "你刚刚用Racket宏创建了一个完整的AI约束意图DSL！🚀\n")
(printf "保持探索，编程语言的可塑性就在你手中！\n")