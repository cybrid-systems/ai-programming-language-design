// C++26 MNA求解器实现
// 高性能电路仿真核心引擎

#include <iostream>
#include <simd>
#include <inplace_vector>
#include <mdspan>
#include <algorithm>
#include <cmath>
#include <numbers>

// ==================== 基础类型定义 ====================

using real_t = double;
static constexpr size_t SIMD_WIDTH = 4;  // AVX2: 4个double

// SIMD向量类型
using simd_real = std::simd<real_t, SIMD_WIDTH>;

// 固定容量向量
template<size_t N>
using fixed_vector = std::inplace_vector<real_t, N>;

// 固定容量矩阵视图
template<size_t Rows, size_t Cols>
using matrix_view = std::mdspan<real_t, 2, std::layout_right>;

// ==================== 电路组件基类 ====================

struct CircuitComponent {
    virtual ~CircuitComponent() = default;
    
    // 组件名称
    virtual const char* name() const = 0;
    
    // 节点连接
    virtual std::array<size_t, 2> nodes() const = 0;
    
    // MNA戳印函数
    virtual void stamp(matrix_view<0, 0>& G, 
                       fixed_vector<0>& I, 
                       real_t dt = 0.0) const = 0;
    
    // 更新状态（用于非线性/时变组件）
    virtual void update_state(const fixed_vector<0>& voltages, real_t dt) {}
    
    // 获取电流
    virtual real_t current(const fixed_vector<0>& voltages) const { return 0.0; }
};

// ==================== 具体组件实现 ====================

// 电阻组件
struct Resistor : CircuitComponent {
    size_t node1, node2;
    real_t resistance;
    
    Resistor(size_t n1, size_t n2, real_t r)
        : node1(n1), node2(n2), resistance(r) {}
    
    const char* name() const override { return "Resistor"; }
    
    std::array<size_t, 2> nodes() const override {
        return {node1, node2};
    }
    
    void stamp(matrix_view<0, 0>& G, 
               fixed_vector<0>& I, 
               real_t dt = 0.0) const override {
        real_t conductance = 1.0 / resistance;
        
        // 主对角线
        G(node1, node1) += conductance;
        G(node2, node2) += conductance;
        
        // 非对角线
        G(node1, node2) -= conductance;
        G(node2, node1) -= conductance;
    }
    
    real_t current(const fixed_vector<0>& voltages) const override {
        return (voltages[node1] - voltages[node2]) / resistance;
    }
};

// 电容组件
struct Capacitor : CircuitComponent {
    size_t node1, node2;
    real_t capacitance;
    real_t prev_voltage = 0.0;
    real_t prev_current = 0.0;
    
    Capacitor(size_t n1, size_t n2, real_t c)
        : node1(n1), node2(n2), capacitance(c) {}
    
    const char* name() const override { return "Capacitor"; }
    
    std::array<size_t, 2> nodes() const override {
        return {node1, node2};
    }
    
    void stamp(matrix_view<0, 0>& G, 
               fixed_vector<0>& I, 
               real_t dt = 0.0) const override {
        if (dt > 0.0) {
            // 使用梯形积分法
            real_t geq = 2.0 * capacitance / dt;
            real_t ieq = -geq * prev_voltage - prev_current;
            
            G(node1, node1) += geq;
            G(node2, node2) += geq;
            G(node1, node2) -= geq;
            G(node2, node1) -= geq;
            
            I[node1] -= ieq;
            I[node2] += ieq;
        }
    }
    
    void update_state(const fixed_vector<0>& voltages, real_t dt) override {
        real_t voltage = voltages[node1] - voltages[node2];
        real_t current = capacitance * (voltage - prev_voltage) / dt;
        
        prev_voltage = voltage;
        prev_current = current;
    }
    
    real_t current(const fixed_vector<0>& voltages) const override {
        return prev_current;
    }
};

// 电感组件
struct Inductor : CircuitComponent {
    size_t node1, node2;
    real_t inductance;
    real_t prev_current = 0.0;
    real_t prev_voltage = 0.0;
    
    Inductor(size_t n1, size_t n2, real_t L)
        : node1(n1), node2(n2), inductance(L) {}
    
    const char* name() const override { return "Inductor"; }
    
    std::array<size_t, 2> nodes() const override {
        return {node1, node2};
    }
    
    void stamp(matrix_view<0, 0>& G, 
               fixed_vector<0>& I, 
               real_t dt = 0.0) const override {
        if (dt > 0.0) {
            // 使用梯形积分法
            real_t geq = dt / (2.0 * inductance);
            real_t ieq = prev_current + geq * prev_voltage;
            
            G(node1, node1) += geq;
            G(node2, node2) += geq;
            G(node1, node2) -= geq;
            G(node2, node1) -= geq;
            
            I[node1] -= ieq;
            I[node2] += ieq;
        }
    }
    
    void update_state(const fixed_vector<0>& voltages, real_t dt) override {
        real_t voltage = voltages[node1] - voltages[node2];
        real_t current = prev_current + (dt / (2.0 * inductance)) * 
                         (voltage + prev_voltage);
        
        prev_voltage = voltage;
        prev_current = current;
    }
    
    real_t current(const fixed_vector<0>& voltages) const override {
        return prev_current;
    }
};

// 电压源组件
struct VoltageSource : CircuitComponent {
    size_t node_plus, node_minus;
    real_t voltage;
    size_t branch_index;  // 用于MNA的额外变量
    
    VoltageSource(size_t np, size_t nm, real_t v, size_t idx)
        : node_plus(np), node_minus(nm), voltage(v), branch_index(idx) {}
    
    const char* name() const override { return "VoltageSource"; }
    
    std::array<size_t, 2> nodes() const override {
        return {node_plus, node_minus};
    }
    
    void stamp(matrix_view<0, 0>& G, 
               fixed_vector<0>& I, 
               real_t dt = 0.0) const override {
        size_t n = G.extent(0);
        size_t j = n + branch_index;
        
        // KVL方程
        G(node_plus, j) += 1.0;
        G(node_minus, j) -= 1.0;
        G(j, node_plus) += 1.0;
        G(j, node_minus) -= 1.0;
        
        // 电压约束
        I[j] += voltage;
    }
};

// ==================== MNA求解器 ====================

template<size_t MaxNodes, size_t MaxComponents>
class MNASolver {
public:
    static constexpr size_t MAX_NODES = MaxNodes;
    static constexpr size_t MAX_COMPONENTS = MaxComponents;
    
    // 构造函数
    MNASolver() {
        // 初始化矩阵和向量
        G_data_.resize(MAX_NODES * MAX_NODES, 0.0);
        I_data_.resize(MAX_NODES, 0.0);
        voltages_.resize(MAX_NODES, 0.0);
        
        // 创建矩阵视图
        G_matrix_ = matrix_view<MAX_NODES, MAX_NODES>(
            G_data_.data(), MAX_NODES, MAX_NODES);
    }
    
    // 添加组件
    void add_component(std::unique_ptr<CircuitComponent> comp) {
        if (components_.size() >= MAX_COMPONENTS) {
            throw std::runtime_error("超出最大组件数量限制");
        }
        components_.push_back(std::move(comp));
    }
    
    // 构建MNA矩阵
    void build_matrices(real_t dt = 0.0) {
        // 清零矩阵和向量
        std::fill(G_data_.begin(), G_data_.end(), 0.0);
        std::fill(I_data_.begin(), I_data_.end(), 0.0);
        
        // 为每个组件添加戳印
        for (const auto& comp : components_) {
            comp->stamp(G_matrix_, I_data_, dt);
        }
        
        // 添加接地节点约束（节点0为地）
        G_matrix_(0, 0) = 1.0;
        I_data_[0] = 0.0;
    }
    
    // 求解线性系统（使用SIMD加速的高斯消元）
    bool solve() {
        size_t n = voltages_.size();
        
        // 复制矩阵和向量用于求解
        fixed_vector<MAX_NODES * MAX_NODES> G_copy = G_data_;
        fixed_vector<MAX_NODES> I_copy = I_data_;
        
        matrix_view<MAX_NODES, MAX_NODES> G_view(
            G_copy.data(), n, n);
        
        // 前向消元（SIMD优化）
        for (size_t k = 0; k < n; ++k) {
            // 查找主元
            size_t pivot = k;
            real_t max_val = std::abs(G_view(k, k));
            
            for (size_t i = k + 1; i < n; ++i) {
                real_t val = std::abs(G_view(i, k));
                if (val > max_val) {
                    max_val = val;
                    pivot = i;
                }
            }
            
            if (max_val < 1e-12) {
                return false;  // 奇异矩阵
            }
            
            // 交换行
            if (pivot != k) {
                for (size_t j = k; j < n; ++j) {
                    std::swap(G_view(k, j), G_view(pivot, j));
                }
                std::swap(I_copy[k], I_copy[pivot]);
            }
            
            // 归一化主元行
            real_t pivot_val = G_view(k, k);
            for (size_t j = k + 1; j < n; ++j) {
                G_view(k, j) /= pivot_val;
            }
            I_copy[k] /= pivot_val;
            G_view(k, k) = 1.0;
            
            // 消去下方行（SIMD优化）
            for (size_t i = k + 1; i < n; i += SIMD_WIDTH) {
                simd_real factor;
                for (size_t s = 0; s < SIMD_WIDTH && i + s < n; ++s) {
                    factor[s] = G_view(i + s, k);
                }
                
                for (size_t j = k + 1; j < n; ++j) {
                    simd_real g_val;
                    for (size_t s = 0; s < SIMD_WIDTH && i + s < n; ++s) {
                        g_val[s] = G_view(i + s, j);
                    }
                    g_val -= factor * G_view(k, j);
                    
                    for (size_t s = 0; s < SIMD_WIDTH && i + s < n; ++s) {
                        G_view(i + s, j) = g_val[s];
                    }
                }
                
                simd_real i_val;
                for (size_t s = 0; s < SIMD_WIDTH && i + s < n; ++s) {
                    i_val[s] = I_copy[i + s];
                }
                i_val -= factor * I_copy[k];
                
                for (size_t s = 0; s < SIMD_WIDTH && i + s < n; ++s) {
                    I_copy[i + s] = i_val[s];
                }
            }
        }
        
        // 回代求解
        for (int k = n - 1; k >= 0; --k) {
            voltages_[k] = I_copy[k];
            for (size_t j = k + 1; j < n; ++j) {
                voltages_[k] -= G_view(k, j) * voltages_[j];
            }
        }
        
        return true;
    }
    
    // 瞬态分析
    void transient_analysis(real_t stop_time, real_t time_step) {
        std::cout << "开始瞬态分析...\n";
        std::cout << "时间范围: 0 到 " << stop_time << " 秒\n";
        std::cout << "时间步长: " << time_step << " 秒\n\n";
        
        real_t time = 0.0;
        size_t step = 0;
        
        while (time < stop_time) {
            // 构建时变矩阵
            build_matrices(time_step);
            
            // 求解
            if (!solve()) {
                std::cerr << "第 " << step << " 步求解失败\n";
                break;
            }
            
            // 更新组件状态
            for (const auto& comp : components_) {
                comp->update_state(voltages_, time_step);
            }
            
            // 输出进度
            if (step % 1000 == 0) {
                std::cout << "时间: " << time << " 秒, ";
                std::cout << "Vout: " << voltages_[2] << " V\n";
            }
            
            time += time_step;
            step++;
        }
        
        std::cout << "\n瞬态分析完成，总步数: " << step << "\n";
    }
    
    // 获取节点电压
    const fixed_vector<MAX_NODES>& voltages() const {
        return voltages_;
    }
    
    // 计算功耗
    real_t calculate_power() const {
        real_t total_power = 0.0;
        
        for (const auto& comp : components_) {
            if (auto* vs = dynamic_cast<VoltageSource*>(comp.get())) {
                real_t current = comp->current(voltages_);
                total_power += std::abs(vs->voltage * current);
            }
        }
        
        return total_power;
    }
    
private:
    // 存储
    fixed_vector<MAX_NODES * MAX_NODES> G_data_;
    fixed_vector<MAX_NODES> I_data_;
    fixed_vector<MAX_NODES> voltages_;
    
    matrix_view<MAX_NODES, MAX_NODES> G_matrix_;
    std::vector<std::unique_ptr<CircuitComponent>> components_;
};

// ==================== 示例电路 ====================

// RC低通滤波器电路
void example_rc_lowpass() {
    std::cout << "=== RC低通滤波器仿真 ===\n\n";
    
    // 创建求解器（最大4个节点，10个组件）
    MNASolver<4, 10> solver;
    
    // 添加组件
    // 节点: 0=地, 1=输入, 2=输出
    solver.add_component(std::make_unique<VoltageSource>(1, 0, 5.0, 0));
    solver.add_component(std::make_unique<Resistor>(1, 2, 1000.0));  // 1kΩ
    solver.add_component(std::make_unique<Capacitor>(2, 0, 1e-6));   // 1µF
    
    // DC分析
    std::cout << "执行DC分析...\n";
    solver.build_matrices();
    if (solver.solve()) {
        auto voltages = solver.voltages();
        std::cout << "节点电压:\n";
        std::cout << "  V1 (输入): " << voltages[1] << " V\n";
        std::cout << "  V2 (输出): " << voltages[2] << " V\n";
        std::cout << "  功耗: " << solver.calculate_power() << " W\n";
    }
    
    std::cout << "\n";
    
    // 瞬态分析
    solver.transient_analysis(10e-3, 1e-6);
}

// 运算放大器电路
void example_opamp_circuit() {
    std::cout << "\n=== 运算放大器电路仿真 ===\n\n";
    
    // 创建求解器（最大8个节点，20个组件）
    MNASolver<8, 20> solver;
    
    // 添加组件
    // 理想运放模型：使用VCVS（电压控制电压源）近似
    // 节点: 0=地, 1=正输入, 2=负输入, 3=输出
    
    // 输入信号
    solver.add_component(std::make_unique<VoltageSource>(1, 0, 1.0, 0));
    
    // 反馈网络
    solver.add_component(std::make_unique<Resistor>(1, 2, 1000.0));   // R1
    solver.add_component(std::make_unique<Resistor>(2, 3, 10000.0));  // R2
    
    // 理想运放（增益=1e6）
    // 使用VCVS: V(3) = 1e6 * (V(1) - V(2))
    // 这需要额外的MNA变量，简化示例中省略
    
    std::cout << "运算放大器电路设置完成\n";
    std::cout << "增益 ≈ 1 + R2/R1 = " << (1.0 + 10000.0/