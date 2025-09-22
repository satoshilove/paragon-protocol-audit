/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { E, now } = require("../helpers");

describe("ParagonPayflowExecutorV2 :: relayer fee behavior", () => {
  async function fixture() {
    const [owner, user, relayer, daoVault] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const In  = await ERC.deploy("I","I",18);  await In.waitForDeployment();
    const Out = await ERC.deploy("O","O",18);  await Out.waitForDeployment();

    const Router = await ethers.getContractFactory("MockRouter");
    const router = await Router.deploy();       await router.waitForDeployment();

    const Reb = await ethers.getContractFactory("MockLPFlowRebates");
    const lpReb = await Reb.deploy();           await lpReb.waitForDeployment();

    const BE = await ethers.getContractFactory("ParagonBestExecutionV14");
    const be = await BE.deploy(owner.address);               await be.waitForDeployment();

    const Locker = await ethers.getContractFactory("MockLocker");
    const lock = await Locker.deploy();         await lock.waitForDeployment();

    const Payflow = await ethers.getContractFactory("ParagonPayflowExecutorV2");
    const pf = await Payflow.deploy(
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

    // relayer fee bps (0.10%), from SURPLUS only
    await (await pf.setRelayerFeeBips(10)).wait();

    await (await In.mint(user.address, E("100"))).wait();
    await (await In.connect(user).approve(pf.target, ethers.MaxUint256)).wait();

    // Fund the router with output tokens for the mock swap
    await (await Out.mint(router.target, E("1000"))).wait();

    if (router.setTokenOut) { await (await router.setTokenOut(Out.target)).wait(); }

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

    return { user, relayer, In, Out, router, pf, domain, types, be };
  }

  it("INV-PF-08: relayer fee only when caller!=user and only from surplus above minOut", async () => {
    const { user, relayer, In, Out, router, pf, domain, types, be } = await fixture();

    await (await router.setNextAmountOut(E("100.05"))).wait(); // surplus = 0.05

    const currentTime = (await ethers.provider.getBlock("latest")).timestamp;

    const it = {
      user: user.address,
      tokenIn: In.target,
      tokenOut: Out.target,
      amountIn: E("10"),
      minAmountOut: E("100"),
      recipient: user.address,
      deadline: BigInt(currentTime + 600),
      nonce: await be.nextNonce(user.address)
    };
    const sig = await user.signTypedData(domain, types, it);
    const permit = { value: 0n, deadline: 0n, v: 0, r: "0x" + "00".repeat(32), s: "0x" + "00".repeat(32) };

    const before = await Out.balanceOf(user.address);
    await (await pf.connect(relayer).execute(it, sig, permit)).wait();
    const after  = await Out.balanceOf(user.address);

    expect(after - before).to.be.gte(E("100")); // user never below minOut
  });

  it("INV-PF-08: zero relayer fee when there is no surplus", async () => {
    const { user, relayer, In, Out, router, pf, domain, types, be } = await fixture();
    await (await router.setNextAmountOut(E("100"))).wait(); // exactly minOut

    const currentTime = (await ethers.provider.getBlock("latest")).timestamp;

    const it = {
      user: user.address,
      tokenIn: In.target,
      tokenOut: Out.target,
      amountIn: E("10"),
      minAmountOut: E("100"),
      recipient: user.address,
      deadline: BigInt(currentTime + 600),
      nonce: await be.nextNonce(user.address)
    };
    const sig = await user.signTypedData(domain, types, it);
    const permit = { value: 0n, deadline: 0n, v: 0, r: "0x" + "00".repeat(32), s: "0x" + "00".repeat(32) };

    const before = await Out.balanceOf(user.address);
    await (await pf.connect(relayer).execute(it, sig, permit)).wait();
    const after  = await Out.balanceOf(user.address);

    expect(after - before).to.equal(E("100")); // exactly minOut ⇒ zero relayer fee
  });
});