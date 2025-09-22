/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const { deadline } = require("../helpers");

describe("ParagonZapV2 @spec", function () {
  async function setup() {
    const [u, feeSink, master] = await ethers.getSigners();

    // WNative (WETH9) — fully-qualified
    const WETH9 = await ethers.getContractFactory("contracts/exchange/WETH9.sol:WETH9");
    const weth = await WETH9.deploy();
    await weth.waitForDeployment();

    // Factory
    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(u.address, ethers.ZeroAddress);
    await fac.waitForDeployment();

    // Router (master is a dummy; auto-yield not exercised here)
    const Router = await ethers.getContractFactory("ParagonRouter");
    const router = await Router.deploy(await fac.getAddress(), await weth.getAddress(), master.address);
    await router.waitForDeployment();

    // Tokens (fully-qualified for determinism)
    const ERC = await ethers.getContractFactory("contracts/exchange/MockERC20.sol:MockERC20");
    const T0 = await ERC.deploy("T0", "T0", 18);
    const T1 = await ERC.deploy("T1", "T1", 18);
    await T0.waitForDeployment();
    await T1.waitForDeployment();

    // Mint + approvals (user -> router for LP seeding)
    await (await T0.mint(u.address, E("100000"))).wait();
    await (await T1.mint(u.address, E("100000"))).wait();
    await (await T0.approve(await router.getAddress(), ethers.MaxUint256)).wait();
    await (await T1.approve(await router.getAddress(), ethers.MaxUint256)).wait();

    // Seed a deeper pool to reduce price impact during zap’s internal swap
    await (
      await router.addLiquidity(
        await T0.getAddress(),
        await T1.getAddress(),
        E("20000"),
        E("20000"),
        0n,
        0n,
        u.address,
        await deadline(600)
      )
    ).wait();

    const lpAddr = await fac.getPair(await T0.getAddress(), await T1.getAddress());

    // Mock farm
    const Farm = await ethers.getContractFactory("MockFarm");
    const farm = await Farm.deploy();
    await farm.waitForDeployment();
    await (await farm.addPool(0, lpAddr, 1)).wait();

    // Zap
    const Zap = await ethers.getContractFactory("ParagonZapV2");
    const zap = await Zap.deploy(await router.getAddress(), await farm.getAddress(), feeSink.address);
    await zap.waitForDeployment();

    return { u, feeSink, weth, fac, router, T0, T1, lpAddr, farm, zap };
  }

  it("INV-ZP-01: zaps token0 → LP and stakes; enforces minLpOut & approvals", async function () {
    const { u, T0, farm, zap } = await setup();

    // User approves Zap to pull T0
    await (await T0.approve(await zap.getAddress(), ethers.MaxUint256)).wait();

    // Single-sided (tokenIn is token0) — zap computes split
    const params = {
      pid: 0,
      tokenIn: await T0.getAddress(),
      amountIn: E("100"),
      pathToTokenA: [],
      pathToTokenB: [],
      minLpOut: 1n,
      slippageBps: 200, // allow 2% to cover swap impact + rounding
      recipient: u.address,
      referrer: ethers.ZeroAddress,
      deadline: await deadline(600),
      autoStake: true,
      salt: ethers.ZeroHash,
    };

    const beforeStaked = await farm.userStaked(0, u.address);
    await (await zap.zapInAndStake(params)).wait();
    const afterStaked = await farm.userStaked(0, u.address);

    expect(afterStaked).to.be.gt(beforeStaked, "no LP staked");

    // Revert path (absurd minLpOut)
    const bad = { ...params, minLpOut: afterStaked - beforeStaked + 10n };
    await expect(zap.zapInAndStake(bad)).to.be.revertedWithCustomError(zap, "InsufficientOutput");
  });

  it("INV-ZP-02: returns residual dust to user (no token0/token1 stuck on Zap)", async function () {
    const { u, T0, T1, farm, zap } = await setup();

    await (await T0.approve(await zap.getAddress(), ethers.MaxUint256)).wait();

    const params = {
      pid: 0,
      tokenIn: await T0.getAddress(),
      amountIn: E("123.456789"), // odd amount to create tiny dust
      pathToTokenA: [],
      pathToTokenB: [],
      minLpOut: 1n,
      slippageBps: 200,
      recipient: u.address,
      referrer: ethers.ZeroAddress,
      deadline: await deadline(600),
      autoStake: false,
      salt: ethers.ZeroHash,
    };

    await (await zap.zapInAndStake(params)).wait();

    // Dust should be forwarded to recipient; Zap should hold none of pair tokens
    expect(await T0.balanceOf(await zap.getAddress())).to.equal(0n);
    expect(await T1.balanceOf(await zap.getAddress())).to.equal(0n);

    // And LP should be in user’s wallet (since autoStake=false)
    const lpAddr = await farm.poolLpToken(0);

    // Use fully-qualified name to avoid HH701 (duplicate artifacts)
    const LP = await ethers.getContractAt(
      "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20",
      lpAddr
    );
    expect(await LP.balanceOf(u.address)).to.be.gt(0n);
  });
});
