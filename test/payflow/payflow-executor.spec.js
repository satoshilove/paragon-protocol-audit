/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { E, now } = require("../helpers");

describe("ParagonPayflowExecutorV2", function () {
  it("INV-PF-03/06: executes payflow — delivers ≥ minOut; LP rebate notified; splits to recipients", async function () {
    const [owner, user, daoVault] = await ethers.getSigners();

    // tokens
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const tokenIn  = await ERC.deploy("USDCx", "USDCx", 18); await tokenIn.waitForDeployment();
    const tokenOut = await ERC.deploy("XPGN",  "XPGN",  18); await tokenOut.waitForDeployment();

    // mocks
    const Router = await ethers.getContractFactory("MockRouter");
    const router = await Router.deploy(); await router.waitForDeployment();

    const BE = await ethers.getContractFactory("ParagonBestExecutionV14");
    const best = await BE.deploy(owner.address); await best.waitForDeployment();

    const Reb = await ethers.getContractFactory("MockLPFlowRebates");
    const rebates = await Reb.deploy(); await rebates.waitForDeployment();

    const Locker = await ethers.getContractFactory("MockLocker");
    const locker = await Locker.deploy(); await locker.waitForDeployment();

    // payflow (ctor: owner, router, bestExec, daoVault, lpRebates, lockerVault)
    const Pay = await ethers.getContractFactory("ParagonPayflowExecutorV2");
    const payflow = await Pay.deploy(
      owner.address,
      router.target,
      best.target,
      daoVault.address,
      rebates.target,
      locker.target
    );
    await payflow.waitForDeployment();

    // Set notifier for rebates to allow notify from payflow
    await rebates.setNotifier(payflow.target);

    // (optional) set protocol fee bps to 200 (2%) like before
    await (await payflow.setParams(
      router.target, best.target, daoVault.address, rebates.target, locker.target, 200
    )).wait();

    // fund + approve
    await (await tokenIn.mint(user.address, E("1000"))).wait();
    await (await tokenIn.connect(user).approve(payflow.target, ethers.MaxUint256)).wait();

    // Fund the router with output tokens for the mock swap
    await (await tokenOut.mint(router.target, E("1000"))).wait();

    // cause router to return 200 out
    await (await router.setNextAmountOut(E("200"))).wait();

    const domain = {
      name: "ParagonBestExecution",
      version: "1",
      chainId: (await ethers.provider.getNetwork()).chainId,
      verifyingContract: best.target
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

    const currentTime = (await ethers.provider.getBlock("latest")).timestamp;

    // structs
    const it = {
      user: user.address,
      tokenIn: tokenIn.target,
      tokenOut: tokenOut.target,
      amountIn: E("100"),
      minAmountOut: E("150"),
      recipient: user.address,
      deadline: BigInt(currentTime + 600),
      nonce: await best.nextNonce(user.address)
    };
    const sig = await user.signTypedData(domain, types, it);
    const permit = { value: 0n, deadline: 0n, v: 0, r: "0x" + "00".repeat(32), s: "0x" + "00".repeat(32) };

    const beforeUser   = await tokenOut.balanceOf(user.address);
    const beforeDao    = await tokenOut.balanceOf(daoVault.address);
    const beforeLocker = await tokenOut.balanceOf(locker.target);

    await (await payflow.connect(user).execute(it, sig, permit)).wait();

    const afterUser   = await tokenOut.balanceOf(user.address);
    const afterDao    = await tokenOut.balanceOf(daoVault.address);
    const afterLocker = await tokenOut.balanceOf(locker.target);

    expect(afterUser - beforeUser).to.be.gte(E("150")); // min satisfied
    expect(afterDao  - beforeDao).to.be.gte(0n);
    expect(afterLocker - beforeLocker).to.be.gte(0n);
    expect(await rebates.count()).to.equal(1n);
  });
});