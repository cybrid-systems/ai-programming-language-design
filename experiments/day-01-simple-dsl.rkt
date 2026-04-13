#lang racket

;; ============================================
;; Day 1: 简单的AI友好DSL实验
;; 目标：创建中文语法的简单DSL，探索Racket宏系统
;; ============================================

;; 1. 基础宏：中文条件语句
(define-syntax-rule (如果 条件 那么 否则)
  (if 条件 那么 否则))

;; 测试中文条件
(printf "=== 测试1：中文条件语句 ===\n")
(如果 (> 5 3)
      (printf "✓ 5大于3\n")
      (printf "✗ 5不大于3\n"))

(如果 (string=? "hello" "world")
      (printf "✓ 字符串相等\n")
      (printf "✗ 字符串不相等\n"))

;; 2. 循环宏：中文循环
(define-syntax-rule (循环 次数 操作)
  (for ([i (in-range 次数)])
    操作))

(printf "\n=== 测试2：中文循环 ===\n")
(循环 3 (printf "  循环第~a次\n" (+ i 1)))

;; 3. AI指令语言：简单的自然语言风格DSL
(define-syntax-rule (AI-指令 动作 目标 参数 ...)
  `(执行 ,动作 于 ,目标 ,@(if (null? '(参数 ...)) '() `(参数: ,@'(参数 ...)))))

(printf "\n=== 测试3：AI指令语言 ===\n")
(define 指令1 (AI-指令 "分析" "用户行为数据"))
(printf "指令1: ~a\n" 指令1)

(define 指令2 (AI-指令 "生成" "代码摘要" "使用Python" "包含注释"))
(printf "指令2: ~a\n" 指令2)

;; 4. 数据转换DSL：类似SQL的查询语言
(define-syntax-rule (选择 字段 从 数据源 条件 ...)
  (filter (lambda (记录) 条件 ...) 数据源))

;; 测试数据
(define 用户数据
  '((姓名 "张三" 年龄 25 城市 "北京")
    (姓名 "李四" 年龄 30 城市 "上海")
    (姓名 "王五" 年龄 22 城市 "北京")))

(printf "\n=== 测试4：数据查询DSL ===\n")
(define 北京用户
  (选择 记录 从 用户数据
        (equal? (assoc '城市 记录) '(城市 "北京"))))

(printf "北京用户: ~a\n" 北京用户)

;; 5. 渐进类型：使用contracts确保AI生成代码的安全
(require racket/contract)

(define/contract (安全除法 被除数 除数)
  (-> number? (and/c number? (not/c zero?)) number?)
  (/ 被除数 除数))

(printf "\n=== 测试5：安全合约 ===\n")
(printf "10 / 2 = ~a\n" (安全除法 10 2))

;; 这会触发合约错误（除数不能为0）
;; (安全除法 10 0)

;; 6. 简单的AI响应生成器
(define-syntax-rule (AI-响应 类型 内容)
  (match 类型
    ['信息 (format "ℹ️  ~a" 内容)]
    ['成功 (format "✅  ~a" 内容)]
    ['警告 (format "⚠️  ~a" 内容)]
    ['错误 (format "❌  ~a" 内容)]
    [_ (format "📝  ~a" 内容)]))

(printf "\n=== 测试6：AI响应格式 ===\n")
(printf "~a\n" (AI-响应 '成功 "任务完成"))
(printf "~a\n" (AI-响应 '警告 "内存使用过高"))
(printf "~a\n" (AI-响应 '信息 "正在处理数据"))

;; 7. 实验：为AI Agent设计约束自然语言
(define-syntax-rule (约束 变量 条件)
  (let ([值 变量])
    (unless 条件
      (error (format "约束违反: ~a 不满足 ~a" '变量 '条件)))
    值))

(printf "\n=== 测试7：约束检查 ===\n")
(define 年龄 (约束 25 (>= 25 18)))
(printf "年龄 ~a 满足成年条件\n" 年龄)

;; 这会触发错误
;; (define 无效年龄 (约束 15 (>= 15 18)))

;; ============================================
;; 总结与反思
;; ============================================

(printf "\n=== 学习总结 ===\n")
(printf "1. Racket宏系统让创建DSL变得异常简单\n")
(printf "2. 语法对象(syntax objects)提供卫生宏，避免命名冲突\n")
(printf "3. Contracts机制可以为AI生成代码添加运行时安全\n")
(printf "4. 渐进式类型化：从动态脚本到静态类型的平滑过渡\n")
(printf "5. 语言导向编程(LOP)是AI时代的强大工具\n")

(printf "\n=== 思考问题 ===\n")
(printf "1. 如何为AI Agent设计更自然的约束语言？\n")
(printf "2. Typed Racket如何帮助验证AI生成的代码？\n")
(printf "3. 能否创建一个#lang专门用于AI意图描述？\n")

;; ============================================
;; 明日学习计划
;; ============================================

(printf "\n=== 明日计划（Day 2）===\n")
(printf "1. 深入学习syntax objects和卫生宏\n")
(printf "2. 创建更复杂的AI DSL原型\n")
(printf "3. 探索Typed Racket的类型系统\n")
(printf "4. 实验AI代码生成与验证工作流\n")

;; 运行所有测试
(printf "\n🎉 Day 1 实验完成！\n")
(printf "保持好奇，继续探索Racket的无限可能！🚀\n")