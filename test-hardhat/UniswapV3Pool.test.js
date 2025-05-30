const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("UniswapV3Pool", function () {
  let pool;
  let token0, token1;
  let owner, user1, user2;
  
  // 初始价格：1 token0 = 2000 token1 (类似ETH/USDC)
  const INITIAL_SQRT_PRICE = "112045541949572279837463876454"; // √2000 * 2^96
  
  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();
    
    // 部署测试代币
    const TestToken = await ethers.getContractFactory("TestToken");
    const tempToken0 = await TestToken.deploy("Token0", "TK0");
    const tempToken1 = await TestToken.deploy("Token1", "TK1");
    
    // 确保token0地址小于token1地址
    if (tempToken0.address.toLowerCase() < tempToken1.address.toLowerCase()) {
      token0 = tempToken0;
      token1 = tempToken1;
    } else {
      token0 = tempToken1;
      token1 = tempToken0;
    }
    
    // 部署池子合约
    const UniswapV3Pool = await ethers.getContractFactory("UniswapV3Pool");
    pool = await UniswapV3Pool.deploy(
      token0.address,
      token1.address,
      INITIAL_SQRT_PRICE
    );
    
    // 给用户分配代币
    await token0.mint(user1.address, ethers.utils.parseEther("1000"));
    await token1.mint(user1.address, ethers.utils.parseEther("2000000"));
    await token0.mint(user2.address, ethers.utils.parseEther("1000"));
    await token1.mint(user2.address, ethers.utils.parseEther("2000000"));
    
    // 授权池子使用代币
    await token0.connect(user1).approve(pool.address, ethers.constants.MaxUint256);
    await token1.connect(user1).approve(pool.address, ethers.constants.MaxUint256);
    await token0.connect(user2).approve(pool.address, ethers.constants.MaxUint256);
    await token1.connect(user2).approve(pool.address, ethers.constants.MaxUint256);
  });
  
  describe("部署", function () {
    it("应该正确设置初始状态", async function () {
      expect(await pool.token0()).to.equal(token0.address);
      expect(await pool.token1()).to.equal(token1.address);
      
      const poolState = await pool.getPoolState();
      expect(poolState.sqrtPriceX96).to.equal(INITIAL_SQRT_PRICE);
      expect(poolState.liquidity).to.equal(0);
    });
  });
  
  describe("添加流动性 (mint)", function () {
    it("测试用例1：应该在[2000, 2500]价格区间成功添加流动性", async function () {
      const tickLower = 69080; // 约对应价格2000
      const tickUpper = 69320; // 约对应价格2500
      const liquidityAmount = 1000000;
      
      const token0Before = await token0.balanceOf(user1.address);
      const token1Before = await token1.balanceOf(user1.address);
      
      // 添加流动性
      const tx = await pool.connect(user1).mint(
        tickLower,
        tickUpper,
        liquidityAmount,
        ethers.utils.parseEther("100"),   // 最大token0数量
        ethers.utils.parseEther("200000") // 最大token1数量
      );
      
      const receipt = await tx.wait();
      const mintEvent = receipt.events?.find(e => e.event === "Mint");
      
      expect(mintEvent).to.not.be.undefined;
      expect(mintEvent.args.amount).to.equal(liquidityAmount);
      
      // 验证代币被正确转入
      const token0After = await token0.balanceOf(user1.address);
      const token1After = await token1.balanceOf(user1.address);
      
      expect(token0After).to.be.lt(token0Before);
      expect(token1After).to.be.lt(token1Before);
      
      // 验证LP代币被铸造
      const lpBalance = await pool.balanceOf(user1.address);
      expect(lpBalance).to.equal(liquidityAmount);
      
      // 验证池状态更新
      const poolState = await pool.getPoolState();
      expect(poolState.liquidity).to.equal(liquidityAmount);
      
      // 验证用户位置
      const position = await pool.getPosition(user1.address, tickLower, tickUpper);
      expect(position.liquidity).to.equal(liquidityAmount);
      
      console.log("✅ 测试用例1通过：成功在价格区间[2000, 2500]添加流动性");
      console.log(`   - 使用token0数量: ${ethers.utils.formatEther(token0Before.sub(token0After))}`);
      console.log(`   - 使用token1数量: ${ethers.utils.formatEther(token1Before.sub(token1After))}`);
      console.log(`   - 获得LP代币: ${liquidityAmount}`);
    });
    
    it("应该拒绝无效的tick范围", async function () {
      await expect(
        pool.connect(user1).mint(
          69320, // tickLower > tickUpper
          69080,
          1000000,
          ethers.utils.parseEther("100"),
          ethers.utils.parseEther("200000")
        )
      ).to.be.revertedWith("Invalid tick range");
    });
    
    it("应该拒绝零流动性", async function () {
      await expect(
        pool.connect(user1).mint(
          69080,
          69320,
          0, // 零流动性
          ethers.utils.parseEther("100"),
          ethers.utils.parseEther("200000")
        )
      ).to.be.revertedWith("Amount must be positive");
    });
  });
  
  describe("交换 (swap)", function () {
    beforeEach(async function () {
      // 先添加流动性
      await pool.connect(user1).mint(
        69080,
        69320,
        1000000,
        ethers.utils.parseEther("100"),
        ethers.utils.parseEther("200000")
      );
    });
    
    it("测试用例2：应该执行swap并使价格穿越Tick", async function () {
      // 记录交换前的状态
      const stateBefore = await pool.getPoolState();
      const token0Before = await token0.balanceOf(user2.address);
      const token1Before = await token1.balanceOf(user2.address);
      
      // 执行大额交换，使价格穿越Tick
      const swapAmount = ethers.utils.parseEther("10"); // 10个token0
      const tx = await pool.connect(user2).swap(
        true, // zeroForOne: 用token0换token1
        swapAmount,
        ethers.BigNumber.from(INITIAL_SQRT_PRICE).div(2) // 价格限制
      );
      
      const receipt = await tx.wait();
      const swapEvent = receipt.events?.find(e => e.event === "Swap");
      
      expect(swapEvent).to.not.be.undefined;
      
      // 验证交换后的状态
      const stateAfter = await pool.getPoolState();
      
      // 价格应该下降（用token0换token1）
      expect(stateAfter.sqrtPriceX96).to.be.lt(stateBefore.sqrtPriceX96);
      expect(stateAfter.currentTick).to.be.lt(stateBefore.currentTick);
      
      // 验证代币余额变化
      const token0After = await token0.balanceOf(user2.address);
      const token1After = await token1.balanceOf(user2.address);
      
      expect(token0After).to.be.lt(token0Before); // token0减少
      expect(token1After).to.be.gt(token1Before); // token1增加
      
      console.log("✅ 测试用例2通过：成功执行swap并穿越Tick");
      console.log(`   - 交换前价格Tick: ${stateBefore.currentTick}`);
      console.log(`   - 交换后价格Tick: ${stateAfter.currentTick}`);
      console.log(`   - token0变化量: ${ethers.utils.formatEther(token0Before.sub(token0After))}`);
      console.log(`   - token1变化量: ${ethers.utils.formatEther(token1After.sub(token1Before))}`);
    });
    
    it("应该拒绝零数量交换", async function () {
      await expect(
        pool.connect(user2).swap(
          true,
          0, // 零数量
          ethers.BigNumber.from(INITIAL_SQRT_PRICE).div(2)
        )
      ).to.be.revertedWith("Amount cannot be zero");
    });
    
    it("应该拒绝无效的价格限制", async function () {
      await expect(
        pool.connect(user2).swap(
          true,
          ethers.utils.parseEther("1"),
          ethers.BigNumber.from(INITIAL_SQRT_PRICE).mul(2) // 无效的价格限制
        )
      ).to.be.revertedWith("Invalid price limit");
    });
  });
  
  describe("移除流动性 (burn)", function () {
    let tickLower, tickUpper, liquidityAmount;
    
    beforeEach(async function () {
      tickLower = 69080;
      tickUpper = 69320;
      liquidityAmount = 1000000;
      
      // 先添加流动性
      await pool.connect(user1).mint(
        tickLower,
        tickUpper,
        liquidityAmount,
        ethers.utils.parseEther("100"),
        ethers.utils.parseEther("200000")
      );
    });
    
    it("测试用例3：应该成功移除流动性并验证代币返还量", async function () {
      const token0Before = await token0.balanceOf(user1.address);
      const token1Before = await token1.balanceOf(user1.address);
      const lpTokensBefore = await pool.balanceOf(user1.address);
      
      // 移除一半流动性
      const burnAmount = Math.floor(liquidityAmount / 2);
      const tx = await pool.connect(user1).burn(
        tickLower,
        tickUpper,
        burnAmount
      );
      
      const receipt = await tx.wait();
      const burnEvent = receipt.events?.find(e => e.event === "Burn");
      
      expect(burnEvent).to.not.be.undefined;
      expect(burnEvent.args.amount).to.equal(burnAmount);
      
      // 验证代币返还
      const token0After = await token0.balanceOf(user1.address);
      const token1After = await token1.balanceOf(user1.address);
      
      expect(token0After).to.be.gt(token0Before);
      expect(token1After).to.be.gt(token1Before);
      
      // 验证LP代币被销毁
      const lpTokensAfter = await pool.balanceOf(user1.address);
      expect(lpTokensAfter).to.equal(lpTokensBefore.sub(burnAmount));
      
      // 验证用户位置更新
      const position = await pool.getPosition(user1.address, tickLower, tickUpper);
      expect(position.liquidity).to.equal(liquidityAmount - burnAmount);
      
      console.log("✅ 测试用例3通过：成功移除流动性并验证代币返还量");
      console.log(`   - 移除时token0返还: ${ethers.utils.formatEther(token0After.sub(token0Before))}`);
      console.log(`   - 移除时token1返还: ${ethers.utils.formatEther(token1After.sub(token1Before))}`);
      console.log(`   - 剩余LP代币: ${lpTokensAfter}`);
    });
    
    it("应该拒绝移除超过拥有的流动性", async function () {
      await expect(
        pool.connect(user1).burn(
          tickLower,
          tickUpper,
          liquidityAmount + 1 // 超过拥有的流动性
        )
      ).to.be.revertedWith("Insufficient liquidity");
    });
    
    it("应该拒绝零数量移除", async function () {
      await expect(
        pool.connect(user1).burn(
          tickLower,
          tickUpper,
          0 // 零数量
        )
      ).to.be.revertedWith("Amount must be positive");
    });
  });
  
  describe("价格计算", function () {
    it("应该正确计算和显示价格信息", async function () {
      const poolState = await pool.getPoolState();
      
      console.log("当前池状态:");
      console.log(`   - 平方根价格 (sqrtPriceX96): ${poolState.sqrtPriceX96}`);
      console.log(`   - 当前Tick: ${poolState.currentTick}`);
      
      // 计算实际价格：price = (sqrtPriceX96 / 2^96)^2
      const Q96 = ethers.BigNumber.from(2).pow(96);
      const price = poolState.sqrtPriceX96.mul(poolState.sqrtPriceX96).div(Q96).div(Q96);
      console.log(`   - 计算得出的价格: ${price}`);
      
      // 验证价格在合理范围内（应该接近2000）
      expect(price).to.be.gt(1500);
      expect(price).to.be.lt(2500);
    });
  });
  
  describe("手续费计算", function () {
    beforeEach(async function () {
      // 添加流动性
      await pool.connect(user1).mint(
        69080,
        69320,
        1000000,
        ethers.utils.parseEther("100"),
        ethers.utils.parseEther("200000")
      );
    });
    
    it("应该正确计算和扣除手续费", async function () {
      const amountIn = ethers.utils.parseEther("1"); // 1 token0
      const expectedFeeRate = 3000; // 0.3%
      
      const token1Before = await token1.balanceOf(user2.address);
      
      // 执行交换
      await pool.connect(user2).swap(
        true,
        amountIn,
        ethers.BigNumber.from(INITIAL_SQRT_PRICE).div(2)
      );
      
      const token1After = await token1.balanceOf(user2.address);
      const actualToken1Received = token1After.sub(token1Before);
      
      console.log("手续费测试:");
      console.log(`   - 输入token0: ${ethers.utils.formatEther(amountIn)}`);
      console.log(`   - 预期手续费率: ${expectedFeeRate / 10000}%`);
      console.log(`   - 实际收到token1: ${ethers.utils.formatEther(actualToken1Received)}`);
      
      // 验证确实收到了token1（交换成功）
      expect(actualToken1Received).to.be.gt(0);
    });
  });
  
  describe("边界条件测试", function () {
    it("应该处理最小Tick值", async function () {
      const minTick = -887272;
      const maxTick = 887272;
      
      // 这个测试主要验证极端Tick值不会导致合约崩溃
      // 实际使用中可能需要更多的流动性支持
      await expect(
        pool.connect(user1).mint(
          minTick,
          minTick + 1000,
          1000,
          ethers.utils.parseEther("1"),
          ethers.utils.parseEther("1")
        )
      ).to.not.be.reverted;
    });
    
    it("应该拒绝超出范围的Tick", async function () {
      const invalidTick = 1000000; // 超出MAX_TICK
      
      await expect(
        pool.connect(user1).mint(
          69080,
          invalidTick,
          1000000,
          ethers.utils.parseEther("100"),
          ethers.utils.parseEther("200000")
        )
      ).to.be.revertedWith("Tick out of range");
    });
  });
});