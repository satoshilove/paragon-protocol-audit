/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { E } = require("../helpers");

describe("ParagonPayflowExecutorV2 :: sweeping", () => {
  it("ADMIN-PF-01: owner-only sweep(token) & sweepNative()", async () => {
    const [owner, other, daoVault] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const T = await ERC.deploy("T","T",18); await T.waitForDeployment();

    const Router = await ethers.getContractFactory("MockRouter");
    const router = await Router.deploy(); await router.waitForDeployment();

    const BE = await ethers.getContractFactory("ParagonBestExecutionV14");
    const be = await BE.deploy(owner.address); await be.waitForDeployment();

    const Reb = await ethers.getContractFactory("MockLPFlowRebates");
    const rebates = await Reb.deploy(); await rebates.waitForDeployment();

    const Locker = await ethers.getContractFactory("MockLocker");
    const locker = await Locker.deploy(); await locker.waitForDeployment();

    const Payflow = await ethers.getContractFactory("ParagonPayflowExecutorV2");
    const pf = await Payflow.deploy(
      owner.address,
      router.target,
      be.target,
      daoVault.address,
      rebates.target,
      locker.target
    );
    await pf.waitForDeployment();

    await (await T.mint(pf.target, E("5"))).wait();

    await expect(pf.connect(other).sweep(T.target, other.address)).to.be.reverted;
    await (await pf.sweep(T.target, owner.address)).wait();
    expect(await T.balanceOf(owner.address)).to.equal(E("5"));

    await owner.sendTransaction({ to: pf.target, value: E("1") });
    await expect(pf.connect(other).sweepNative(other.address)).to.be.reverted;
    await (await pf.sweepNative(owner.address)).wait();
  });
});