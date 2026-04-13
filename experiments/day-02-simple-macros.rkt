#lang racket

;; ============================================
;; Day 2: 简化版AI DSL原型（使用基础宏）
;; 目标：演示Racket宏系统核心概念
;; ============================================

(require racket/contract)

(printf "🎯 Day 2: Racket宏系统与AI DSL原型\n")
(printf "============================================\n\n")

;; ==================== 基础宏示例 ====================

;; 1. 简单的define-syntax-rule宏
(define-syntax-rule (如果 条件 那么 否则)
  (if 条件 那么 否则))

(printf "=== 测试1：基础条件宏 ===\n")
(如果 (> 5 3)
      (printf "  ✅ 5大于3\n")
      (printf "  ❌ 5不大于3\n"))

;; 2. 带参数的宏
(define-syntax-rule (循环 次数 主体)
  (for ([i (in-range 次数)])
    (主体 i)))

(printf "\n=== 测试2：循环宏 ===\n")
(循环 3 (lambda (i) (printf "  第~a次循环\n" (+ i 1))))

;; ==================== AI意图宏（简化版） ====================

;; 使用更简单的宏定义方式
(define-syntax (定义-AI-意图 stx)
  (syntax-case stx ()
    [(_ 名称 描述 约束 动作)
     #'(begin
         (printf "定义AI意图: ~a\n" '名称)
         (printf "描述: ~a\n" 描述)
         
         (define (名称 参数 ...)
           (printf "执行意图: ~a\n" '名称)
           (if 约束
               (begin
                 (printf "✅ 约束满足\n")
                 动作)
               (error '名称 "约束不满足"))))]))

(printf "\n=== 测试3：AI意图宏 ===\n")

(定义-AI-意图 预订航班
  "为用户预订航班"
  (<= 预算 5000)
  (printf "  正在预订航班，预算: ~a\n" 预算))

;; 测试
(预订航班 4500)

;; ==================== 带模式匹配的宏 ====================

(define-syntax (AI-任务 stx)
  (syntax-case stx ()
    [(_ 任务名称 (输入 ...) 输出 步骤 ...)
     #'(begin
         (define (任务名称 输入 ...)
           (printf "开始AI任务: ~a\n" '任务名称)
           步骤 ...
           输出))]))

(printf "\n=== 测试4：AI任务宏 ===\n")

(AI-任务 分析数据
         (用户ID 数据源)
         (printf "分析完成\n")
         (printf "加载用户数据: ~a\n" 用户ID)
         (printf "从数据源读取: ~a\n" 数据源)
         (printf "执行分析算法\n"))

;; 执行任务
(分析数据 "user123" "database")

;; ==================== 卫生宏示例 ====================

(define-syntax (卫生测试 stx)
  (syntax-case stx ()
    [(_ 表达式)
     (with-syntax ([临时变量 (datum->syntax stx 'temp)])
       #'(let ([临时变量 10])
           (+ 临时变量 表达式)))]))

(printf "\n=== 测试5：卫生宏 ===\n")

;; 即使外部有同名变量，也不会冲突
(define temp 100)
(printf "外部temp: ~a\n" temp)
(printf "宏内计算: ~a\n" (卫生测试 5))
(printf "外部temp不变: ~a\n" temp)

;; ==================== 编译期计算宏 ====================

(define-syntax (编译期检查 stx)
  (syntax-case stx ()
    [(_ 条件 消息)
     (if (eval (syntax->datum #'条件))
         #'(void)
         (raise-syntax-error #f 消息 stx))]))

(printf "\n=== 测试6：编译期检查 ===\n")

;; 这个会在编译时检查
(编译期检查 (> 5 3) "条件必须为真")

;; 如果取消下面这行的注释，编译会失败
;; (编译期检查 (< 5 3) "这个条件为假，编译失败")

;; ==================== AI Agent状态机（简化） ====================

(define-syntax (定义-Agent stx)
  (syntax-case stx ()
    [(_ 名称 初始状态 [状态 ...] [(从 到 当) ...] [(在状态 执行) ...])
     #'(begin
         (define 名称
           (let ([当前状态 初始状态])
             (lambda (事件)
               (printf "Agent ~a: 状态=~a, 事件=~a\n" '名称 当前状态 事件)
               
               ;; 状态转移
               (for ([转移 (list (list '从 '到 当) ...)])
                 (match-let ([(list 从状态 到状态 条件) 转移])
                   (when (and (eq? 当前状态 从状态) 条件)
                     (set! 当前状态 到状态)
                     (printf "  状态转移: ~a → ~a\n" 从状态 到状态))))
               
               当前状态))))]))

(printf "\n=== 测试7：AI Agent状态机 ===\n")

(定义-Agent 对话Agent
            '问候
            [问候 聆听 处理 回复 结束]
            [(问候 聆听 (eq? 事件 '用户说话))
             (聆听 处理 (eq? 事件 '收到消息))
             (处理 回复 (eq? 事件 '回复就绪))
             (回复 聆听 (eq? 事件 '已发送))
             (回复 结束 (eq? 事件 '对话结束))]
            [(在状态 问候 (printf "  发送欢迎消息\n"))
             (在状态 聆听 (printf "  接收用户输入\n"))
             (在状态 处理 (printf "  分析并生成回复\n"))
             (在状态 回复 (printf "  发送回复\n"))
             (在状态 结束 (printf "  结束对话\n"))])

;; 模拟对话
(对话Agent '用户说话)
(对话Agent '收到消息)
(对话Agent '回复就绪)
(对话Agent '已发送)
(对话Agent '对话结束)

;; ==================== 学习总结 ====================

(printf "\n=== 学习总结 ===\n")
(printf "1. define-syntax-rule: 最简单的宏形式\n")
(printf "2. define-syntax + syntax-case: 更灵活的模式匹配\n")
(printf "3. 卫生宏: 自动避免变量名冲突\n")
(printf "4. 编译期计算: 在宏展开时执行代码\n")
(printf "5. 语法对象: 携带词法作用域信息\n")

(printf "\n=== 核心概念 ===\n")
(printf "• 宏在编译期展开，不是运行时\n")
(printf "• syntax对象包含源位置和词法信息\n")
(printf "• 卫生性防止意外变量捕获\n")
(printf "• 模式匹配让宏更强大\n")

(printf "\n=== AI DSL设计模式 ===\n")
(printf "1. 意图描述 → 宏展开 → 可执行代码\n")
(printf "2. 自然语言风格的关键字\n")
(printf "3. 编译期约束检查\n")
(printf "4. 运行时契约保护\n")

(printf "\n=== 明日预告 ===\n")
(printf "Day 3: Typed Racket + 高阶契约\n")
(printf "• 为AI生成代码添加静态类型\n")
(printf "• 运行时契约验证\n")
(printf "• 形式验证集成\n")

(printf "\n🎉 Day 2 实验完成！\n")
(printf "你已掌握Racket宏系统的核心概念！🚀\n")
(printf "继续探索，用宏创造你自己的编程语言！\n")