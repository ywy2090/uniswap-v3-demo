const { ethers } = require("hardhat");

async function main() {
  console.log("开始部署Uniswap V3 Demo合约...");
  
  // 获取部署账户
  const [deployer] = await ethers.getSigners();
  console.log("部署账户:", deployer.address);
  console.log("账户余额:", ethers.utils.formatEther(await deployer.getBalance()));
  
  // 部署测试代币
  console.log("\n部署测试代币...");
  const TestToken = await ethers.getContractFactory("TestToken");
  
  const token0 = await TestToken.deploy("Test Token 0", "TK0");
  await token0.deployed();
  console.log("Token0 部署到:", token0.address);
  
  const token1 = await TestToken.deploy("Test Token 1", "TK1");
  await token1.deployed();
  console.log("Token1 部署到:", token1.address);
  
  // 确保token0地址小于token1地址
  let finalToken0, finalToken1;
  if (token0.address.toLowerCase() < token1.address.toLowerCase()) {
    finalToken0 = token0;
    finalToken1 = token1;
  } else {
    finalToken0 = token1;
    finalToken1 = token0;
  }
  
  console.log("\n排序后的代币地址:");
  console.log("Token0 (较小地址):", finalToken0.address);
  console.log("Token1 (较大地址):", finalToken1.address);
  
  // 部署Uniswap V3池子
  console.log("\n部署Uniswap V3池子...");
  const UniswapV3Pool = await ethers.getContractFactory("UniswapV3Pool");
  
  // 初始价格：1 token0 = 2000 token1
  const initialSqrtPrice = "112045541949572279837463876454";
  
  const pool = await UniswapV3Pool.deploy(
    finalToken0.address,
    finalToken1.address,
    initialSqrtPrice
  );
  await pool.deployed();
  
  console.log("UniswapV3Pool 部署到:", pool.address);
  
  // 验证部署
  console.log("\n验证部署...");
  const poolState = await pool.getPoolState();
  console.log("初始流动性:", poolState.liquidity.toString());
  console.log("初始价格 (sqrtPriceX96):", poolState.sqrtPriceX96.toString());
  console.log("初始Tick:", poolState.currentTick.toString());
  
  console.log("\n部署完成！");
  console.log("合约地址汇总:");
  console.log("- Token0:", finalToken0.address);
  console.log("- Token1:", finalToken1.address);
  console.log("- UniswapV3Pool:", pool.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });