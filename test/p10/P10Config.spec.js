const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("P10 config and safety guards", function () {
  async function deployFixture() {
    const [owner, other] = await ethers.getSigners();

    const Pricing = await ethers.getContractFactory("contracts/mocks/MockP10Pricing.sol:MockP10Pricing");
    const pricing = await Pricing.deploy();
    await pricing.waitForDeployment();

    const P10 = await ethers.getContractFactory("P10Token");
    const p10 = await P10.deploy(owner.address);
    await p10.waitForDeployment();

    const Manager = await ethers.getContractFactory("P10IndexManager");
    const manager = await Manager.deploy(
      owner.address,
      await p10.getAddress(),
      await pricing.getAddress()
    );
    await manager.waitForDeployment();

    return { owner, other, pricing, p10, manager };
  }

  it("rejects zero addresses for pricing/vault/execution manager", async function () {
    const { manager } = await deployFixture();

    await expect(manager.setPricing(ethers.ZeroAddress)).to.be.revertedWith("P10: zero pricing");
    await expect(manager.setVault(ethers.ZeroAddress)).to.be.revertedWith("P10: zero vault");
    await expect(manager.setExecutionManager(ethers.ZeroAddress)).to.be.revertedWith("P10: zero exec manager");
  });

  it("caps fees and daily mint cap", async function () {
    const { manager } = await deployFixture();

    await expect(manager.setFees(101, 10)).to.be.revertedWith("P10: mint fee too high");
    await expect(manager.setFees(10, 101)).to.be.revertedWith("P10: redeem fee too high");
    await expect(manager.setMintCaps(0, 1001)).to.be.revertedWith("P10: daily cap too high");
  });

  it("only owner can unpause", async function () {
    const { manager, owner, other } = await deployFixture();

    await (await manager.setPauser(other.address)).wait();
    await (await manager.connect(other).setMintPaused(true)).wait();

    await expect(manager.connect(other).setMintPaused(false)).to.be.revertedWith("P10: only owner unpause");
    await expect(manager.connect(other).setRedeemPaused(false)).to.be.revertedWith("P10: only owner unpause");
  });
});