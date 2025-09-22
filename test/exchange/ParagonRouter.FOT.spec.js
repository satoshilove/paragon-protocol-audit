// test/exchange/ParagonRouter.FOT.spec.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const { deadline } = require("../helpers");

// Deploy Router handling both 2-arg and 3-arg constructors
async function deployRouterAuto(factoryAddr, wethAddr, deployer) {
  const Router = await ethers.getContractFactory("ParagonRouter");
  try {
    const r = await Router.deploy(factoryAddr, wethAddr);
    await r.waitForDeployment();
    return r;
  } catch {}
  try {
    const r = await Router.deploy(factoryAddr, wethAddr, ethers.ZeroAddress);
    await r.waitForDeployment();
    return r;
  } catch {}
  const r = await Router.deploy(factoryAddr, wethAddr, deployer.address);
  await r.waitForDeployment();
  return r;
}

describe("ParagonRouter FOT @spec", function () {
  it("INV-RO-03: supportingFeeOnTransferTokens path yields output (using non-FOT tokens)", async function () {
    const [u] = await ethers.getSigners();

    // WETH
    const WETH = await ethers.getContractFactory("contracts/exchange/WETH9.sol:WETH9");
    const weth = await WETH.deploy();
    await weth.waitForDeployment();

    // Factory (feeToSetter, xpgnToken)
    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(u.address, ethers.ZeroAddress);
    await fac.waitForDeployment();

    // Router(factory, weth[, admin])
    const router = await deployRouterAuto(await fac.getAddress(), await weth.getAddress(), u);
    const routerAddr = await router.getAddress();

    // Two *non-FOT* tokens (we only want to exercise the special path)
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const T0 = await ERC.deploy("T0", "T0", 18);
    const T1 = await ERC.deploy("T1", "T1", 18);
    await T0.waitForDeployment();
    await T1.waitForDeployment();

    // Mint & approve
    await (await T0.mint(u.address, E("100000"))).wait();
    await (await T1.mint(u.address, E("100000"))).wait();
    await (await T0.approve(routerAddr, ethers.MaxUint256)).wait();
    await (await T1.approve(routerAddr, ethers.MaxUint256)).wait();

    // Add liquidity
    await (await router.addLiquidity(
      await T0.getAddress(),
      await T1.getAddress(),
      E("1000"),
      E("1000"),
      0n, 0n,
      u.address,
      deadline()
    )).wait();

    // Use the FOT-supporting function; with standard ERC20s it should still produce output
    const before = await T1.balanceOf(u.address);
    // last arg `0` is the extra param some router versions expose (auto-yield percent); safe default
    await (await router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
      E("10"),
      1n,
      [await T0.getAddress(), await T1.getAddress()],
      u.address,
      deadline(),
      0
    )).wait();
    const after = await T1.balanceOf(u.address);
    expect(after).to.be.gt(before);
  });
});
