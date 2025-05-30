// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title 简化版Uniswap V3核心合约
/// @notice 实现集中流动性（Concentrated Liquidity）功能
contract UniswapV3Pool is ERC20, ReentrancyGuard {
    // ============ 常量定义 ============
    
    /// @notice 固定手续费率 0.3%
    uint24 public constant FEE = 3000; // 0.3% = 3000 / 1000000
    
    /// @notice Q64.96格式的固定点数精度
    uint256 public constant Q96 = 2**96;
    
    /// @notice 每个Tick对应的价格倍数 √1.0001
    uint256 public constant TICK_BASE = 1000100000000000000; // √1.0001 * 10^18
    
    /// @notice 最小和最大Tick值
    int24 public constant MIN_TICK = -887272;
    int24 public constant MAX_TICK = 887272;
    
    // ============ 状态变量 ============
    
    /// @notice 代币对
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    
    /// @notice Tick信息结构体
    struct TickInfo {
        uint128 liquidityGross; // 该Tick上的总流动性
        int128 liquidityNet;    // 该Tick上的净流动性变化
        bool initialized;       // 是否已初始化
    }
    
    /// @notice 流动性位置信息
    struct Position {
        uint128 liquidity;      // 流动性数量
        uint256 feeGrowthInside0LastX128; // 上次收取手续费时的累计手续费
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;    // 待提取的token0手续费
        uint128 tokensOwed1;    // 待提取的token1手续费
    }
    
    /// @notice 全局池状态
    struct PoolState {
        uint128 liquidity;      // 当前激活的流动性
        uint256 sqrtPriceX96;   // Q64.96格式的平方根价格
        int24 currentTick;      // 当前价格对应的Tick
        uint256 feeGrowthGlobal0X128; // 全局累计手续费
        uint256 feeGrowthGlobal1X128;
    }
    
    /// @notice 池状态
    PoolState public poolState;
    
    /// @notice Tick数据映射
    mapping(int24 => TickInfo) public ticks;
    
    /// @notice 用户位置映射 keccak256(owner, tickLower, tickUpper) => Position
    mapping(bytes32 => Position) public positions;
    
    // ============ 事件定义 ============
    
    event Mint(
        address indexed sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    
    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0Delta,
        int256 amount1Delta,
        uint256 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );
    
    // ============ 构造函数 ============
    
    constructor(
        address _token0,
        address _token1,
        uint256 _sqrtPriceX96
    ) ERC20("UniswapV3-LP", "UNI-V3-LP") {
        require(_token0 < _token1, "Token order invalid");
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        
        // 初始化池状态
        poolState.sqrtPriceX96 = _sqrtPriceX96;
        poolState.currentTick = _getTickAtSqrtRatio(_sqrtPriceX96);
    }
    
    // ============ 核心功能实现 ============
    
    /// @notice 在指定价格区间添加流动性
    /// @param tickLower 价格区间下界
    /// @param tickUpper 价格区间上界
    /// @param amount 要添加的流动性数量
    /// @param amount0Desired 期望的token0数量
    /// @param amount1Desired 期望的token1数量
    /// @return amount0 实际使用的token0数量
    /// @return amount1 实际使用的token1数量
    function mint(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(tickLower < tickUpper, "Invalid tick range");
        require(tickLower >= MIN_TICK && tickUpper <= MAX_TICK, "Tick out of range");
        require(amount > 0, "Amount must be positive");
        
        // 计算所需的代币数量（基于白皮书公式6）
        (amount0, amount1) = _getAmountsForLiquidity(
            poolState.sqrtPriceX96,
            tickLower,
            tickUpper,
            amount
        );
        
        require(amount0 <= amount0Desired && amount1 <= amount1Desired, "Insufficient desired amounts");
        
        // 更新Tick信息
        _updateTick(tickLower, int128(amount));
        _updateTick(tickUpper, -int128(amount));
        
        // 如果当前价格在添加的区间内，更新激活流动性
        if (poolState.currentTick >= tickLower && poolState.currentTick < tickUpper) {
            poolState.liquidity += amount;
        }
        
        // 更新用户位置
        bytes32 positionKey = keccak256(abi.encodePacked(msg.sender, tickLower, tickUpper));
        positions[positionKey].liquidity += amount;
        
        // 转入代币
        if (amount0 > 0) token0.transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.transferFrom(msg.sender, address(this), amount1);
        
        // 铸造LP代币
        _mint(msg.sender, amount);
        
        emit Mint(msg.sender, msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }
    
    /// @notice 执行代币兑换
    /// @param zeroForOne 是否用token0换token1
    /// @param amountSpecified 指定的代币数量（正数表示精确输入，负数表示精确输出）
    /// @param sqrtPriceLimitX96 价格限制
    /// @return amount0Delta token0的变化量
    /// @return amount1Delta token1的变化量
    function swap(
        bool zeroForOne,
        int256 amountSpecified,
        uint256 sqrtPriceLimitX96
    ) external nonReentrant returns (int256 amount0Delta, int256 amount1Delta) {
        require(amountSpecified != 0, "Amount cannot be zero");
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < poolState.sqrtPriceX96 && sqrtPriceLimitX96 > 0
                : sqrtPriceLimitX96 > poolState.sqrtPriceX96,
            "Invalid price limit"
        );
        
        // 执行交换逻辑
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: poolState.sqrtPriceX96,
            tick: poolState.currentTick,
            liquidity: poolState.liquidity
        });
        
        // 主要交换循环
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;
            
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            
            // 找到下一个初始化的Tick
            (step.tickNext, step.initialized) = _nextInitializedTickWithinOneWord(
                state.tick,
                zeroForOne
            );
            
            // 计算到下一个Tick的价格
            step.sqrtPriceNextX96 = _getSqrtRatioAtTick(step.tickNext);
            
            // 计算交换数量
            (state.sqrtPriceX96, step.amountIn, step.amountOut) = _computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining
            );
            
            if (amountSpecified > 0) {
                state.amountSpecifiedRemaining -= int256(step.amountIn);
                state.amountCalculated = state.amountCalculated - int256(step.amountOut);
            } else {
                state.amountSpecifiedRemaining += int256(step.amountOut);
                state.amountCalculated = state.amountCalculated + int256(step.amountIn);
            }
            
            // 如果价格移动到下一个Tick，更新流动性
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    int128 liquidityNet = ticks[step.tickNext].liquidityNet;
                    if (zeroForOne) liquidityNet = -liquidityNet;
                    state.liquidity = liquidityNet < 0
                        ? state.liquidity - uint128(-liquidityNet)
                        : state.liquidity + uint128(liquidityNet);
                }
                
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = _getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }
        
        // 更新全局状态
        poolState.sqrtPriceX96 = state.sqrtPriceX96;
        poolState.currentTick = state.tick;
        poolState.liquidity = state.liquidity;
        
        // 计算最终的代币变化量
        (amount0Delta, amount1Delta) = zeroForOne
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);
        
        // 执行代币转账
        if (zeroForOne) {
            if (amount1Delta < 0) token1.transfer(msg.sender, uint256(-amount1Delta));
            if (amount0Delta > 0) token0.transferFrom(msg.sender, address(this), uint256(amount0Delta));
        } else {
            if (amount0Delta < 0) token0.transfer(msg.sender, uint256(-amount0Delta));
            if (amount1Delta > 0) token1.transferFrom(msg.sender, address(this), uint256(amount1Delta));
        }
        
        emit Swap(msg.sender, msg.sender, amount0Delta, amount1Delta, state.sqrtPriceX96, state.liquidity, state.tick);
    }
    
    /// @notice 移除流动性
    /// @param tickLower 价格区间下界
    /// @param tickUpper 价格区间上界
    /// @param amount 要移除的流动性数量
    /// @return amount0 返还的token0数量
    /// @return amount1 返还的token1数量
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(amount > 0, "Amount must be positive");
        
        bytes32 positionKey = keccak256(abi.encodePacked(msg.sender, tickLower, tickUpper));
        Position storage position = positions[positionKey];
        require(position.liquidity >= amount, "Insufficient liquidity");
        
        // 计算返还的代币数量
        (amount0, amount1) = _getAmountsForLiquidity(
            poolState.sqrtPriceX96,
            tickLower,
            tickUpper,
            amount
        );
        
        // 更新Tick信息
        _updateTick(tickLower, -int128(amount));
        _updateTick(tickUpper, int128(amount));
        
        // 如果当前价格在移除的区间内，更新激活流动性
        if (poolState.currentTick >= tickLower && poolState.currentTick < tickUpper) {
            poolState.liquidity -= amount;
        }
        
        // 更新用户位置
        position.liquidity -= amount;
        
        // 销毁LP代币
        _burn(msg.sender, amount);
        
        // 转出代币
        if (amount0 > 0) token0.transfer(msg.sender, amount0);
        if (amount1 > 0) token1.transfer(msg.sender, amount1);
        
        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }
    
    // ============ 内部辅助函数 ============
    
    struct SwapState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint256 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
    }
    
    struct StepComputations {
        uint256 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint256 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
    }
    
    /// @notice 根据流动性计算所需的代币数量
    /// @dev 基于Uniswap V3白皮书公式6实现
    function _getAmountsForLiquidity(
        uint256 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        uint256 sqrtRatioA = _getSqrtRatioAtTick(tickLower);
        uint256 sqrtRatioB = _getSqrtRatioAtTick(tickUpper);
        
        if (sqrtPriceX96 <= sqrtRatioA) {
            // 当前价格低于区间，只需要token0
            // amount0 = liquidity * (√Pb - √Pa) / (√Pa * √Pb)
            amount0 = _getAmount0ForLiquidity(sqrtRatioA, sqrtRatioB, liquidity);
        } else if (sqrtPriceX96 < sqrtRatioB) {
            // 当前价格在区间内，需要两种代币
            // amount0 = liquidity * (√Pb - √P) / (√P * √Pb)
            // amount1 = liquidity * (√P - √Pa)
            amount0 = _getAmount0ForLiquidity(sqrtPriceX96, sqrtRatioB, liquidity);
            amount1 = _getAmount1ForLiquidity(sqrtRatioA, sqrtPriceX96, liquidity);
        } else {
            // 当前价格高于区间，只需要token1
            // amount1 = liquidity * (√Pb - √Pa)
            amount1 = _getAmount1ForLiquidity(sqrtRatioA, sqrtRatioB, liquidity);
        }
    }
    
    /// @notice 计算token0数量
    function _getAmount0ForLiquidity(
        uint256 sqrtRatioAX96,
        uint256 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        return uint256(liquidity) * (sqrtRatioBX96 - sqrtRatioAX96) / sqrtRatioBX96 / sqrtRatioAX96 * Q96;
    }
    
    /// @notice 计算token1数量
    function _getAmount1ForLiquidity(
        uint256 sqrtRatioAX96,
        uint256 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        return uint256(liquidity) * (sqrtRatioBX96 - sqrtRatioAX96) / Q96;
    }
    
    /// @notice 更新Tick信息
    function _updateTick(int24 tick, int128 liquidityDelta) internal {
        TickInfo storage tickInfo = ticks[tick];
        
        uint128 liquidityGrossBefore = tickInfo.liquidityGross;
        uint128 liquidityGrossAfter = liquidityDelta < 0
            ? liquidityGrossBefore - uint128(-liquidityDelta)
            : liquidityGrossBefore + uint128(liquidityDelta);
        
        require(liquidityGrossAfter <= type(uint128).max, "Liquidity overflow");
        
        tickInfo.liquidityGross = liquidityGrossAfter;
        tickInfo.liquidityNet += liquidityDelta;
        
        if (liquidityGrossBefore == 0) {
            tickInfo.initialized = true;
        }
    }
    
    /// @notice 根据平方根价格计算Tick
    function _getTickAtSqrtRatio(uint256 sqrtPriceX96) internal pure returns (int24 tick) {
        // 简化实现：使用对数计算
        // 实际实现会使用更精确的二分查找
        require(sqrtPriceX96 >= 4295128739 && sqrtPriceX96 <= 1461446703485210103287273052203988822378723970342, "Price out of range");
        
        // 这里使用简化的计算方法
        // 实际应该使用: tick = log_1.0001(price) = log(price) / log(1.0001)
        uint256 ratio = sqrtPriceX96 * sqrtPriceX96 / Q96;
        
        // 简化的Tick计算（实际需要更精确的实现）
        if (ratio >= 2**128) {
            tick = int24(int256(ratio / 2**128));
        } else {
            tick = -int24(int256(2**128 / ratio));
        }
        
        // 确保在有效范围内
        if (tick < MIN_TICK) tick = MIN_TICK;
        if (tick > MAX_TICK) tick = MAX_TICK;
    }
    
    /// @notice 根据Tick计算平方根价格
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint256 sqrtPriceX96) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of range");
        
        // 简化实现：√P = 1.0001^(tick/2)
        // 实际实现会使用更精确的计算
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        
        // 使用简化的幂运算
        sqrtPriceX96 = Q96;
        if (absTick > 0) {
            // 简化计算：每个tick对应√1.0001的变化
            for (uint256 i = 0; i < absTick && i < 100; i++) {
                sqrtPriceX96 = sqrtPriceX96 * TICK_BASE / 1e18;
            }
        }
        
        if (tick < 0) {
            sqrtPriceX96 = Q96 * Q96 / sqrtPriceX96;
        }
    }
    
    /// @notice 找到下一个初始化的Tick
    function _nextInitializedTickWithinOneWord(
        int24 tick,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        // 简化实现：线性搜索附近的Tick
        if (lte) {
            for (int24 i = tick; i >= tick - 256 && i >= MIN_TICK; i--) {
                if (ticks[i].initialized) {
                    return (i, true);
                }
            }
            return (MIN_TICK, false);
        } else {
            for (int24 i = tick + 1; i <= tick + 256 && i <= MAX_TICK; i++) {
                if (ticks[i].initialized) {
                    return (i, true);
                }
            }
            return (MAX_TICK, false);
        }
    }
    
    /// @notice 计算单步交换
    function _computeSwapStep(
        uint256 sqrtRatioCurrentX96,
        uint256 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining
    ) internal pure returns (
        uint256 sqrtRatioNextX96,
        uint256 amountIn,
        uint256 amountOut
    ) {
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        bool exactIn = amountRemaining >= 0;
        
        if (exactIn) {
            uint256 amountRemainingLessFeee = uint256(amountRemaining) * (1000000 - FEE) / 1000000;
            amountIn = zeroForOne
                ? _getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : _getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            
            if (amountRemainingLessFeee >= amountIn) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = _getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFeee,
                    zeroForOne
                );
            }
        } else {
            amountOut = zeroForOne
                ? _getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : _getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            
            if (uint256(-amountRemaining) >= amountOut) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = _getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    uint256(-amountRemaining),
                    zeroForOne
                );
            }
        }
        
        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;
        
        if (zeroForOne) {
            amountIn = max && exactIn
                ? amountIn
                : _getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : _getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            amountIn = max && exactIn
                ? amountIn
                : _getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : _getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }
        
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }
        
        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            amountIn = uint256(amountRemaining) - amountIn * FEE / (1000000 - FEE);
        }
    }
    
    // 简化的价格计算辅助函数
    function _getAmount0Delta(
        uint256 sqrtRatioAX96,
        uint256 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        
        uint256 numerator1 = uint256(liquidity) << 96;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;
        
        return numerator1 * numerator2 / sqrtRatioBX96 / sqrtRatioAX96;
    }
    
    function _getAmount1Delta(
        uint256 sqrtRatioAX96,
        uint256 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        
        return uint256(liquidity) * (sqrtRatioBX96 - sqrtRatioAX96) / Q96;
    }
    
    function _getNextSqrtPriceFromInput(
        uint256 sqrtPX96,
        uint128 liquidity,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (uint256) {
        require(sqrtPX96 > 0, "Invalid sqrt price");
        require(liquidity > 0, "Invalid liquidity");
        
        if (zeroForOne) {
            uint256 product = amountIn * sqrtPX96;
            if (product / amountIn == sqrtPX96) {
                uint256 denominator = uint256(liquidity) << 96;
                if (product <= denominator) {
                    return sqrtPX96 - product / denominator;
                }
            }
            return sqrtPX96 - amountIn / liquidity;
        } else {
            return sqrtPX96 + (amountIn << 96) / liquidity;
        }
    }
    
    function _getNextSqrtPriceFromOutput(
        uint256 sqrtPX96,
        uint128 liquidity,
        uint256 amountOut,
        bool zeroForOne
    ) internal pure returns (uint256) {
        require(sqrtPX96 > 0, "Invalid sqrt price");
        require(liquidity > 0, "Invalid liquidity");
        
        if (zeroForOne) {
            return sqrtPX96 + (amountOut << 96) / liquidity;
        } else {
            uint256 product = amountOut * sqrtPX96;
            require(product / amountOut == sqrtPX96, "Overflow");
            uint256 denominator = uint256(liquidity) << 96;
            require(product < denominator, "Insufficient liquidity");
            return sqrtPX96 - product / denominator;
        }
    }
    
    // ============ 查询函数 ============
    
    /// @notice 获取当前池状态
    function getPoolState() external view returns (
        uint128 liquidity,
        uint256 sqrtPriceX96,
        int24 currentTick
    ) {
        return (poolState.liquidity, poolState.sqrtPriceX96, poolState.currentTick);
    }
    
    /// @notice 获取用户位置信息
    function getPosition(
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (Position memory) {
        bytes32 positionKey = keccak256(abi.encodePacked(owner, tickLower, tickUpper));
        return positions[positionKey];
    }
}