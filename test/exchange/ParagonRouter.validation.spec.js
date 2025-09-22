const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const { deadline } = require("../helpers");

async function getERCFactory() {
  const cands = [
    "contracts/exchange/MockERC20.sol:MockERC20",
    "exchange/MockERC20.sol:MockERC20",
    "contracts/mocks/MockERC20.sol:MockERC20",
    "mocks/MockERC20.sol:MockERC20",
    "MockERC20",
  ];
  for (const fq of cands) {
    try { return await ethers.getContractFactory(fq); } catch {}
  }
  throw new Error("MockERC20 artifact not found.");
}

async function getWethFactory() {
  const cands = [
    "contracts/exchange/WETH9.sol:WETH9",
    "exchange/WETH9.sol:WETH9",
    "WETH9",
  ];
  for (const fq of cands) {
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

function isNoFragmentErr(e) { return e && e.code === 'UNSUPPORTED_OPERATION'; }
async function swapExactTokensForTokensCompat(router, amountIn, minOut, path, to, ddl) {
  const tries = [
    [amountIn, minOut, path, to, ddl],
    [amountIn, minOut, path, to, ddl, 0],
    [amountIn, minOut, path, to, ddl, ethers.ZeroAddress],
    [amountIn, minOut, path, to, ddl, 0, ethers.ZeroAddress],
    [amountIn, minOut, path, to, ddl, ethers.ZeroAddress, 0],
    [amountIn, minOut, path, to, ddl, false],
    [amountIn, minOut, path, to, ddl, false, ethers.ZeroAddress],
    [amountIn, minOut, path, to, ddl, ethers.ZeroAddress, false],
  ];
  let lastNoFrag;
  for (const args of tries) {
    try { return await router.swapExactTokensForTokens(...args); }
    catch (e) {
      if (isNoFragmentErr(e)) { lastNoFrag = e; continue; }
      throw e;
    }
  }
  throw lastNoFrag || new Error("No compatible swapExactTokensForTokens overload found.");
}

describe("ParagonRouter (validation) @spec", function () {
  it("reverts: path length < 2", async function () {
    const [u] = await ethers.getSigners();

    const WETH = await getWethFactory(); const weth = await WETH.deploy(); await weth.waitForDeployment();
    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(u.address, ethers.ZeroAddress); await fac.waitForDeployment();
    const router = await deployRouterAuto(await fac.getAddress(), await weth.getAddress(), u);

    const ERC = await getERCFactory();
    const T = await ERC.deploy("T", "T", 18); await T.waitForDeployment();
    await (await T.mint(u.address, E("10"))).wait();
    await (await T.approve(await router.getAddress(), ethers.MaxUint256)).wait();

    await expect(
      swapExactTokensForTokensCompat(router, E("1"), 0n, [await T.getAddress()], u.address, deadline())
    ).to.be.reverted;
  });

  it("reverts: path has identical consecutive tokens", async function () {
    const [u] = await ethers.getSigners();

    const WETH = await getWethFactory(); const weth = await WETH.deploy(); await weth.waitForDeployment();
    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(u.address, ethers.ZeroAddress); await fac.waitForDeployment();
    const router = await deployRouterAuto(await fac.getAddress(), await weth.getAddress(), u);

    const ERC = await getERCFactory();
    const A = await ERC.deploy("A", "A", 18);
    const B = await ERC.deploy("B", "B", 18);
    await A.waitForDeployment(); await B.waitForDeployment();

    await (await A.mint(u.address, E("10"))).wait();
    await (await A.approve(await router.getAddress(), ethers.MaxUint256)).wait();

    await expect(
      swapExactTokensForTokensCompat(router, E("1"), 0n, [await A.getAddress(), await A.getAddress(), await B.getAddress()], u.address, deadline())
    ).to.be.reverted;
  });

  it("reverts: path length > 5 (if your router enforces a max)", async function () {
    const [u] = await ethers.getSigners();

    const WETH = await getWethFactory(); const weth = await WETH.deploy(); await weth.waitForDeployment();
    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(u.address, ethers.ZeroAddress); await fac.waitForDeployment();
    const router = await deployRouterAuto(await fac.getAddress(), await weth.getAddress(), u);

    const ERC = await getERCFactory();
    const T = [];
    for (let i = 0; i < 6; i++) {
      const Ti = await ERC.deploy(`T${i}`, `T${i}`, 18);
      await Ti.waitForDeployment(); T.push(Ti);
    }
    await (await T[0].mint(u.address, E("10"))).wait();
    await (await T[0].approve(await router.getAddress(), ethers.MaxUint256)).wait();

    const path = await Promise.all(T.map(t => t.getAddress()));
    await expect(
      swapExactTokensForTokensCompat(router, E("1"), 0n, path, u.address, deadline())
    ).to.be.reverted;
  });

  it("reverts: addLiquidity with identical tokens", async function () {
    const [u] = await ethers.getSigners();
    const WETH = await getWethFactory(); const weth = await WETH.deploy(); await weth.waitForDeployment();
    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(u.address, ethers.ZeroAddress); await fac.waitForDeployment();
    const router = await deployRouterAuto(await fac.getAddress(), await weth.getAddress(), u);

    const ERC = await getERCFactory();
    const T0 = await ERC.deploy("T0", "T0", 18); await T0.waitForDeployment();
    await (await T0.mint(u.address, E("10"))).wait();
    await (await T0.approve(await router.getAddress(), ethers.MaxUint256)).wait();

    await expect(
      router.addLiquidity(await T0.getAddress(), await T0.getAddress(), E("1"), E("1"), 0n, 0n, u.address, deadline())
    ).to.be.reverted;
  });

  it("reverts: swap without allowance", async function () {
    const [u] = await ethers.getSigners();

    const WETH = await getWethFactory(); const weth = await WETH.deploy(); await weth.waitForDeployment();
    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(u.address, ethers.ZeroAddress); await fac.waitForDeployment();
    const router = await deployRouterAuto(await fac.getAddress(), await weth.getAddress(), u);

    const ERC = await getERCFactory();
    const A = await ERC.deploy("A", "A", 18);
    const B = await ERC.deploy("B", "B", 18);
    await A.waitForDeployment(); await B.waitForDeployment();

    await (await A.mint(u.address, E("1"))).wait();
    // no approval on purpose
    await expect(
      swapExactTokensForTokensCompat(router, E("1"), 0n, [await A.getAddress(), await B.getAddress()], u.address, deadline())
    ).to.be.reverted;
  });
});
