const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const { deadline, now } = require("../helpers");

async function getERCFactory() {
  const candidates = [
    "contracts/exchange/MockERC20.sol:MockERC20",
    "exchange/MockERC20.sol:MockERC20",
    "contracts/mocks/MockERC20.sol:MockERC20",
    "mocks/MockERC20.sol:MockERC20",
    "MockERC20",
  ];
  for (const fq of candidates) {
    try { return await ethers.getContractFactory(fq); } catch {}
  }
  throw new Error("MockERC20 artifact not found.");
}

async function getWethFactory() {
  const candidates = [
    "contracts/exchange/WETH9.sol:WETH9",
    "exchange/WETH9.sol:WETH9",
    "WETH9",
  ];
  for (const fq of candidates) {
    try { return await ethers.getContractFactory(fq); } catch {}
  }
  throw new Error("WETH9 artifact not found.");
}

async function deployRouterAuto(factoryAddr, wethAddr, deployer) {
  const Router = await ethers.getContractFactory("ParagonRouter");
  try { const r = await Router.deploy(factoryAddr, wethAddr); await r.waitForDeployment(); return r; } catch {}
  try { const r = await Router.deploy(factoryAddr, wethAddr, ethers.ZeroAddress); await r.waitForDeployment(); return r; } catch {}
  const r = await Router.deploy(factoryAddr, wethAddr, deployer.address);
  await r.waitForDeployment();
  return r;
}

// Try different tails for swapExactTokensForTokens to match your Router ABI.
function isNoFragmentErr(e) { return e && e.code === 'UNSUPPORTED_OPERATION'; }
async function swapExactTokensForTokensCompat(router, amountIn, minOut, path, to, ddl) {
  const tries = [
    [amountIn, minOut, path, to, ddl],                              // classic 5
    [amountIn, minOut, path, to, ddl, 0],                           // + uint
    [amountIn, minOut, path, to, ddl, ethers.ZeroAddress],          // + address
    [amountIn, minOut, path, to, ddl, 0, ethers.ZeroAddress],       // + uint, address
    [amountIn, minOut, path, to, ddl, ethers.ZeroAddress, 0],       // + address, uint
    [amountIn, minOut, path, to, ddl, false],                       // + bool
    [amountIn, minOut, path, to, ddl, false, ethers.ZeroAddress],   // + bool, address
    [amountIn, minOut, path, to, ddl, ethers.ZeroAddress, false],   // + address, bool
  ];
  let lastNoFrag;
  for (const args of tries) {
    try { return await router.swapExactTokensForTokens(...args); }
    catch (e) {
      if (isNoFragmentErr(e)) { lastNoFrag = e; continue; }
      throw e; // real revert should bubble for .to.be.reverted
    }
  }
  throw lastNoFrag || new Error("No compatible swapExactTokensForTokens overload found.");
}

describe("ParagonRouter @spec", function () {
  it("INV-RO-01/02: deadline + minOut enforced; add/remove liquidity roundtrip", async function () {
    const [u] = await ethers.getSigners();

    const WETH = await getWethFactory();
    const weth = await WETH.deploy(); await weth.waitForDeployment();

    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(u.address, ethers.ZeroAddress); await fac.waitForDeployment();

    const router = await deployRouterAuto(await fac.getAddress(), await weth.getAddress(), u);
    const routerAddr = await router.getAddress();

    const ERC = await getERCFactory();
    const T0 = await ERC.deploy("T0", "T0", 18);
    const T1 = await ERC.deploy("T1", "T1", 18);
    await T0.waitForDeployment(); await T1.waitForDeployment();

    const t0 = await T0.getAddress(); const t1 = await T1.getAddress();
    await (await T0.mint(u.address, E("100000"))).wait();
    await (await T1.mint(u.address, E("100000"))).wait();
    await (await T0.approve(routerAddr, ethers.MaxUint256)).wait();
    await (await T1.approve(routerAddr, ethers.MaxUint256)).wait();

    await (await router.addLiquidity(t0, t1, E("1000"), E("1000"), 0n, 0n, u.address, deadline())).wait();

    // expired → revert
    await expect(
      swapExactTokensForTokensCompat(router, E("1"), 0n, [t0, t1], u.address, BigInt((await now()) - 1))
    ).to.be.reverted;

    // impossible minOut → revert
    await expect(
      swapExactTokensForTokensCompat(router, E("1"), ethers.MaxUint256, [t0, t1], u.address, deadline())
    ).to.be.reverted;

    // LP remove should burn LP
    const lpAddr = await fac.getPair(t0, t1);
    const LP = await ethers.getContractAt("ParagonPair", lpAddr);
    const before = await LP.balanceOf(u.address);
    await (await LP.approve(routerAddr, ethers.MaxUint256)).wait();
    await (await router.removeLiquidity(t0, t1, (await LP.balanceOf(u.address)) / 2n, 0n, 0n, u.address, deadline())).wait();
    const after = await LP.balanceOf(u.address);
    expect(after).to.be.lt(before);
  });
});
