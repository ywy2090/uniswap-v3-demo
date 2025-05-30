# Uniswap V3 集中流动性 Demo

这是一个简化版的Uniswap V3核心合约实现，展示了集中流动性（Concentrated Liquidity）的核心机制。

## 项目特性

- ✅ 集中流动性 ：支持在指定价格区间[tickLower, tickUpper]添加流动性
- ✅ Tick系统 ：实现基于tick的精确价格管理
- ✅ 动态交换 ：支持跨tick的复杂交换路径
- ✅ 手续费机制 ：内置0.3%交易手续费
- ✅ LP代币 ：自动计算和管理流动性凭证
- ✅ 双框架支持 ：同时支持Foundry和Hardhat测试

## 项目结构

uniswap-v3-demo/
├── src/
│   ├── UniswapV3Pool.sol      # 核心池子合约
│   └── TestToken.sol           # 测试用ERC20代币
├── test/
│   └── UniswapV3Pool.t.sol     # Foundry测试文件
├── test-hardhat/
│   └── UniswapV3Pool.test.js   # Hardhat测试文件
├── scripts/
│   └── deploy.js               # 部署脚本
├── foundry.toml                # Foundry配置
├── hardhat.config.js           # Hardhat配置
└── package.json                # NPM依赖

## 集中流动性原理

### 什么是集中流动性？

传统的AMM（如Uniswap V2）将流动性均匀分布在整个价格曲线上（0到∞），这导致了资本效率低下的问题。Uniswap V3引入了**集中流动性**概念，允许流动性提供者（LP）将资金集中在特定的价格区间内。

### 核心概念

#### 1. Tick系统

- **Tick**：价格的离散化表示，每个tick对应一个特定的价格点
- **价格关系**：`√P = 1.0001^(tick/2)`，即每个tick代表0.01%的价格变化
- **价格计算**：`P = (sqrtPriceX96 / 2^96)^2`

#### 2. 价格区间

- LP可以选择在`[tickLower, tickUpper]`区间内提供流动性
- 只有当前价格在该区间内时，流动性才会被激活并赚取手续费
- 区间外的流动性处于休眠状态

#### 3. 流动性计算（基于白皮书公式6）

当前价格在区间内时，所需的代币数量计算如下：
其中：

``` bash
当 √Pa ≤ √P ≤ √Pb 时：
amount0 = liquidity × (√Pb - √P) / (√P × √Pb)
amount1 = liquidity × (√P - √Pa)

当 √P < √Pa 时（价格低于区间）：
amount0 = liquidity × (√Pb - √Pa) / (√Pa × √Pb)
amount1 = 0

当 √P > √Pb 时（价格高于区间）：
amount0 = 0
amount1 = liquidity × (√Pb - √Pa)
```

- `√Pa`：区间下界的平方根价格
- `√Pb`：区间上界的平方根价格  
- `√P`：当前的平方根价格
- `liquidity`：流动性数量

#### 4. 交换机制

- **恒定乘积**：在每个价格区间内遵循 `x × y = k` 公式
- **流动性切换**：当价格跨越tick时，激活流动性会发生变化
- **滑点计算**：`state.liquidity = liquidityNet[nextTick]`
- **手续费**：固定0.3%，从输入金额中扣除

#### 5. 效率提升

假设ETH/USDC池子，当前价格为2000 USDC：

**传统V2方式**：

- 流动性分布：0 → ∞
- 大部分资金闲置在极端价格区间
- 资本利用率低

**V3集中流动性**：

- 流动性集中在[1800, 2200]区间
- 相同资金量可提供更深的流动性
- 资本利用率可提升数十倍

## Hardhat 开发环境设置

### **项目初始化**

```bash
# 克隆项目
git clone <repository-url>
cd uniswap-v3-demo

# 初始化npm
npm init -y
```

### **安装依赖**

```bash
# 安装Hardhat和相关工具链
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox

# 安装OpenZeppelin合约库
npm install --save-dev @openzeppelin/contracts

# 安装所有依赖
npm install

# 检查Hardhat版本
npx hardhat --version

# 查看可用hardhat任务
npx hardhat help
```

## 测试用例运行

```bash
# 编译合约
npm run compile
# 或者
npx hardhat compile

# 运行所有测试
npm run test
# 或者
npx hardhat test

# 运行详细测试（显示console.log输出）
npm run test:verbose
# 或者
npx hardhat test --verbose

# 运行特定测试文件
npx hardhat test test-hardhat/UniswapV3Pool.test.js

# 运行特定测试用例
npx hardhat test --grep "应该在.*价格区间成功添加流动性"

# 分析gas使用情况
REPORT_GAS=true npx hardhat test
```

## 本地开发

### **启动本地网络**

```bash
# 启动Hardhat本地网络
npm run node
# 或者
npx hardhat node

# 网络信息：
# - RPC URL: http://127.0.0.1:8545
# - Chain ID: 31337
# - 预设账户：20个，每个10000 ETH
```

### **部署合约**

```bash
# 部署合约
npm hardhat run deploy
# 或者
npx hardhat run scripts/deploy.js --network localhost
```

### **测试用例**

```bash
# 运行测试用例
npx hardhat test
```
