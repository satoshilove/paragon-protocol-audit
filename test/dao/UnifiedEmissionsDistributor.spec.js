/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const WEEK = 7 * 24 * 60 * 60;

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}

describe("UnifiedEmissionsDistributor @spec", () => {
  it("uses finalized previous epoch, funds allocated only, and scopes farm approval", async () => {
    const [owner, treasury] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    const LP = await ERC.deploy("LP", "LP", 18);
    await X.waitForDeployment();
    await LP.waitForDeployment();

    const G = await ethers.getContractFactory("SimpleGauge");
    const simpleGauge = await G.deploy(LP.target, X.target, ethers.ZeroAddress, owner.address);
    await simpleGauge.waitForDeployment();

    const Farm = await ethers.getContractFactory("contracts/mocks/MockFarmNotify.sol:MockFarmNotify");
    const farm = await Farm.deploy();
    await farm.waitForDeployment();

    const Controller = await ethers.getContractFactory("contracts/mocks/MockGaugeControllerFinal.sol:MockGaugeControllerFinal");
    const controller = await Controller.deploy();
    await controller.waitForDeployment();

    const g1 = simpleGauge.target;
    const g2 = ethers.Wallet.createRandom().address;

    await controller.setCurrentEpoch(5);
    await controller.setEpochFinalized(4, true);
    await controller.setGaugeList([g1, g2]);
    await controller.setGaugeWeight(4, g1, 7000);
    await controller.setGaugeWeight(4, g2, 3000);
    await controller.setTotalWeight(4, 10000);

    const D = await ethers.getContractFactory("UnifiedEmissionsDistributor");
    const dist = await D.deploy(X.target, controller.target, farm.target, owner.address);
    await dist.waitForDeployment();

    await dist.setWeeklyEmission(E("100"));
    await dist.setFundingMode(false, treasury.address);
    await dist.mapGauge(g1, 0, true);
    await dist.mapGauge(g2, 7, false);

    await X.mint(treasury.address, E("100"));
    await X.connect(treasury).approve(dist.target, E("100"));
    await simpleGauge.setMinter(dist.target);

    await ff(WEEK + 2);

    await expect(dist.kick()).to.emit(dist, "EmissionsPushed");

    expect(await X.balanceOf(simpleGauge.target)).to.equal(E("70"));
    expect(await farm.lastPid()).to.equal(7n);
    expect(await farm.lastAmount()).to.equal(E("30"));

    await expect(dist.kick()).to.be.revertedWith("already pushed this week");
  });

  it("reverts if a weighted gauge is unmapped", async () => {
    const [owner] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    const Farm = await ethers.getContractFactory("contracts/mocks/MockFarmNotify.sol:MockFarmNotify");
    const farm = await Farm.deploy();
    await farm.waitForDeployment();

    const Controller = await ethers.getContractFactory("contracts/mocks/MockGaugeControllerFinal.sol:MockGaugeControllerFinal");
    const controller = await Controller.deploy();
    await controller.waitForDeployment();

    const g = ethers.Wallet.createRandom().address;
    await controller.setCurrentEpoch(3);
    await controller.setEpochFinalized(2, true);
    await controller.setGaugeList([g]);
    await controller.setGaugeWeight(2, g, 10000);
    await controller.setTotalWeight(2, 10000);

    const D = await ethers.getContractFactory("UnifiedEmissionsDistributor");
    const dist = await D.deploy(X.target, controller.target, farm.target, owner.address);
    await dist.waitForDeployment();

    await dist.setWeeklyEmission(E("100"));
    await ff(WEEK + 2);

    await expect(dist.kick()).to.be.revertedWith("unmapped weighted gauge");
  });
});