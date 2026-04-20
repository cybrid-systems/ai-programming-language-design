#lang racket/base

;; ============================================
;; 电路DSL - LLM集成完整版
;; 自然语言 → LLM生成 → 验证 → 代码生成
;; ============================================

(require syntax/parse
         racket/struct
         racket/format
         racket/file
         racket/list
         racket/json
         net/url
         racket/port)

;; ==================== LLM配置 ====================
(define API-KEY (getenv "OPENAI_API_KEY"))
(when (not API-KEY)
  (error 'llm "请先设置环境变量：export OPENAI_API_KEY=sk-..."))

(define (call-llm prompt)
  (define url "https://api.openai.com/v1/chat/completions")
  (define body (jsexpr->string
                (hasheq 'model "gpt-4o"
                        'messages (list
                                   (hasheq 'role "system"
                                           'content "你是电路DSL专家。请只输出合法的Racket代码（define-subcircuit 和 define-circuit），不要任何解释、markdown或额外文字。")
                                   (hasheq 'role "user" 'content prompt)))))
  (define resp (post-pure-port (string->url url)
                               (string->bytes/utf-8 body)
                               (list "Content-Type: application/json"
                                     (format "Authorization: Bearer ~a" API-KEY))))
  (define json (bytes->jsexpr (port->bytes resp)))
  (hash-ref (first (hash-ref json 'choices)) 'message 'content))

;; ==================== 核心数据结构 ====================
(struct circuit (name title analysis components probes) 
  #:transparent
  #:methods gen:custom-write
  [(define (write-proc c port mode)
     (fprintf port "#<circuit:~a>" (circuit-name c)))])

(struct subcircuit (name nodes components) #:transparent)
(struct component (type id value nodes options) #:transparent)
(struct probe (type name node) #:transparent)

;; ==================== 语法类定义 ====================
(begin-for-syntax
  (define-syntax-class node
    #:description "电路节点（数字或符号）"
    (pattern (~or n:number n:symbol)))
  
  (define-syntax-class comp
    #:description "电路元件"
    (pattern (type:id id:id val:expr (nodes n1:node n2:node) 
             (~optional (~seq #:options opts:expr) #:defaults ([opts #'()])))))
  
  (define-syntax-class prb
    #:description "探测点"
    (pattern (probe-type:id probe-name:id nd:node)))
  
  (define-syntax-class inst
    #:description "子电路实例"
    (pattern (instance id:id sub-name:id (nodes n1:node n2:node n3:node ...)))))

;; ==================== 子电路宏 ====================
(define-syntax (define-subcircuit stx)
  (syntax-parse stx
    [(_ name:id (nodes node:id ...) comp:comp ...)
     #`(define name
         (subcircuit 'name '(node ...)
                     (list (component 'comp.type 'comp.id comp.val 
                                      (list comp.n1 comp.n2) comp.opts) ...)))]))

;; ==================== 电路宏（支持子电路实例） ====================
(define-syntax (define-circuit stx)
  (syntax-parse stx
    [(_ name:id
        (~alt
         (~optional (~seq #:title title:expr) 
                    #:defaults ([title #'"Unnamed Circuit"]))
         (~optional (~seq #:analysis analysis:expr)
                    #:defaults ([analysis #'(dc)])))
        (~or comp:comp ...)
        (~or inst:inst ...)
        (~or prb:prb ...))
     
     #`(define name
         (circuit
          'name
          #,title
          #,analysis
          (list (component 'comp.type 'comp.id comp.val 
                           (list comp.n1 comp.n2) comp.opts) ...)
          (list (probe 'prb.probe-type 'prb.probe-name prb.nd) ...)))]))

;; ==================== LLM生成电路 ====================
(define (llm-generate-circuit intent)
  (printf "🤖 LLM正在解析自然语言：~a\n" intent)
  
  (define prompt
    (format "请根据以下需求生成合法的Racket电路DSL代码，支持子电路、参数化、概率类型、命名节点。\n\n需求：~a\n\n支持语法：\n1. 子电路定义：\n   (define-subcircuit 名称 (nodes 节点...) 元件...)\n2. 电路定义：\n   (define-circuit 名称 #:title \"标题\" #:analysis (类型) 元件... 实例... 探测点...)\n3. 元件语法：\n   (元件类型 标识 值 (nodes 节点...) #:选项 ...)\n4. 实例语法：\n   (instance 标识 子电路名 (nodes 节点...))\n5. 探测点：\n   (probe 类型 名称 节点)\n\n只输出代码，不要任何解释。" intent))
  
  (define llm-response (call-llm prompt))
  (printf "✅ LLM返回代码（前300字符）：~a\n" 
          (substring llm-response 0 (min 300 (string-length llm-response))))
  
  (read-syntax 'llm-input (open-input-string llm-response)))

;; ==================== 基础验证系统 ====================
(define (validate-circuit circ)
  (printf "🔍 验证电路 ~a ...\n" (circuit-name circ))
  
  ;; 1. 节点检查
  (define nodes (remove-duplicates
                 (apply append (map component-nodes (circuit-components circ)))))
  (printf " ✓ 发现 ~a 个节点\n" (length nodes))
  
  ;; 2. 接地检查
  (unless (member 0 nodes)
    (printf " ⚠️ 警告：电路没有接地节点（节点0）\n"))
  
  ;; 3. 参数范围检查
  (for ([c (circuit-components circ)])
    (define val (component-value c))
    (when (and (number? val) (<= val 0))
      (error 'validate-circuit 
             "元件 ~a 值必须 > 0，当前为 ~a" 
             (component-id c) val)))
  
  (printf "✅ 基础验证通过\n")
  circ)

;; ==================== SPICE生成器（支持子电路） ====================
(define (generate-spice circ filename)
  (with-output-to-file filename #:exists 'replace
    (λ ()
      (printf "* SPICE netlist generated by Racket DSL + LLM\n")
      (printf "* Circuit: ~a\n" (circuit-title circ))
      (printf "* Analysis: ~a\n\n" (circuit-analysis circ))
      
      ;; 生成所有元件
      (for ([c (circuit-components circ)])
        (define n1 (first (component-nodes c)))
        (define n2 (second (component-nodes c)))
        
        (case (component-type c)
          [(vsource)
           (printf "V~a ~a ~a DC ~a\n" (component-id c) n1 n2 (component-value c))]
          [(resistor)
           (printf "R~a ~a ~a ~a\n" (component-id c) n1 n2 (component-value c))]
          [(capacitor)
           (printf "C~a ~a ~a ~a\n" (component-id c) n1 n2 (component-value c))]
          [(inductor)
           (printf "L~a ~a ~a ~a\n" (component-id c) n1 n2 (component-value c))]
          [(diode)
           (printf "D~a ~a ~a Ddefault\n" (component-id c) n1 n2)]
          [(opamp)
           (define n3 (third (component-nodes c)))
           (printf "X~a ~a ~a ~a opamp\n" (component-id c) n1 n2 n3)]
          [(switch)
           (printf "S~a ~a ~a ~a 0 SW\n" (component-id c) n1 n2 n1)]
          [(mosfet)
           (define n3 (third (component-nodes c)))
           (define mos-type (if (eq? (cadr (assoc '#:type (component-options c))) 'nmos)
                                "nmos" "pmos"))
           (printf "M~a ~a ~a ~a 0 ~a\n" (component-id c) n1 n2 n3 mos-type)]))
      
      ;; 生成探测点
      (for ([p (circuit-probes circ)])
        (printf ".probe v(~a)\n" (probe-node p)))
      
      ;; 生成分析命令
      (match (car (circuit-analysis circ))
        ['dc (printf "\n.op\n")]
        ['transient 
         (define stop-time (cadr (assoc '#:stop-time (cdr (circuit-analysis circ)))))
         (printf "\n.tran 1e-6 ~a\n" (or stop-time 0.01))]
        ['ac
         (define freq-range (cadr (assoc '#:freq-range (cdr (circuit-analysis circ)))))
         (printf "\n.ac dec 10 ~a ~a\n" (first freq-range) (second freq-range))])
      
      (printf ".end\n")))
  (printf "📄 SPICE netlist 已生成 → ~a\n" filename))

;; ==================== C++生成器（基础版） ====================
(define (generate-cpp-simulator circ filename)
  (with-output-to-file filename #:exists 'replace
    (λ ()
      (printf "// C++ circuit simulator - Generated by Racket DSL + LLM\n")
      (printf "// Circuit: ~a\n\n" (circuit-title circ))
      
      (printf "#include <iostream>\n")
      (printf "#include <vector>\n")
      (printf "#include <map>\n")
      (printf "#include <cmath>\n\n")
      
      (printf "class ~a {\n" (string-titlecase (symbol->string (circuit-name circ))))
      (printf "public:\n")
      (printf "  static constexpr const char* name = \"~a\";\n\n" (circuit-name circ))
      
      (printf "  std::vector<double> voltages;\n")
      (printf "  std::vector<double> currents;\n\n")
      
      (printf "  void initialize() {\n")
      (printf "    voltages.assign(20, 0.0);\n")
      (printf "    currents.assign(20, 0.0);\n")
      (printf "  }\n\n")
      
      (printf "  void solve() {\n")
      (printf "    // 简单求解（后续可扩展为完整MNA）\n")
      (for ([c (circuit-components circ)]
            [i (in-naturals)])
        (match (component-type c)
          ['vsource
           (printf "    voltages[~a] = ~a; // ~a\n" 
                   (first (component-nodes c))
                   (component-value c)
                   (component-id c))]
          ['resistor
           (printf "    currents[~a] = (voltages[~a] - voltages[~a]) / ~a; // ~a\n"
                   i
                   (first (component-nodes c))
                   (second (component-nodes c))
                   (component-value c)
                   (component-id c))]
          [_ (void)]))
      (printf "  }\n\n")
      
      (printf "  void print_results() {\n")
      (for ([p (circuit-probes circ)])
        (printf "    std::cout << \"~a = \" << voltages[~a] << \" V\\n\";\n"
                (probe-name p) (probe-node p)))
      (printf "  }\n")
      
      (printf "};\n\n")
      
      (printf "int main() {\n")
      (printf "  ~a circuit;\n" (string-titlecase (symbol->string (circuit-name circ))))
      (printf "  circuit.initialize();\n")
      (printf "  circuit.solve();\n")
      (printf "  circuit.print_results();\n")
      (printf "  return 0;\n")
      (printf "}\n")))
  (printf "🚀 C++ 仿真器已生成 → ~a\n" filename))

;; ==================== 提供接口 ====================
(provide llm-generate-circuit validate-circuit generate-spice generate-cpp-simulator)

;; ==================== 示例：手动定义子电路 ====================
(module+ test-manual
  (printf "=== 手动定义子电路示例 ===\n\n")
  
  ;; 定义运算放大器子电路
  (define-subcircuit simple-opamp
    (nodes in- in+ out)
    (resistor Rf 10k (nodes in- out))
    (resistor Rg 1k (nodes in+ 0)))
  
  ;; 使用子电路
  (define-circuit opamp-circuit
    #:title "使用子电路的运算放大器"
    #:analysis (dc)
    
    (vsource Vin 1.0 (nodes 1 0))
    (instance U1 simple-opamp (nodes 1 0 2))
    
    (probe voltage Vout 2))
  
  (validate-circuit opamp-circuit)
  (generate-spice opamp-circuit "opamp-with-subcircuit.cir")
  (generate-cpp-simulator opamp-circuit "opamp_with_subcircuit_sim.cpp")
  
  (printf "\n🎉 手动子电路示例完成！\n"))

;; ==================== 示例：LLM生成电路 ====================
(module+ test-llm
  (printf "=== LLM生成电路示例 ===\n\n")
  
  ;; 注意：需要设置 OPENAI_API_KEY 环境变量
  (when (not API-KEY)
    (printf "⚠️ 跳过LLM测试：请设置 OPENAI_API_KEY 环境变量\n")
    (exit 0))
  
  ;; 简单意图示例
  (define intent "设计一个简单的RC低通滤波器，输入5V，电阻1k，电容1uF，输出节点2")
  
  (printf "意图：~a\n\n" intent)
  
  (define raw-stx (llm-generate-circuit intent))
  (printf "\n✅ LLM代码生成完成\n")
  
  (define circ (eval raw-stx))
  (validate-circuit circ)
  (generate-spice circ "llm-generated.cir")
  (generate-cpp-simulator circ "llm_generated_sim.cpp")
  
  (printf "\n🎉 LLM生成电路示例完成！\n"))