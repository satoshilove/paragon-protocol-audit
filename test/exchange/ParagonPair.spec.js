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

async function setupPair() {
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
  const A = await ERC.deploy("T0","T0",18);
  const B = await ERC.deploy("T1","T1",18);
  await A.waitForDeployment(); await B.waitForDeployment();

  await (await A.mint(u.address, E("100000"))).wait();
  await (await B.mint(u.address, E("100000"))).wait();
  await (await A.approve(await router.getAddress(), ethers.MaxUint256)).wait();
  await (await B.approve(await router.getAddress(), ethers.MaxUint256)).wait();

  await (await router.addLiquidity(
    await A.getAddress(), await B.getAddress(),
    E("1000"), E("1000"),
    0n, 0n, u.address, deadline()
  )).wait();

  const pairAddr = await fac.getPair(await A.getAddress(), await B.getAddress());
  const Pair = await ethers.getContractFactory("ParagonPair");
  const pair = Pair.attach(pairAddr);

  // map to reserve order
  const token0Addr = (await pair.token0()).toLowerCase();
  const Aaddr = (await A.getAddress()).toLowerCase();
  const [T0, T1] = token0Addr === Aaddr ? [A, B] : [B, A];

  return { u, T0, T1, pair };
}

// gentle price nudge that *always* respects K: send 1 token of the input side,
// request exactly 1 wei on the *other* side.
async function nudgePrice(pair, T_in, toSigner) {
  await (await T_in.connect(toSigner).transfer(await pair.getAddress(), E("1"))).wait();

  const token0 = (await pair.token0()).toLowerCase();
  const inIs0 = (await T_in.getAddress()).toLowerCase() === token0;
  const to = toSigner.address;

  // if we sent token0 in, ask for 1 wei token1 out; else 1 wei token0 out
  if (inIs0) {
    await (await pair.connect(toSigner).swap(0n, 1n, to, "0x")).wait();
  } else {
    await (await pair.connect(toSigner).swap(1n, 0n, to, "0x")).wait();
  }
}

describe("ParagonPair @spec", function () {
  it("INV-EX-01/02: k after swap ≥ before; sync can't set below balances", async function () {
    const { u, T0, T1, pair } = await setupPair();

    // K before
    const [r0a, r1a] = await pair.getReserves();
    const kBefore = r0a * r1a;

    // move price a hair in a safe way
    await nudgePrice(pair, T0, u);

    // K after
    const [r0b, r1b] = await pair.getReserves();
    const kAfter = r0b * r1b;

    // invariant should not decrease
    expect(kAfter).to.be.gte(kBefore);

    // Now push extra token0 directly and sync — reserves must match balances
    await (await T0.transfer(await pair.getAddress(), E("15"))).wait();
    await expect(pair.sync()).to.not.be.reverted;

    const [r0c, r1c] = await pair.getReserves();
    const bal0 = await T0.balanceOf(await pair.getAddress());
    const bal1 = await T1.balanceOf(await pair.getAddress());
    expect(r0c).to.equal(bal0);
    expect(r1c).to.equal(bal1);
  });
});
