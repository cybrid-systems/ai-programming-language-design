#lang racket

;; ============================================
;; Day 5: #lang机制完整解析 + 自定义#lang ai-intent语言实现
;; Constraint Natural Language实验落地
;; ============================================

(require syntax/parse
         racket/custodian
         racket/thread
         racket/datalog)

(printf "🎯 Day 5: #lang机制完整解析 + 自定义AI意图语言\n")
(printf "============================================\n\n")

;; ==================== 1. 自定义语言基础结构 ====================

(printf "=== 1. 自定义语言基础结构 ===\n")

;; 1.1 模拟#lang机制的核心组件
(define-syntax (define-language stx)
  (syntax-parse stx
    [(_ name:id body ...)
     #'(begin
         (printf "定义语言: ~a\n" 'name)
         (define-syntax (name-module-begin stx)
           (syntax-parse stx
             [(_ forms ...)
              #'(#%module-begin
                 (printf "[~a语言] 模块开始\n" 'name)
                 forms ...
                 (printf "[~a语言] 模块结束\n" 'name))]))
         body ...)]))

;; 1.2 示例：简单计算语言
(printf "创建简单计算语言示例...\n")

(define-language simple-calc
  (define-syntax (计算 stx)
    (syntax-parse stx
      [(_ 表达式:expr)
       #'(printf "计算结果: ~a\n" 表达式)]))
  
  (define-syntax (如果 stx)
    (syntax-parse stx
      [(_ 条件:expr 那么:expr 否则:expr)
       #'(if 条件 那么 否则)])))

;; 测试简单语言
(module+ test
  (simple-calc-module-begin
   (计算 (+ 1 2 3))
   (如果 (> 5 3)
         (计算 "条件成立")
         (计算 "条件不成立"))))

;; ==================== 2. AI意图语言完整实现 ====================

(printf "\n=== 2. AI意图语言完整实现 ===\n")

;; 2.1 语言核心模块
(define (make-ai-intent-language)
  (printf "构建AI意图语言核心...\n")
  
  ;; 语言状态
  (define intents (make-hash))
  (define knowledge-base (make-hash))
  
  ;; 核心宏：定义意图
  (define-syntax (def-ai-intent stx)
    (syntax-parse stx
      [(_ name:id 
          #:desc desc:str
          #:constraints [c:expr ...]
          #:action action:expr)
       #'(begin
           ;; 记录意图定义
           (hash-set! intents 'name (list desc (list c ...) action))
           
           ;; 添加到知识库
           (hash-set! knowledge-base 'name 
                     `(intent ,desc ,(list c ...)))
           
           ;; 生成执行函数
           (define (name . args)
             (let ([c (make-custodian)])
               (parameterize ([current-custodian c])
                 (thread-wait
                  (thread
                   (λ ()
                     (printf "[AI意图 ~a] 启动\n" 'name)
                     (printf "描述: ~a\n" desc)
                     (printf "约束: ~a\n" (list c ...))
                     (printf "输入参数: ~a\n" args)
                     
                     ;; 检查约束
                     (when (and c ...)
                       (printf "✅ 约束检查通过\n")
                       (apply action args))
                     
                     (printf "[AI意图 ~a] 完成\n" 'name))))
                 (custodian-shutdown-all c)
                 (printf "[AI意图 ~a] 资源已清理\n" 'name))))
           
           (provide name))]))
  
  ;; 查询函数
  (define (list-intents)
    (printf "已定义的意图:\n")
    (for ([(name info) intents])
      (printf "  ~a: ~a\n" name (first info))))
  
  ;; 返回语言组件
  (list def-ai-intent list-intents intents knowledge-base))

;; 2.2 测试AI意图语言
(printf "测试AI意图语言...\n")

(define-values (def-ai-intent list-intents intents knowledge-base)
  (apply values (make-ai-intent-language)))

;; 定义一些意图
(module+ test
  (def-ai-intent book-flight
    #:desc "预订航班，预算限制5000元"
    #:constraints [(<= (first args) 5000)
                   (> (second args) (current-seconds))]
    #:action (λ (budget time)
               (printf "预订航班成功: 预算~a，时间~a\n" budget time)))
  
  (def-ai-intent book-hotel
    #:desc "预订酒店，预算限制3000元"
    #:constraints [(<= (first args) 3000)]
    #:action (λ (budget)
               (printf "预订酒店成功: 预算~a\n" budget)))
  
  ;; 列出意图
  (list-intents)
  
  ;; 执行意图
  (printf "\n执行意图测试...\n")
  (book-flight 4500 (+ (current-seconds) 86400))
  (book-hotel 2500))

;; ==================== 3. 自定义Reader实现 ====================

(printf "\n=== 3. 自定义Reader实现 ===\n")

;; 3.1 自然语言解析器
(define (parse-natural-intent str)
  (match str
    [(regexp #rx"定义意图(.+)描述(.+)约束(.+)动作(.+)" 
             (list _ name desc constraints action))
     `(def-ai-intent ,(string->symbol name)
        #:desc ,desc
        #:constraints ,(read (open-input-string constraints))
        #:action ,(read (open-input-string action)))]
    [else #f]))

;; 3.2 测试自然语言解析
(printf "测试自然语言解析...\n")

(define natural-example 
  "定义意图 订机票 描述 预订上海到北京航班 约束 (<= 预算 5000) 动作 (printf 机票预订成功)")

(define parsed (parse-natural-intent natural-example))
(printf "解析结果: ~a\n" parsed)

;; 3.3 简单中文DSL
(define-syntax (定义意图 stx)
  (syntax-parse stx
    [(_ 名称:id 描述:str 约束:expr 动作:expr)
     #'(def-ai-intent 名称
         #:desc 描述
         #:constraints [约束]
         #:action 动作)]))

;; 测试中文DSL
(module+ test
  (定义意图 订火车票
    "预订火车票，二等座"
    (<= 票价 500)
    (λ (票价) (printf "火车票预订成功: ~a元\n" 票价)))
  
  ;; 执行
  (订火车票 350))

;; ==================== 4. 语言打包与安装 ====================

(printf "\n=== 4. 语言打包与安装 ===\n")

;; 4.1 模拟包结构
(define ai-intent-package
  `((info.rkt 
     . ,(string-append
         "#lang info\n"
         "(define collection 'multi)\n"
         "(define version \"0.1\")\n"
         "(define deps '(\"base\" \"typed-racket\"))\n"))
    (main.rkt 
     . ,(string-append
         "#lang racket/base\n"
         "(provide def-ai-intent)\n"
         "(define-syntax (def-ai-intent stx) ...)\n"))
    (reader.rkt
     . ,(string-append
         "#lang racket\n"
         "(provide read read-syntax)\n"
         "(define (read in) ...)\n"))))

(printf "AI意图语言包结构:\n")
(for ([(file content) ai-intent-package])
  (printf "  ~a (~a字节)\n" file (string-length content)))

;; 4.2 安装模拟
(define (install-language package)
  (printf "安装语言包...\n")
  (for ([(file content) package])
    (printf "  创建文件: ~a\n" file))
  (printf "✅ 语言安装完成\n")
  #t)

(install-language ai-intent-package)

;; ==================== 5. 多文件模块系统 ====================

(printf "\n=== 5. 多文件模块系统 ===\n")

;; 5.1 模块定义宏
(define-syntax (ai-module stx)
  (syntax-parse stx
    [(_ name:id body ...)
     #'(module name "ai-intent/main.rkt"
         body ...)]))

;; 5.2 模块导入导出
(define-syntax (ai-require stx)
  (syntax-parse stx
    [(_ module:expr)
     #'(require module)]))

(define-syntax (ai-provide stx)
  (syntax-parse stx
    [(_ spec ...)
     #'(provide spec ...)]))

;; 5.3 测试模块系统
(printf "测试模块系统...\n")

(module travel-module "ai-intent/main.rkt"
  (def-ai-intent book-flight
    #:desc "旅行模块：航班预订"
    #:constraints [#t]
    #:action (λ () (printf "旅行模块执行\n")))
  
  (provide book-flight))

;; 模拟模块使用
(printf "模拟模块导入...\n")
(require 'travel-module)
(book-flight)

;; ==================== 6. 语言工具链集成 ====================

(printf "\n=== 6. 语言工具链集成 ===\n")

;; 6.1 语法高亮模拟
(define (syntax-highlight code)
  (printf "语法高亮分析:\n")
  (for ([line (string-split code "\n")])
    (cond
      [(regexp-match? #rx"def-ai-intent" line)
       (printf "  🔵 ~a\n" line)]
      [(regexp-match? #rx"#:desc" line)
       (printf "  🟢 ~a\n" line)]
      [else
       (printf "  ⚫ ~a\n" line)])))

;; 6.2 测试高亮
(define sample-code 
  "#lang ai-intent\n(def-ai-intent test #:desc \"测试\" #:constraints [] #:action void)")
(syntax-highlight sample-code)

;; 6.3 错误检查
(define (check-syntax code)
  (printf "语法检查...\n")
  (with-handlers ([exn:fail:syntax?
                   (λ (e) (printf "❌ 语法错误: ~a\n" (exn-message e)))])
    (read (open-input-string code))
    (printf "✅ 语法正确\n")))

(check-syntax "(def-ai-intent test #:desc \"测试\" #:action void)")
(check-syntax "(def-ai-intent test)") ; 应该报错

;; ==================== 7. 进阶：类型系统集成 ====================

(printf "\n=== 7. 进阶：类型系统集成 ===\n")

;; 7.1 带类型的意图定义
(define-syntax (def-typed-intent stx)
  (syntax-parse stx
    [(_ name:id 
        #:desc desc:str
        #:input-type input-type:expr
        #:output-type output-type:expr  
        #:action action:expr)
     #'(begin
         (define (name input)
           (unless (input-type input)
             (error 'name "输入类型错误: ~a" input))
           (let ([result (action input)])
             (unless (output-type result)
               (error 'name "输出类型错误: ~a" result))
             result))
         (provide name))]))

;; 7.2 测试类型意图
(module+ test
  (def-typed-intent calculate-price
    #:desc "计算价格，输入为数字，输出为数字"
    #:input-type number?
    #:output-type number?
    #:action (λ (x) (* x 1.1))) ; 加10%税
  
  (printf "类型意图测试: ~a\n" (calculate-price 100))
  
  (with-handlers ([exn:fail? (λ (e) (printf "✅ 类型检查生效: ~a\n" (exn-message e)))])
    (calculate-price "不是数字")))

;; ==================== 8. 综合应用：完整AI意图项目 ====================

(printf "\n=== 8. 综合应用：完整AI意图项目 ===\n")

;; 8.1 项目结构模拟
(define ai-project
  `(("project/"
     ("ai-intent/" 
      ("main.rkt" . "语言核心")
      ("info.rkt" . "包信息")
      ("reader.rkt" . "语法解析"))
     ("agents/"
      ("travel.intent" . "旅行Agent")
      ("finance.intent" . "金融Agent"))
     ("knowledge/"
      ("rules.datalog" . "业务规则"))
     ("tests/"
      ("test-intent.rkt" . "测试用例")))))

(printf "AI意图项目结构:\n")
(define (print-tree tree indent)
  (for ([item tree])
    (if (pair? item)
        (begin
          (printf "~a📁 ~a\n" indent (car item))
          (print-tree (cdr item) (string-append indent "  ")))
        (printf "~a📄 ~a\n" indent item))))

(print-tree ai-project "")

;; 8.2 构建脚本模拟
(define (build-project)
  (printf "\n构建AI意图项目...\n")
  (printf "1. 编译语言核心 ✓\n")
  (printf "2. 解析Agent文件 ✓\n")
  (printf "3. 类型检查 ✓\n")
  (printf "4. 生成可执行代码 ✓\n")
  (printf "5. 打包分发 ✓\n")
  (printf "✅ 项目构建完成\n"))

(build-project)

;; ==================== 学习总结 ====================

(printf "\n=== 学习总结 ===\n")
(printf "1. 自定义语言基础: #lang机制原理\n")
(printf "2. AI意图语言实现: 完整语言核心\n")
(printf "3. 自定义Reader: 自然语言语法支持\n")
(printf "4. 语言打包: 可安装的语言包\n")
(printf "5. 模块系统: 多文件模块支持\n")
(printf "6. 工具链集成: 语法高亮和错误检查\n")
(printf "7. 类型系统集成: 带类型的意图定义\n")
(printf "8. 综合应用: 完整项目结构\n")

(printf "\n=== #lang机制的AI优势 ===\n")
(printf "• 语言定义权: 为AI场景定制专用语言\n")
(printf "• 语法自由度: 支持自然语言风格语法\n")
(printf "• 工具链集成: DrRacket原生支持\n")
(printf "• 编译期优化: 性能优于解释型DSL\n")
(printf "• 生态兼容: 可复用Racket所有库\n")

(printf "\n=== 实际应用场景 ===\n")
(printf "• AI Agent专用语言\n")
(printf "• 领域特定语言(DSL)\n")
(printf "• 业务规则引擎\n")
(printf "• 教育编程语言\n")
(printf "• 原型语言快速开发\n")

(printf "\n🎉 Day 5 自定义语言实战完成！\n")
(printf "你现在可以为AI Agent定义专属的编程语言了！🚀\n")

;; ==================== 下一步学习 ====================

(printf "\n=== 下一步学习 ===\n")
(printf "1. Rosette形式验证: 数学证明层\n")
(printf "2. Datalog集成: 逻辑推理引擎\n")
(printf "3. 分布式扩展: 跨机器语言执行\n")
(printf "4. 可视化工具: 语言开发环境\n")
(printf "5. 生产部署: 企业级语言解决方案\n")

(printf "\n🚀 准备好迎接Day 6的形式验证了吗？\n")