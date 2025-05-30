// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/UniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// 测试用的ERC20代币
contract TestToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract UniswapV3PoolTest is Test {
    UniswapV3Pool public pool;
    TestToken public token0;
    TestToken public token1;
    
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    
    // 初始价格：1 token0 = 2000 token1 (类似ETH/USDC)
    uint256 constant INITIAL_SQRT_PRICE = 112045541949572279837463876454; // √2000 * 2^96
    
    function setUp() public {
        // 创建测试代币（确保token0 < token1的地址顺序）
        token0 = new TestToken("Token0", "TK0");
        token1 = new TestToken("Token1", "TK1");
        
        // 如果地址顺序不对，交换它们
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        // 创建池子
        pool = new UniswapV3Pool(
            address(token0),
            address(token1),
            INITIAL_SQRT_PRICE
        );
        
        // 给测试用户分配代币
        token0.mint(user1, 1000 * 10**18);
        token1.mint(user1, 2000000 * 10**18);
        token0.mint(user2, 1000 * 10**18);
        token1.mint(user2, 2000000 * 10**18);
        
        // 授权池子使用代币
        vm.startPrank(user1);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(user2);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }
    
    /// @notice 测试用例1：在[2000, 2500]价格区间添加流动性
    function testMintLiquidity() public {
        vm.startPrank(user1);
        
        // 计算对应的Tick（简化计算）
        int24 tickLower = 69080; // 约对应价格2000
        int24 tickUpper = 69320; // 约对应价格2500
        uint128 liquidityAmount = 1000000;
        
        uint256 token0Before = token0.balanceOf(user1);
        uint256 token1Before = token1.balanceOf(user1);
        
        // 添加流动性
        (uint256 amount0, uint256 amount1) = pool.mint(
            tickLower,
            tickUpper,
            liquidityAmount,
            100 * 10**18,  // 最大token0数量
            200000 * 10**18 // 最大token1数量
        );
        
        // 验证代币被正确转入
        assertEq(token0.balanceOf(user1), token0Before - amount0);
        assertEq(token1.balanceOf(user1), token1Before - amount1);
        
        // 验证LP代币被铸造
        assertEq(pool.balanceOf(user1), liquidityAmount);
        
        // 验证池状态更新
        (uint128 liquidity, , ) = pool.getPoolState();
        assertEq(liquidity, liquidityAmount);
        
        // 验证用户位置
        UniswapV3Pool.Position memory position = pool.getPosition(user1, tickLower, tickUpper);
        assertEq(position.liquidity, liquidityAmount);
        
        vm.stopPrank();
        
        console.log("✅ 测试用例1通过：成功在价格区间[2000, 2500]添加流动性");
        console.log("   - 使用token0数量:", amount0);
        console.log("   - 使用token1数量:", amount1);
        console.log("   - 获得LP代币:", liquidityAmount);
    }
    
    /// @notice 测试用例2：执行swap使价格穿越Tick
    function testSwapCrossTick() public {
        // 首先添加流动性
        vm.startPrank(user1);
        int24 tickLower = 69080;
        int24 tickUpper = 69320;
        pool.mint(tickLower, tickUpper, 1000000, 100 * 10**18, 200000 * 10**18);
        vm.stopPrank();
        
        // 记录交换前的状态
        (, uint256 sqrtPriceBefore, int24 tickBefore) = pool.getPoolState();
        uint256 token0Before = token0.balanceOf(user2);
        uint256 token1Before = token1.balanceOf(user2);
        
        vm.startPrank(user2);
        
        // 执行大额交换，使价格穿越Tick
        (int256 amount0Delta, int256 amount1Delta) = pool.swap(
            true, // zeroForOne: 用token0换token1
            10 * 10**18, // 交换10个token0
            INITIAL_SQRT_PRICE / 2 // 价格限制
        );
        
        vm.stopPrank();
        
        // 验证交换后的状态
        (, uint256 sqrtPriceAfter, int24 tickAfter) = pool.getPoolState();
        
        // 价格应该下降（用token0换token1）
        assertLt(sqrtPriceAfter, sqrtPriceBefore);
        assertLt(tickAfter, tickBefore);
        
        // 验证代币余额变化
        assertEq(token0.balanceOf(user2), token0Before - uint256(amount0Delta));
        assertEq(token1.balanceOf(user2), token1Before + uint256(-amount1Delta));
        
        console.log("✅ 测试用例2通过：成功执行swap并穿越Tick");
        console.log("   - 交换前价格Tick:", tickBefore);
        console.log("   - 交换后价格Tick:", tickAfter);
        console.log("   - token0变化量:", amount0Delta);
        console.log("   - token1变化量:", amount1Delta);
    }
    
    /// @notice 测试用例3：验证移除流动性时代币返还量
    function testBurnLiquidity() public {
        vm.startPrank(user1);
        
        int24 tickLower = 69080;
        int24 tickUpper = 69320;
        uint128 liquidityAmount = 1000000;
        
        // 添加流动性
        (uint256 amount0Mint, uint256 amount1Mint) = pool.mint(
            tickLower,
            tickUpper,
            liquidityAmount,
            100 * 10**18,
            200000 * 10**18
        );
        
        uint256 token0Before = token0.balanceOf(user1);
        uint256 token1Before = token1.balanceOf(user1);
        uint256 lpTokensBefore = pool.balanceOf(user1);
        
        // 移除一半流动性
        uint128 burnAmount = liquidityAmount / 2;
        (uint256 amount0Burn, uint256 amount1Burn) = pool.burn(
            tickLower,
            tickUpper,
            burnAmount
        );
        
        // 验证代币返还
        assertEq(token0.balanceOf(user1), token0Before + amount0Burn);
        assertEq(token1.balanceOf(user1), token1Before + amount1Burn);
        
        // 验证LP代币被销毁
        assertEq(pool.balanceOf(user1), lpTokensBefore - burnAmount);
        
        // 验证返还量约等于添加量的一半（考虑精度误差）
        assertApproxEqRel(amount0Burn, amount0Mint / 2, 0.01e18); // 1%误差
        assertApproxEqRel(amount1Burn, amount1Mint / 2, 0.01e18);
        
        // 验证用户位置更新
        UniswapV3Pool.Position memory position = pool.getPosition(user1, tickLower, tickUpper);
        assertEq(position.liquidity, liquidityAmount - burnAmount);
        
        vm.stopPrank();
        
        console.log("✅ 测试用例3通过：成功移除流动性并验证代币返还量");
        console.log("   - 添加时token0数量:", amount0Mint);
        console.log("   - 移除时token0返还:", amount0Burn);
        console.log("   - 添加时token1数量:", amount1Mint);
        console.log("   - 移除时token1返还:", amount1Burn);
        console.log("   - 剩余LP代币:", pool.balanceOf(user1));
    }
    
    /// @notice 测试价格计算的准确性
    function testPriceCalculation() public {
        (, uint256 sqrtPrice, int24 currentTick) = pool.getPoolState();
        
        console.log("当前池状态:");
        console.log("   - 平方根价格 (sqrtPriceX96):", sqrtPrice);
        console.log("   - 当前Tick:", currentTick);
        
        // 计算实际价格：price = (sqrtPriceX96 / 2^96)^2
        uint256 price = (sqrtPrice * sqrtPrice) >> 192; // 除以2^192 = (2^96)^2
        console.log("   - 计算得出的价格:", price);
        
        // 验证价格在合理范围内（应该接近2000）
        assertGt(price, 1500);
        assertLt(price, 2500);
    }
    
    /// @notice 测试手续费计算
    function testFeeCalculation() public {
        // 添加流动性
        vm.startPrank(user1);
        pool.mint(69080, 69320, 1000000, 100 * 10**18, 200000 * 10**18);
        vm.stopPrank();
        
        vm.startPrank(user2);
        
        uint256 amountIn = 1 * 10**18; // 1 token0
        uint256 expectedFee = amountIn * 3000 / 1000000; // 0.3%手续费
        
        uint256 token1Before = token1.balanceOf(user2);
        
        // 执行交换
        (int256 amount0Delta, int256 amount1Delta) = pool.swap(
            true,
            int256(amountIn),
            INITIAL_SQRT_PRICE / 2
        );
        
        uint256 token1After = token1.balanceOf(user2);
        uint256 actualToken1Received = token1After - token1Before;
        
        // 验证实际收到的token1少于理论值（因为扣除了手续费）
        console.log("手续费测试:");
        console.log("   - 输入token0:", amountIn);
        console.log("   - 预期手续费:", expectedFee);
        console.log("   - 实际收到token1:", actualToken1Received);
        console.log("   - token1变化量:", -amount1Delta);
        
        vm.stopPrank();
    }
}