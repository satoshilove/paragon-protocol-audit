const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const { deadline } = require("../helpers");

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
  throw new Error("MockERC20 not found");
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
  throw new Error("WETH9 not found");
}

async function basicSetup() {
  const [u] = await ethers.getSigners();

  const WETH = await getWethFactory();
  const weth = await WETH.deploy(); await weth.waitForDeployment();

  const Factory = await ethers.getContractFactory("ParagonFactory");
  const fac = await Factory.deploy(u.address, ethers.ZeroAddress); await fac.waitForDeployment();

  const Router = await ethers.getContractFactory("ParagonRouter");
  let router;
  try { router = await Router.deploy(await fac.getAddress(), await weth.getAddress()); }
  catch { try { router = await Router.deploy(await fac.getAddress(), await weth.getAddress(), ethers.ZeroAddress); }
  catch { router = await Router.deploy(await fac.getAddress(), await weth.getAddress(), u.address); } }
  await router.waitForDeployment();

  const ERC = await getERCFactory();
  const T0 = await ERC.deploy("T0", "T0", 18);
  const T1 = await ERC.deploy("T1", "T1", 18);
  await T0.waitForDeployment(); await T1.waitForDeployment();

  await (await T0.mint(u.address, E("100000"))).wait();
  await (await T1.mint(u.address, E("100000"))).wait();
  await (await T0.approve(await router.getAddress(), ethers.MaxUint256)).wait();
  await (await T1.approve(await router.getAddress(), ethers.MaxUint256)).wait();

  await (await router.addLiquidity(
    await T0.getAddress(), await T1.getAddress(),
    E("1000"), E("1000"),
    0n, 0n, u.address, deadline()
  )).wait();

  const pairAddr = await fac.getPair(await T0.getAddress(), await T1.getAddress());
  const Pair = await ethers.getContractFactory("ParagonPair");
  const pair = Pair.attach(pairAddr);

  return { u, T0, T1, pair };
}

describe("ParagonPair (extras) @spec", function () {
  it("SKIM: returns only surplus (not reserves)", async function () {
    const { u, T0, T1, pair } = await basicSetup();

    await (await T0.transfer(await pair.getAddress(), E("5"))).wait();
    await (await T1.transfer(await pair.getAddress(), E("7"))).wait();

    const bal0Before = await T0.balanceOf(u.address);
    const bal1Before = await T1.balanceOf(u.address);

    await expect(pair.skim(u.address)).to.not.be.reverted;

    const bal0After = await T0.balanceOf(u.address);
    const bal1After = await T1.balanceOf(u.address);
    expect(bal0After - bal0Before).to.equal(E("5"));
    expect(bal1After - bal1Before).to.equal(E("7"));
  });

  it("SYNC: updates reserves up to current balances", async function () {
    const { T0, T1, pair } = await basicSetup();

    // Figure out which token is reserve0/reserve1 by address
    const tok0Addr = await pair.token0();
    const t0Addr = await T0.getAddress();
    const [tok0, tok1] = (tok0Addr.toLowerCase() === t0Addr.toLowerCase())
      ? [T0, T1] : [T1, T0];

    // Bump balances above recorded reserves *per side*
    // +30 on reserve0 token, +15 on reserve1 token
    await (await tok0.transfer(await pair.getAddress(), E("30"))).wait();
    await (await tok1.transfer(await pair.getAddress(), E("15"))).wait();

    await expect(pair.sync()).to.not.be.reverted;

    // After sync, reserves MUST equal actual balances
    const [r0, r1] = await pair.getReserves();
    const bal0 = await tok0.balanceOf(await pair.getAddress());
    const bal1 = await tok1.balanceOf(await pair.getAddress());
    expect(r0).to.equal(bal0);
    expect(r1).to.equal(bal1);
  });

  it("swap sanity: reverts on zero-in / impossible out", async function () {
    const { pair } = await basicSetup();
    await expect(pair.swap(0n, 0n, ethers.ZeroAddress, "0x")).to.be.reverted; // zero out
    await expect(pair.swap(E("1"), 0n, ethers.ZeroAddress, "0x"))
      .to.be.reverted; // asks for token0 out while not providing the opposite side in
  });
});
