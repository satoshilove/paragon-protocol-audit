const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n); 
const { deadline } = require("../helpers");

// Integer sqrt for bigint
function sqrtBI(x) {
  if (x < 0n) throw new Error("sqrt of negative");
  if (x < 2n) return x;
  let y = x, z = (x >> 1n) + 1n;
  while (z < y) { y = z; z = (x / z + z) >> 1n; }
  return y;
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

describe("Paragon protocol fee @spec", function () {
  async function deployCore() {
    const [owner, feeTo, master, user] = await ethers.getSigners();

    const WETH = await getWethFactory();
    const weth = await WETH.deploy(); await weth.waitForDeployment();

    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(owner.address, ethers.ZeroAddress);
    await fac.waitForDeployment();

    // Router constructors vary (2 or 3 args)
    const Router = await ethers.getContractFactory("ParagonRouter");
    let router;
    try { router = await Router.deploy(await fac.getAddress(), await weth.getAddress()); }
    catch { try { router = await Router.deploy(await fac.getAddress(), await weth.getAddress(), ethers.ZeroAddress); }
    catch { router = await Router.deploy(await fac.getAddress(), await weth.getAddress(), master.address); } }
    await router.waitForDeployment();

    const ERC = await getERCFactory();
    const T0 = await ERC.deploy("T0","T0",18);
    const T1 = await ERC.deploy("T1","T1",18);
    await T0.waitForDeployment(); await T1.waitForDeployment();

    // mint only to user (not owner)
    await (await T0.mint(user.address, E("100000"))).wait();
    await (await T1.mint(user.address, E("100000"))).wait();
    await (await T0.connect(user).approve(await router.getAddress(), ethers.MaxUint256)).wait();
    await (await T1.connect(user).approve(await router.getAddress(), ethers.MaxUint256)).wait();

    // seed 1000/1000
    await (await router.connect(user).addLiquidity(
      await T0.getAddress(), await T1.getAddress(),
      E("1000"), E("1000"),
      0n, 0n, user.address, deadline()
    )).wait();

    // pair
    const lpAddr = await fac.getPair(await T0.getAddress(), await T1.getAddress());
    const Pair = await ethers.getContractFactory("ParagonPair");
    const pair = Pair.attach(lpAddr);

    // read minimum liquidity if exposed, else 1000
    let MIN_LIQ = 1000n;
    try { MIN_LIQ = await pair.MINIMUM_LIQUIDITY(); } catch {}

    return { owner, feeTo, master, user, weth, fac, router, T0, T1, pair, lpAddr, MIN_LIQ };
  }

  // Gentle price move that always satisfies K: send input from the holder (user),
  // and request a tiny 1 wei out on the other side.
  async function doPriceMove(pair, tokenIn, fromSigner, wantToken0Out, amountIn = E("1")) {
    await (await tokenIn.connect(fromSigner).transfer(await pair.getAddress(), amountIn)).wait();
    const to = fromSigner.address;
    const tinyOut = 1n;
    if (wantToken0Out) {
      await (await pair.connect(fromSigner).swap(tinyOut, 0n, to, "0x")).wait();
    } else {
      await (await pair.connect(fromSigner).swap(0n, tinyOut, to, "0x")).wait();
    }
  }

  it("fee OFF → burn mints no extra LP", async function () {
    const { user, router, T0, T1, pair, MIN_LIQ } = await deployCore();

    await (await router.connect(user).addLiquidity(
      await T0.getAddress(), await T1.getAddress(),
      E("10"), E("10"), 0n, 0n, user.address, deadline()
    )).wait();

    const userLP = await pair.balanceOf(user.address);
    expect(userLP).to.be.gt(0n);

    await (await pair.connect(user).transfer(await pair.getAddress(), userLP)).wait();
    await expect(pair.connect(user).burn(user.address)).to.not.be.reverted;

    const tsAfter = await pair.totalSupply();
    expect(tsAfter).to.equal(MIN_LIQ);
  });

  it("fee ON → burn mints LP to feeTo per Uniswap formula", async function () {
    const { owner, feeTo, user, router, T0, T1, pair, fac } = await deployCore();

    await (await fac.connect(owner).setFeeTo(feeTo.address)).wait();

    // grow k a bit
    await doPriceMove(pair, T1, user, true, E("1"));

    // give user some new LP to burn
    await (await router.connect(user).addLiquidity(
      await T0.getAddress(), await T1.getAddress(),
      E("5"), E("5"), 0n, 0n, user.address, deadline()
    )).wait();

    const tsBefore = await pair.totalSupply();
    const [r0, r1] = await pair.getReserves();
    const k = r0 * r1;
    const kLast = await pair.kLast();
    expect(kLast).to.be.gt(0n);

    // formula from UniswapV2Pair
    const rootK = sqrtBI(k);
    const rootKLast = sqrtBI(kLast);
    let expectedMint = 0n;
    if (rootK > rootKLast) {
      expectedMint = (tsBefore * (rootK - rootKLast)) / (rootK * 5n + rootKLast);
    }

    const userLP = await pair.balanceOf(user.address);
    await (await pair.connect(user).transfer(await pair.getAddress(), userLP)).wait();
    await expect(pair.connect(user).burn(user.address)).to.not.be.reverted;

    const feeBal = await pair.balanceOf(feeTo.address);
    expect(feeBal).to.equal(expectedMint);
    if (expectedMint > 0n) expect(feeBal).to.be.gt(0n);
  });

  it("toggle OFF afterwards → no mint and kLast gets cleared", async function () {
    const { owner, feeTo, user, router, T0, T1, pair, fac } = await deployCore();

    await (await fac.connect(owner).setFeeTo(feeTo.address)).wait();

    await doPriceMove(pair, T0, user, false, E("2"));

    // turn OFF
    await (await fac.connect(owner).setFeeTo(ethers.ZeroAddress)).wait();

    await (await router.connect(user).addLiquidity(
      await T0.getAddress(), await T1.getAddress(),
      E("3"), E("3"), 0n, 0n, user.address, deadline()
    )).wait();

    const before = await pair.balanceOf(feeTo.address);
    const userLP = await pair.balanceOf(user.address);
    await (await pair.connect(user).transfer(await pair.getAddress(), userLP)).wait();
    await expect(pair.connect(user).burn(user.address)).to.not.be.reverted;
    const after = await pair.balanceOf(feeTo.address);

    expect(after - before).to.equal(0n);
    expect(await pair.kLast()).to.equal(0n);
  });

  it("fee ON but no k growth → no mint", async function () {
    const { owner, feeTo, user, router, T0, T1, pair, fac } = await deployCore();

    await (await fac.connect(owner).setFeeTo(feeTo.address)).wait();

    await (await router.connect(user).addLiquidity(
      await T0.getAddress(), await T1.getAddress(),
      E("10"), E("10"), 0n, 0n, user.address, deadline()
    )).wait();

    const feeBefore = await pair.balanceOf(feeTo.address);

    const userLP = await pair.balanceOf(user.address);
    await (await pair.connect(user).approve(await router.getAddress(), userLP)).wait();
    await (await router.connect(user).removeLiquidity(
      await T0.getAddress(), await T1.getAddress(),
      userLP, 0n, 0n, user.address, deadline()
    )).wait();

    const feeAfter = await pair.balanceOf(feeTo.address);
    expect(feeAfter - feeBefore).to.equal(0n);
  });
});
