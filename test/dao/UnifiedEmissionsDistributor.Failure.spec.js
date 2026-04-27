/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const WEEK = 7 * 24 * 60 * 60;

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}
async function latestTs() {
  const b = await ethers.provider.getBlock("latest");
  return b.timestamp;
}
async function toNextWeek() {
  const ts = await latestTs();
  const delta = WEEK - (ts % WEEK) + 1;
  await ff(delta);
}
function ceilWeek(ts) {
  const W = BigInt(WEEK);
  return ((BigInt(ts) + W - 1n) / W) * W;
}

describe("UnifiedEmissionsDistributor failure paths @spec", () => {
  it("reverts when previous epoch is not finalized", async () => {
    const [owner] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const token = await ERC.deploy("XPGN", "XPGN", 18);
    await token.waitForDeployment();

    const Farm = await ethers.getContractFactory("contracts/mocks/MockFarmNotify.sol:MockFarmNotify");
    const farm = await Farm.deploy();
    await farm.waitForDeployment();

    const Controller = await ethers.getContractFactory("contracts/mocks/MockGaugeControllerFinal.sol:MockGaugeControllerFinal");
    const controller = await Controller.deploy();
    await controller.waitForDeployment();
    await controller.setCurrentEpoch(4);

    const Dist = await ethers.getContractFactory("UnifiedEmissionsDistributor");
    const dist = await Dist.deploy(token.target, controller.target, farm.target, owner.address);
    await dist.waitForDeployment();
    await dist.setWeeklyEmission(E("100"));

    await ff(WEEK + 2);
    await expect(dist.kick()).to.be.revertedWith("previous epoch not finalized");
  });

  it("reverts on no total weight, treasury shortfall, and unmapped weighted gauge", async () => {
    const [owner, treasury] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const token = await ERC.deploy("XPGN", "XPGN", 18);
    await token.waitForDeployment();

    const Farm = await ethers.getContractFactory("contracts/mocks/MockFarmNotify.sol:MockFarmNotify");
    const farm = await Farm.deploy();
    await farm.waitForDeployment();

    const Controller = await ethers.getContractFactory("contracts/mocks/MockGaugeControllerFinal.sol:MockGaugeControllerFinal");
    const controller = await Controller.deploy();
    await controller.waitForDeployment();

    const g = ethers.Wallet.createRandom().address;
    await controller.setCurrentEpoch(5);
    await controller.setEpochFinalized(4, true);
    await controller.setGaugeList([g]);
    await controller.setGaugeWeight(4, g, 10000);

    const Dist = await ethers.getContractFactory("UnifiedEmissionsDistributor");
    const dist = await Dist.deploy(token.target, controller.target, farm.target, owner.address);
    await dist.waitForDeployment();
    await dist.setWeeklyEmission(E("100"));

    await ff(WEEK + 2);
    await expect(dist.kick()).to.be.revertedWith("no total weight");

    await controller.setTotalWeight(4, 10000);
    await expect(dist.kick()).to.be.revertedWith("unmapped weighted gauge");

    await dist.setFundingMode(false, treasury.address);
    await dist.mapGauge(g, 0, false);
    await token.mint(treasury.address, E("99"));
    await token.connect(treasury).approve(dist.target, E("99"));
    await expect(dist.kick()).to.be.reverted;
  });
});
