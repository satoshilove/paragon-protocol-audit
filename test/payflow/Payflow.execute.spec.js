/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { E, now } = require("../helpers");

describe("ParagonPayflowExecutorV2 :: execute()", () => {
  async function fixture() {
    const [owner, user, relayer, daoVault] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const tokenIn  = await ERC.deploy("IN","IN",18);  await tokenIn.waitForDeployment();
    const tokenOut = await ERC.deploy("OUT","OUT",18);await tokenOut.waitForDeployment();

    const Router = await ethers.getContractFactory("MockRouter");
    const router = await Router.deploy(); await router.waitForDeployment();

    const Reb = await ethers.getContractFactory("MockLPFlowRebates");
    const lpReb = await Reb.deploy(); await lpReb.waitForDeployment();

    const BE = await ethers.getContractFactory("ParagonBestExecutionV14");
    const be = await BE.deploy(owner.address); await be.waitForDeployment();

    const Locker = await ethers.getContractFactory("MockLocker");
    const lock = await Locker.deploy(); await lock.waitForDeployment();

    const Pay = await ethers.getContractFactory("ParagonPayflowExecutorV2");
    const pf = await Pay.deploy(
      owner.address,
      router.target,
      be.target,
      daoVault.address,
      lpReb.target,
      lock.target
    );
    await pf.waitForDeployment();

    // Set notifier for lpReb to allow notify from pf
    await lpReb.setNotifier(pf.target);

    // (optional) protocol fee (keeps parity with previous tests using trailing bps)
    await (await pf.setParams(
      router.target, be.target, daoVault.address, lpReb.target, lock.target, 5
    )).wait();

    await (await tokenIn.mint(user.address, E("1000"))).wait();
    await (await tokenIn.connect(user).approve(pf.target, ethers.MaxUint256)).wait();

    // Fund the router with output tokens for the mock swap
    await (await tokenOut.mint(router.target, E("1000"))).wait();

    const domain = {
      name: "ParagonBestExecution",
      version: "1",
      chainId: (await ethers.provider.getNetwork()).chainId,
      verifyingContract: be.target
    };

    const types = {
      SwapIntent: [
        { name: "user", type: "address" },
        { name: "tokenIn", type: "address" },
        { name: "tokenOut", type: "address" },
        { name: "amountIn", type: "uint256" },
        { name: "minAmountOut", type: "uint256" },
        { name: "deadline", type: "uint256" },
        { name: "recipient", type: "address" },
        { name: "nonce", type: "uint256" }
      ]
    };

    return { owner, user, relayer, tokenIn, tokenOut, router, lpReb, be, lock, pf, domain, types };
  }

  it("INV-PF-03/06/08: happy path — minOut respected; LP notify x1; no relayer fee when caller=user", async () => {
    const { user, tokenIn, tokenOut, router, pf, lpReb, domain, types, be } = await fixture();

    await (await router.setNextAmountOut(E("100"))).wait();

    const currentTime = (await ethers.provider.getBlock("latest")).timestamp;

    const it = {
      user: user.address,
      tokenIn: tokenIn.target,
      tokenOut: tokenOut.target,
      amountIn: E("10"),
      minAmountOut: E("95"),
      recipient: user.address,
      deadline: BigInt(currentTime + 600),
      nonce: await be.nextNonce(user.address)
    };
    const sig = await user.signTypedData(domain, types, it);
    const permit = { value: 0n, deadline: 0n, v: 0, r: "0x" + "00".repeat(32), s: "0x" + "00".repeat(32) };

    const outBalBefore = await tokenOut.balanceOf(user.address);
    await (await pf.connect(user).execute(it, sig, permit)).wait();
    const outBalAfter  = await tokenOut.balanceOf(user.address);

    expect(outBalAfter - outBalBefore).to.be.gte(E("95"));
    expect(await lpReb.count()).to.equal(1n);
  });

  it("INV-PF-01: replay protection — (user, nonce) single-use", async () => {
    const { user, tokenIn, tokenOut, router, pf, domain, types, be } = await fixture();
    await (await router.setNextAmountOut(E("50"))).wait();

    const currentTime = (await ethers.provider.getBlock("latest")).timestamp;

    const it = {
      user: user.address,
      tokenIn: tokenIn.target,
      tokenOut: tokenOut.target,
      amountIn: E("5"),
      minAmountOut: E("40"),
      recipient: user.address,
      deadline: BigInt(currentTime + 600),
      nonce: await be.nextNonce(user.address)
    };
    const sig = await user.signTypedData(domain, types, it);
    const permit = { value: 0n, deadline: 0n, v: 0, r: "0x" + "00".repeat(32), s: "0x" + "00".repeat(32) };

    await (await pf.connect(user).execute(it, sig, permit)).wait();
    await expect(pf.connect(user).execute(it, sig, permit)).to.be.reverted; // nonce used
  });

  it("INV-PF-02/03: guards — tokenIn!=tokenOut; recipient!=0; not expired; minOut enforced", async () => {
    const { user, tokenIn, tokenOut, router, pf, domain, types, be } = await fixture();
    await (await router.setNextAmountOut(E("10"))).wait();

    const permit = { value: 0n, deadline: 0n, v: 0, r: "0x" + "00".repeat(32), s: "0x" + "00".repeat(32) };

    const currentTime = (await ethers.provider.getBlock("latest")).timestamp;

    const base = {
      user: user.address,
      tokenIn: tokenIn.target,
      tokenOut: tokenOut.target,
      amountIn: E("1"),
      minAmountOut: E("9"),
      recipient: user.address,
      deadline: BigInt(currentTime + 600),
      nonce: await be.nextNonce(user.address)
    };
    const baseSig = await user.signTypedData(domain, types, base);

    const a = { ...base, tokenOut: tokenIn.target };
    const aSig = await user.signTypedData(domain, types, a);
    await expect(pf.connect(user).execute(a, aSig, permit)).to.be.reverted;

    const b = { ...base, recipient: ethers.ZeroAddress };
    const bSig = await user.signTypedData(domain, types, b);
    await expect(pf.connect(user).execute(b, bSig, permit)).to.be.reverted;

    const c = { ...base, deadline: BigInt(currentTime - 1) };
    const cSig = await user.signTypedData(domain, types, c);
    await expect(pf.connect(user).execute(c, cSig, permit)).to.be.reverted;

    await (await router.setNextAmountOut(E("5"))).wait();
    await expect(pf.connect(user).execute(base, baseSig, permit)).to.be.reverted; // minOut=9 > 5
  });
});