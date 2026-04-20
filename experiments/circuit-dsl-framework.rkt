#lang racket

;; 电路DSL框架实现
;; 基于syntax-parse的完整电路描述语言

(require syntax/parse
         (for-syntax syntax/parse)
         racket/format
         racket/match)

;; ==================== 基础数据结构 ====================

(struct node (name) #:transparent)
(struct component (type name nodes parameters) #:transparent)
(struct circuit (name components analyses probes constraints) #:transparent)

;; ==================== 语法解析器 ====================

;; 节点定义语法
(define-syntax-parser define-node
  [(_ name:id)
   #'(define name (node 'name))])

;; 组件定义宏
(define-syntax-parser define-component-type
  [(_ type:id (field:id ...) stamp-fn:expr)
   #'(begin
       (struct type component (field ...)
         #:property prop:stamp-function stamp-fn)
       
       ;; 语法转换器
       (define-syntax-parser type
         [(_ name:id nodes:expr params:expr ...)
          #'(type 'name nodes (hash params ...))]))])

;; 电路定义宏（核心）
(define-syntax-parser define-circuit
  #:datum-literals (#:title #:description #:generate #:verify #:analysis #:probes #:constraints)
  [(_ name:id
      (~seq (~or (~optional (~seq #:title title:str))
                 (~optional (~seq #:description desc:str))
                 (~optional (~seq #:generate (~or 'spice 'cpp 'both)))
                 (~optional (~seq #:verify (~or 'rosette 'basic 'none)))
                 (~optional (~seq #:analysis analysis:expr))
                 (~optional (~seq #:probes probes:expr))
                 (~optional (~seq #:constraints constraints:expr)))
            ...)
      components:expr ...)
   
   #'(begin
       ;; 创建电路结构
       (define name
         (circuit 'name
                  (list components ...)
                  (or analysis '())
                  (or probes '())
                  (or constraints '())))
       
       ;; 语义验证
       (when (and verify (not (eq? verify 'none)))
         (validate-circuit name verify))
       
       ;; 代码生成
       (cond
         [(eq? generate 'spice)
          (generate-spice-netlist name)]
         [(eq? generate 'cpp)
          (generate-cpp-simulator name)]
         [(eq? generate 'both)
          (begin
            (generate-spice-netlist name)
            (generate-cpp-simulator name))]
         [else
          (generate-spice-netlist name)]))])

;; ==================== 组件类型定义 ====================

;; 电阻
(define-component-type resistor (resistance tolerance temp-coeff)
  (λ (R n1 n2)
    (hash 'conductance (/ 1.0 R.resistance)
          'nodes (list n1 n2))))

;; 电容
(define-component-type capacitor (capacitance voltage-rating esr)
  (λ (C n1 n2)
    (hash 'capacitance C.capacitance
          'nodes (list n1 n2))))

;; 电感
(define-component-type inductor (inductance current-rating dcr)
  (λ (L n1 n2)
    (hash 'inductance L.inductance
          'nodes (list n1 n2))))

;; 电压源
(define-component-type vsource (voltage type frequency)
  (λ (V n+ n-)
    (hash 'voltage V.voltage
          'type V.type
          'frequency (or V.frequency 0)
          'nodes (list n+ n-))))

;; 电流源
(define-component-type isource (current type)
  (λ (I n+ n-)
    (hash 'current I.current
          'type I.type
          'nodes (list n+ n-))))

;; 二极管
(define-component-type diode (model is n rs)
  (λ (D anode cathode)
    (hash 'model D.model
          'is (or D.is 1e-12)
          'n (or D.n 1.0)
          'rs (or D.rs 0.0)
          'nodes (list anode cathode))))

;; 运放（理想）
(define-component-type opamp (gain slew-rate bandwidth)
  (λ (U in+ in- out)
    (hash 'gain (or U.gain 1e6)
          'slew-rate (or U.slew-rate 1e6)
          'bandwidth (or U.bandwidth 1e6)
          'nodes (list in+ in- out))))

;; ==================== 分析类型定义 ====================

(struct analysis (type parameters) #:transparent)

(define-syntax-parser define-analysis
  [(_ type:id (param:id ...) generator:expr)
   #'(begin
       (struct type analysis (param ...)
         #:property prop:analysis-generator generator)
       
       (define-syntax-parser type
         [(_ (~seq #:key val) ...)
          #'(type 'type (hash 'key val ...))]))])

;; 瞬态分析
(define-analysis transient (stop-time step method)
  (λ (analysis)
    (format ".tran ~a ~a~a"
            analysis.step
            analysis.stop-time
            (if analysis.method
                (format " method=~a" analysis.method)
                ""))))

;; DC分析
(define-analysis dc (sweep-source start stop step)
  (λ (analysis)
    (match analysis.sweep-source
      [(list source)
       (format ".dc ~a ~a ~a ~a"
               source
               analysis.start
               analysis.stop
               analysis.step)]
      [_ ""])))

;; AC分析
(define-analysis ac (start-freq stop-freq points)
  (λ (analysis)
    (format ".ac dec ~a ~a ~a"
            analysis.points
            analysis.start-freq
            analysis.stop-freq)))

;; ==================== 语义验证 ====================

;; 基础验证
(define (validate-circuit-basic circuit)
  (printf "验证电路: ~a\n" (circuit-name circuit))
  
  ;; 检查节点连接性
  (let ([nodes (collect-nodes circuit)])
    (printf "  节点数: ~a\n" (length nodes))
    
    ;; 检查孤岛节点
    (let ([isolated (find-isolated-nodes circuit nodes)])
      (when (not (null? isolated))
        (error (format "发现孤岛节点: ~a" isolated)))))
  
  ;; 检查组件参数范围
  (for ([comp (circuit-components circuit)])
    (validate-component-parameters comp))
  
  (printf "基础验证通过 ✓\n"))

;; 收集所有节点
(define (collect-nodes circuit)
  (remove-duplicates
   (append-map component-nodes (circuit-components circuit))))

;; 查找孤岛节点
(define (find-isolated-nodes circuit all-nodes)
  (filter (λ (node)
            (not (connected-to-ground? circuit node)))
          all-nodes))

;; 组件参数验证
(define (validate-component-parameters comp)
  (match comp
    [(resistor _ _ resistance _ _)
     (when (<= resistance 0)
       (error (format "电阻 ~a 的值必须为正数" (component-name comp))))]
    
    [(capacitor _ _ capacitance _ _)
     (when (<= capacitance 0)
       (error (format "电容 ~a 的值必须为正数" (component-name comp))))]
    
    [(inductor _ _ inductance _ _)
     (when (<= inductance 0)
       (error (format "电感 ~a 的值必须为正数" (component-name comp))))]
    
    [_ #t]))

;; ==================== 代码生成器 ====================

;; 生成SPICE netlist
(define (generate-spice-netlist circuit)
  (define netlist
    (string-append
     (format ".title ~a\n" (circuit-name circuit))
     "\n* 组件定义\n"
     (string-join (map component->spice (circuit-components circuit)) "\n")
     "\n\n* 分析设置\n"
     (string-join (map analysis->spice (circuit-analyses circuit)) "\n")
     "\n\n* 输出控制\n"
     (generate-output-controls (circuit-probes circuit))
     "\n.end\n"))
  
  (define filename (format "~a.cir" (circuit-name circuit)))
  (with-output-to-file filename
    (λ () (display netlist))
    #:exists 'replace)
  
  (printf "SPICE netlist已生成: ~a\n" filename)
  netlist)

;; 组件转SPICE
(define (component->spice comp)
  (match comp
    [(resistor name nodes params)
     (format "R~a ~a ~a ~a"
             name
             (first nodes) (second nodes)
             (hash-ref params 'resistance))]
    
    [(capacitor name nodes params)
     (format "C~a ~a ~a ~a"
             name
             (first nodes) (second nodes)
             (hash-ref params 'capacitance))]
    
    [(vsource name nodes params)
     (let ([type (hash-ref params 'type 'dc)])
       (case type
         [(dc) (format "V~a ~a ~a DC ~a"
                       name
                       (first nodes) (second nodes)
                       (hash-ref params 'voltage))]
         [(ac) (format "V~a ~a ~a AC ~a ~a"
                       name
                       (first nodes) (second nodes)
                       (hash-ref params 'voltage)
                       (hash-ref params 'frequency))]
         [else (format "V~a ~a ~a ~a"
                       name
                       (first nodes) (second nodes)
                       (hash-ref params 'voltage))]))]
    
    [_ (format "* 未实现的组件: ~a" (component-name comp))]))

;; 分析转SPICE
(define (analysis->spice analysis)
  (match analysis
    [(transient _ params)
     (format ".tran ~a ~a"
             (hash-ref params 'step 1e-9)
             (hash-ref params 'stop-time 1e-6))]
    
    [(dc _ params)
     (format ".dc ~a ~a ~a ~a"
             (hash-ref params 'sweep-source "V1")
             (hash-ref params 'start 0)
             (hash-ref params 'stop 5)
             (hash-ref params 'step 0.1))]
    
    [(ac _ params)
     (format ".ac dec ~a ~a ~a"
             (hash-ref params 'points 10)
             (hash-ref params 'start-freq 1)
             (hash-ref params 'stop-freq 1e9))]
    
    [_ ""]))

;; ==================== C++26代码生成 ====================

(define (generate-cpp-simulator circuit)
  (define cpp-code
    (string-append
     "// 自动生成的电路仿真器 - " (symbol->string (circuit-name circuit)) "\n"
     "// 由Racket DSL编译器生成\n\n"
     
     "#include <iostream>\n"
     "#include <simd>\n"
     "#include <inplace_vector>\n"
     "#include <mdspan>\n\n"
     
     "namespace generated {\n"
     "    class " (symbol->string (circuit-name circuit)) "_simulator {\n"
     "    public:\n"
     "        // 电路元数据\n"
     "        static constexpr const char* name = \"" 
     (symbol->string (circuit-name circuit)) "\";\n"
     "        static constexpr size_t num_nodes = " 
     (number->string (length (collect-nodes circuit))) ";\n"
     "        static constexpr size_t num_components = "
     (number->string (length (circuit-components circuit))) ";\n\n"
     
     "        // 组件定义\n"
     (generate-component-definitions (circuit-components circuit))
     "\n"
     "        // MNA矩阵\n"
     "        std::inplace_vector<double, " 
     (calculate-matrix-size circuit) "> G_data;\n"
     "        std::mdspan<double, 2> G_matrix{G_data.data(), "
     (format "{~a, ~a}" 
             (length (collect-nodes circuit))
             (length (collect-nodes circuit))) "};\n\n"
     
     "        // 节点电压\n"
     "        std::inplace_vector<double, "
     (number->string (length (collect-nodes circuit))) "> node_voltages;\n\n"
     
     "        // 构造函数\n"
     "        " (symbol->string (circuit-name circuit)) "_simulator() {\n"
     "            initialize_matrices();\n"
     "        }\n\n"
     
     "        // 初始化MNA矩阵\n"
     "        void initialize_matrices() {\n"
     (generate-matrix-initialization (circuit-components circuit))
     "        }\n\n"
     
     "        // 瞬态分析\n"
     "        std::simd<double, 4> transient_step(double dt) {\n"
     "            // SIMD加速的时间步进\n"
     "            auto voltages = load_voltages_simd();\n"
     "            auto new_voltages = solve_mna_simd(G_matrix, dt);\n"
     "            store_voltages_simd(new_voltages);\n"
     "            return new_voltages;\n"
     "        }\n\n"
     
     "    private:\n"
     "        // SIMD辅助函数\n"
     "        std::simd<double, 4> load_voltages_simd() const {\n"
     "            alignas(32) double voltage_data[4];\n"
     "            for (int i = 0; i < 4 && i < node_voltages.size(); ++i) {\n"
     "                voltage_data[i] = node_voltages[i];\n"
     "            }\n"
     "            return std::simd<double, 4>::load(voltage_data, std::vector_aligned);\n"
     "        }\n"
     "        \n"
     "        void store_voltages_simd(const std::simd<double, 4>& voltages) {\n"
     "            alignas(32) double voltage_data[4];\n"
     "            voltages.copy_to(voltage_data, std::vector_aligned);\n"
     "            for (int i = 0; i < 4 && i < node_voltages.size(); ++i) {\n"
     "                node_voltages[i] = voltage_data[i];\n"
     "            }\n"
     "        }\n"
     "    };\n"
     "}\n"))
  
  (define filename (format "~a_simulator.cpp" (circuit-name circuit)))
  (with-output-to-file filename
    (λ () (display cpp-code))
    #:exists 'replace)
  
  (printf "C++26仿真器已生成: ~a\n" filename)
  cpp-code)

(define (generate-component-definitions components)
  (string-join
   (for/list ([comp components])
     (match comp
       [(resistor name nodes params)
        (format "        // 电阻 ~a: ~a Ω 在节点 ~a-~a\n"
                name
                (hash-ref params 'resistance)
                (first nodes) (second nodes))]
       [(capacitor name nodes params)
        (format "        // 电容 ~a: ~a F 在节点 ~a-~a\n"
                name
                (hash-ref params 'capacitance)
                (first nodes) (second nodes))]
       [_ ""]))
   "\n"))

(define (calculate-matrix-size circuit)
  (let ([n (length (collect-nodes circuit))])
    (* n n)))

(define (generate-matrix-initialization components)
  (string-join
   (for/list ([comp components])
     (match comp
       [(resistor name nodes params)
        (let ([n1 (first nodes)] [n2 (second nodes)]
              [g (/ 1.0 (hash-ref params 'resistance))])
          (format "            // 电阻 ~a 的戳印\n"
                  name))]))))

;; ==================== 示例电路 ====================

;; 定义节点
(define-node gnd)
(define-node in)
(define-node out)

;; RC低通滤波器
(define-circuit rc-lowpass
  #:title "一阶RC低通滤波器"
  #:description "截止频率 ≈ 1/(2πRC) ≈ 159Hz"
  #:generate 'both
  #:verify 'basic
  #:analysis (transient #:stop-time 10e-3 #:step 1e-6)
  #:probes '((voltage Vout node: out))
  #:constraints '((cutoff-frequency > 100Hz))
  
  ;; 组件
  (vsource V1 5.0V #:nodes (in gnd) #:type 'dc)
  (resistor R1 1kΩ #:nodes (in out) #:tolerance '5%)
  (capacitor C1 1µF #:nodes (out gnd) #:voltage-rating 16V))

;; 运算放大器同相放大器
(define-circuit opamp-noninverting
  #:title "运算放大器同相放大器"
  #:description "增益 = 1 + R2/R1"
  #:generate 'both
  
  ;; 节点定义
  (define-node vcc)
  (define-node vee)
  (define-node vout)
  
  ;; 电源
  (vsource VCC 12V #:nodes (vcc gnd))
  (vsource VEE -12V #:nodes (vee gnd))
  (vsource Vin 1V #:nodes (in gnd)