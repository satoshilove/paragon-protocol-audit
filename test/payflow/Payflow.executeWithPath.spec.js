/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { E, now } = require("../helpers");

describe("ParagonPayflowExecutorV2 :: executeWithPath()", () => {
  async function fixture() {
    const [owner, user, daoVault] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const A = await ERC.deploy("A","A",18); await A.waitForDeployment();
    const B = await ERC.deploy("B","B",18); await B.waitForDeployment();
    const C = await ERC.deploy("C","C",18); await C.waitForDeployment();

    const Router = await ethers.getContractFactory("MockRouter");
    const router = await Router.deploy(); await router.waitForDeployment();

    const Reb = await ethers.getContractFactory("MockLPFlowRebates");
    const lpReb = await Reb.deploy(); await lpReb.waitForDeployment();

    const BE = await ethers.getContractFactory("ParagonBestExecutionV14");
    const be = await BE.deploy(owner.address); await be.waitForDeployment();

    const Locker = await ethers.getContractFactory("MockLocker");
    const lock = await Locker.deploy(); await lock.waitForDeployment();

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

    await (await A.mint(user.address, E("1000"))).wait();
    await (await A.connect(user).approve(pf.target, ethers.MaxUint256)).wait();

    // Fund the router with output tokens for the mock swap
    await (await C.mint(router.target, E("1000"))).wait();

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

    return { user, A, B, C, router, pf, lpReb, be, domain, types };
  }

  it("INV-PF-02a/06: validates path (start/end, length) and per-hop shares sum to 10000", async () => {
    const { user, A, B, C, router, pf, lpReb, domain, types, be } = await fixture();
    await (await router.setNextAmountOut(E("90"))).wait();

    const path = [A.target, B.target, C.target]; // 2 hops → A->B, B->C
    const shares = [4000, 6000];                 // length = path.length - 1, sum = 10000

    const currentTime = (await ethers.provider.getBlock("latest")).timestamp;

    const it = {
      user: user.address,
      tokenIn: A.target,
      tokenOut: C.target,
      amountIn: E("10"),
      minAmountOut: E("80"),
      recipient: user.address,
      deadline: BigInt(currentTime + 600),
      nonce: await be.nextNonce(user.address)
    };
    const sig = await user.signTypedData(domain, types, it);
    const permit = { value: 0n, deadline: 0n, v: 0, r: "0x" + "00".repeat(32), s: "0x" + "00".repeat(32) };

    await (await pf.connect(user).executeWithPath(it, sig, path, shares, permit)).wait();
    expect(await lpReb.count()).to.equal(2n);

    const bad1 = [C.target, B.target, C.target]; // wrong first hop
    await expect(pf.connect(user).executeWithPath(it, sig, bad1, shares, permit)).to.be.reverted;

    const bad2 = [A.target, B.target, A.target]; // wrong last hop
    await expect(pf.connect(user).executeWithPath(it, sig, bad2, shares, permit)).to.be.reverted;

    const badShares = [5000, 3000]; // sum != 10000
    await expect(pf.connect(user).executeWithPath(it, sig, path, badShares, permit)).to.be.reverted;
  });
});