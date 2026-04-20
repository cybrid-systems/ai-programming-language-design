#lang racket

;; ============================================
;; Day 4: Custodian + 绿色线程实战
;; AI Agent"永不崩溃"资源沙箱 + 多模态意图DSL
;; ============================================

(require racket/custodian
         racket/thread
         racket/place
         racket/contract)

(printf "🎯 Day 4: Custodian + 绿色线程实战\n")
(printf "============================================\n\n")

;; ==================== 1. Custodian基础 ====================

(printf "=== 1. Custodian基础：资源监管器 ===\n")

;; 1.1 简单Custodian示例
(printf "创建简单Custodian...\n")

(define simple-custodian (make-custodian))
(printf "Custodian创建成功: ~a\n" simple-custodian)

;; 在Custodian中创建线程
(parameterize ([current-custodian simple-custodian])
  (define t (thread (λ () 
                     (printf "在Custodian监管下的线程中执行\n")
                     (sleep 1)
                     (printf "线程执行完成\n"))))
  (thread-wait t)
  (printf "线程执行完毕，准备关闭Custodian\n")
  (custodian-shutdown-all simple-custodian)
  (printf "Custodian已关闭，所有资源已清理\n"))

;; 1.2 嵌套Custodian
(printf "\n测试嵌套Custodian...\n")

(define parent-c (make-custodian))
(define child-c (make-custodian parent-c))

(printf "父Custodian: ~a\n" parent-c)
(printf "子Custodian: ~a\n" child-c)

;; 在子Custodian中执行
(parameterize ([current-custodian child-c])
  (thread (λ () (printf "在子Custodian中执行任务\n"))))

;; 只关闭子Custodian
(custodian-shutdown-all child-c)
(printf "子Custodian已关闭，父Custodian仍在运行: ~a\n" parent-c)

;; 关闭父Custodian
(custodian-shutdown-all parent-c)
(printf "父Custodian已关闭\n")

;; ==================== 2. 绿色线程并行 ====================

(printf "\n=== 2. 绿色线程并行 ===\n")

;; 2.1 创建多个并行线程
(printf "创建5个并行线程...\n")

(define threads
  (for/list ([i (in-range 5)])
    (thread 
     (λ ()
       (printf "线程~a 启动\n" i)
       (sleep (/ (random 1000) 1000.0)) ; 随机睡眠
       (printf "线程~a 完成\n" i)))))

;; 等待所有线程完成
(for ([t threads])
  (thread-wait t))

(printf "所有线程执行完成\n")

;; 2.2 线程间通信
(printf "\n线程间通信测试...\n")

(define channel (make-channel))

(define producer
  (thread
   (λ ()
     (for ([i (in-range 3)])
       (printf "生产者发送: 消息~a\n" i)
       (channel-put channel (format "消息~a" i))
       (sleep 0.5)))))

(define consumer
  (thread
   (λ ()
     (for ([i (in-range 3)])
       (define msg (channel-get channel))
       (printf "消费者收到: ~a\n" msg)))))

(thread-wait producer)
(thread-wait consumer)

;; ==================== 3. 多模态AI Agent沙箱 ====================

(printf "\n=== 3. 多模态AI Agent沙箱 ===\n")

;; 3.1 多模态意图沙箱宏
(define-syntax (def-multi-modal-agent stx)
  (syntax-case stx ()
    [(_ name text-desc image-desc action)
     #'(define (name)
         (let ([c (make-custodian)]) ; 每个Agent独立监管器
           (parameterize ([current-custodian c])
             (let ([t (thread
                       (λ ()
                         (printf "[~a] 多模态意图执行中...\n" 'name)
                         (printf "文本描述: ~a\n" text-desc)
                         (printf "视觉描述: ~a\n" image-desc)
                         (action) ; LLM调用或视觉处理
                         (printf "[~a] 执行完成\n" 'name)))])
               (thread-wait t)
               (custodian-shutdown-all c) ; 自动清理所有资源
               (printf "[~a] 沙箱已安全关闭\n" 'name)))))]))

;; 3.2 创建多模态Agent
(printf "创建多模态AI Agent...\n")

(def-multi-modal-agent travel-planner
  "规划从上海到北京的旅行，预算5000元"
  "图像：机场、酒店、景点照片"
  (λ ()
    (printf "调用多模态API分析图像和文本...\n")
    (sleep 0.8) ; 模拟API调用
    (printf "生成旅行计划：航班 + 酒店 + 景点\n")))

(def-multi-modal-agent medical-analyzer
  "分析医学影像，检测异常"
  "图像：X光片显示肺部区域"
  (λ ()
    (printf "启动视觉模型分析医学影像...\n")
    (sleep 1.2) ; 模拟深度学习推理
    (printf "检测结果：无明显异常\n")))

;; 3.3 并行执行Agent
(printf "\n并行执行多模态Agent...\n")

(define agent-thread1 (thread travel-planner))
(define agent-thread2 (thread medical-analyzer))

(thread-wait agent-thread1)
(thread-wait agent-thread2)

(printf "所有Agent执行完成\n")

;; ==================== 4. 崩溃隔离测试 ====================

(printf "\n=== 4. 崩溃隔离测试 ===\n")

;; 4.1 创建会崩溃的Agent
(def-multi-modal-agent crashy-agent
  "故意崩溃的测试Agent"
  "图像：测试图像"
  (λ ()
    (printf "[crashy-agent] 开始执行...\n")
    (sleep 0.3)
    (error "模拟Agent崩溃！")
    (printf "[crashy-agent] 这行不会执行\n")))

;; 4.2 创建正常Agent
(def-multi-modal-agent normal-agent
  "正常工作的Agent"
  "图像：正常图像"
  (λ ()
    (printf "[normal-agent] 正常执行中...\n")
    (sleep 0.5)
    (printf "[normal-agent] 执行完成\n")))

;; 4.3 测试崩溃隔离
(printf "测试崩溃隔离效果...\n")

;; 先启动正常Agent
(define normal-thread (thread normal-agent))

;; 尝试启动会崩溃的Agent（会被隔离）
(with-handlers ([exn:fail? 
                 (λ (e) 
                   (printf "捕获到崩溃: ~a\n" (exn-message e))
                   (printf "✅ 崩溃已被隔离，不影响其他Agent\n"))])
  (crashy-agent))

;; 等待正常Agent完成
(thread-wait normal-thread)
(printf "✅ 正常Agent成功完成执行\n")

;; ==================== 5. 资源限制与监控 ====================

(printf "\n=== 5. 资源限制与监控 ===\n")

;; 5.1 内存限制Custodian
(printf "创建带内存限制的Custodian...\n")

(define limited-custodian (make-custodian))
(custodian-limit-memory limited-custodian (* 10 1024 1024)) ; 10MB限制

(parameterize ([current-custodian limited-custodian])
  (with-handlers ([exn:fail:out-of-memory?
                   (λ (e) (printf "✅ 内存限制生效: ~a\n" (exn-message e)))])
    (thread
     (λ ()
       (printf "尝试分配大量内存...\n")
       ;; 模拟内存消耗
       (define big-list (make-list 1000000 'data))
       (printf "内存分配成功（这行不应执行）\n"))))
  (sleep 0.5))

;; 5.2 执行时间限制
(define (run-with-timeout thunk timeout-ms)
  (let ([c (make-custodian)])
    (parameterize ([current-custodian c])
      (define t (thread thunk))
      (thread (λ () (sleep (/ timeout-ms 1000.0)) (custodian-shutdown-all c)))
      (with-handlers ([exn:fail? (λ (e) (printf "任务超时\n"))])
        (thread-wait t)
        (printf "任务在时限内完成\n")))))

(printf "\n测试执行时间限制...\n")
(run-with-timeout 
 (λ () 
   (printf "长时间任务开始...\n")
   (sleep 2)
   (printf "长时间任务完成\n"))
 1000) ; 1秒超时

;; ==================== 6. 多核并行Place ====================

(printf "\n=== 6. 多核并行Place ===\n")

;; 6.1 创建并行Place
(printf "创建并行Place利用多核CPU...\n")

(define parallel-place
  (place ch
    (printf "[Place进程] 启动，PID: ~a\n" (getpid))
    (let loop ([count 0])
      (match (place-channel-get ch)
        ['exit (printf "[Place进程] 退出\n")]
        [task
         (printf "[Place进程] 处理任务: ~a (第~a次)\n" task count)
         ;; 模拟CPU密集型计算
         (for ([i (in-range 1000000)]) (* i i))
         (place-channel-put ch (format "任务~a完成" task))
         (loop (+ count 1))]))))

;; 6.2 并行执行任务
(printf "向Place发送并行任务...\n")

(for ([i (in-range 3)])
  (place-channel-put parallel-place (format "任务~a" i))
  (thread (λ () 
            (define result (place-channel-get parallel-place))
            (printf "收到结果: ~a\n" result))))

(sleep 1) ; 等待任务完成

;; 关闭Place
(place-channel-put parallel-place 'exit)

;; ==================== 7. 综合应用：多模态旅行助手 ====================

(printf "\n=== 7. 综合应用：多模态旅行助手 ===\n")

;; 7.1 专业Agent定义
(def-multi-modal-agent flight-agent
  "航班查询与预订"
  "图像：航班时刻表、座位图"
  (λ ()
    (printf "[航班Agent] 查询航班信息...\n")
    (sleep 0.6)
    (printf "[航班Agent] 找到最佳航班：上海→北京 08:00-10:00\n")))

(def-multi-modal-agent hotel-agent
  "酒店查询与预订"
  "图像：酒店外观、房间照片"
  (λ ()
    (printf "[酒店Agent] 查询酒店信息...\n")
    (sleep 0.7)
    (printf "[酒店Agent] 推荐：北京王府井酒店，¥800/晚\n")))

(def-multi-modal-agent attraction-agent
  "景点推荐与门票"
  "图像：景点照片、地图"
  (λ ()
    (printf "[景点Agent] 查询景点信息...\n")
    (sleep 0.5)
    (printf "[景点Agent] 推荐：故宫、长城、颐和园\n")))

;; 7.2 并行执行所有Agent
(printf "并行执行旅行规划...\n")

(define travel-threads
  (list (thread flight-agent)
        (thread hotel-agent)
        (thread attraction-agent)))

;; 等待所有Agent完成
(for ([t travel-threads])
  (thread-wait t))

(printf "\n✅ 旅行规划完成！\n")
(printf "航班：上海→北京 08:00-10:00\n")
(printf "酒店：北京王府井酒店，¥800/晚\n")
(printf "景点：故宫、长城、颐和园\n")

;; ==================== 8. 高级特性：动态Custodian管理 ====================

(printf "\n=== 8. 高级特性：动态Custodian管理 ===\n")

;; 8.1 Custodian管理器
(define custodian-manager (make-hash))

(define (create-managed-agent name thunk)
  (let ([c (make-custodian)])
    (hash-set! custodian-manager name c)
    (thread
     (λ ()
       (parameterize ([current-custodian c])
         (with-handlers ([exn:fail? (λ (e) (printf "Agent ~a 崩溃: ~a\n" name (exn-message e)))])
           (thunk)))))))

;; 8.2 监控和清理函数
(define (shutdown-agent name)
  (when (hash-has-key? custodian-manager name)
    (custodian-shutdown-all (hash-ref custodian-manager name))
    (hash-remove! custodian-manager name)
    (printf "Agent ~a 已关闭\n" name)))

(define (list-active-agents)
  (printf "活跃Agent: ~a\n" (hash-keys custodian-manager)))

;; 8.3 测试动态管理
(printf "测试动态Custodian管理...\n")

(create-managed-agent "agent1" 
  (λ () 
    (printf "Agent1 运行中...\n")
    (sleep 1)
    (printf "Agent1 完成\n")))

(create-managed-agent "agent2"
  (λ ()
    (printf "Agent2 运行中...\n")
    (sleep 2)
    (printf "Agent2 完成\n")))

(sleep 0.5)
(list-active-agents)

(sleep 1)
(shutdown-agent "agent1")
(list-active-agents)

(sleep 1)
(shutdown-agent "agent2")
(list-active-agents)

;; ==================== 学习总结 ====================

(printf "\n=== 学习总结 ===\n")
(printf "1. Custodian基础: 资源监管器创建与管理\n")
(printf "2. 绿色线程: 轻量级线程创建与通信\n")
(printf "3. 多模态Agent沙箱: 文本+视觉意图封装\n")
(printf "4. 崩溃隔离: 单个Agent崩溃不影响系统\n")
(printf "5. 资源限制: 内存和执行时间控制\n")
(printf "6. 多核并行: Place进程利用多核CPU\n")
(printf "7. 综合应用: 多模态旅行助手系统\n")
(printf "8. 动态管理: Custodian管理器高级用法\n")

(printf "\n=== Custodian的AI优势 ===\n")
(printf "• 资源隔离: 每个Agent独立沙箱\n")
(printf "• 自动清理: 执行完成自动回收资源\n")
(printf "• 崩溃安全: 单个故障不影响整体\n")
(printf "• 并发控制: 安全的多Agent并行\n")
(printf "• 生产就绪: 企业级可靠性保障\n")

(printf "\n=== 实际应用场景 ===\n")
(printf "• AI Agent生产部署\n")
(printf "• 多模态处理系统\n")
(printf "• 实时数据分析\n")
(printf "• 容错微服务架构\n")
(printf "• 资源敏感型应用\n")

(printf "\n🎉 Day 4 Custodian沙箱实战完成！\n")
(printf "你的AI Agent现在可以在安全沙箱中并发执行了！🚀\n")

;; ==================== 下一步学习 ====================

(printf "\n=== 下一步学习 ===\n")
(printf "1. #lang机制: 自定义AI编程语言\n")
(printf "2. 类型系统: Typed Racket深度集成\n")
(printf "3. 形式验证: Rosette数学证明\n")
(printf "4. 分布式扩展: 跨机器Agent协作\n")
(printf "5. 性能优化: 大规模并发处理\n")

(printf "\n🚀 准备好迎接Day 5的自定义AI语言了吗？\n")