/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const E = (n) => ethers.parseEther(n);

describe("GaugeEmitterToFarmBps @spec", () => {
  it("INV-GE-01: splits exact by controller weights to farm", async () => {
    const [owner] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN","XPGN",18); await X.waitForDeployment();

    const Ctr = await ethers.getContractFactory("contracts/mocks/MockGaugeControllerLite.sol:MockGaugeControllerLite");
    const ctr = await Ctr.deploy(); await ctr.waitForDeployment();

    const g0 = ethers.Wallet.createRandom().address;
    const g1 = ethers.Wallet.createRandom().address;
    await ctr.addGauge(g0, 2500);
    await ctr.addGauge(g1, 7500);

    // Use the notifier mock (has notifyRewardAmount(pid,address,uint256) and notified(pid))
    const Farm = await ethers.getContractFactory("contracts/mocks/MockFarmNotifier.sol:MockFarmNotifier");
    const farm = await Farm.deploy(); await farm.waitForDeployment();

    // 4-arg constructor: (reward, controller, farm, owner)
    const Em = await ethers.getContractFactory("GaugeEmitterToFarmBps");
    const em = await Em.deploy(X.target, ctr.target, farm.target, owner.address);
    await em.waitForDeployment();

    await em.setPoolId(g0, 1);
    await em.setPoolId(g1, 2);

    await X.mint(owner.address, E("1000"));
    await X.connect(owner).approve(em.target, E("1000"));

    await expect(em.notifyRewardAmount(0, E("1000"))).to.emit(em, "Notified");

    expect(await X.balanceOf(farm.target)).to.equal(E("1000"));

    const I = new ethers.Interface(["function notified(uint256) view returns (uint256)"]);
    const F = new ethers.Contract(farm.target, I, ethers.provider);
    expect(await F.notified(1)).to.equal(E("250"));
    expect(await F.notified(2)).to.equal(E("750"));
  });

  it("INV-GE-02: gauges without mapping (pid=0) are skipped", async () => {
    const [owner] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN","XPGN",18); await X.waitForDeployment();

    const Ctr = await ethers.getContractFactory("contracts/mocks/MockGaugeControllerLite.sol:MockGaugeControllerLite");
    const ctr = await Ctr.deploy(); await ctr.waitForDeployment();

    const g0 = ethers.Wallet.createRandom().address; // mapped
    const g1 = ethers.Wallet.createRandom().address; // not mapped
    await ctr.addGauge(g0, 5000);
    await ctr.addGauge(g1, 5000);

    const Farm = await ethers.getContractFactory("contracts/mocks/MockFarmNotifier.sol:MockFarmNotifier");
    const farm = await Farm.deploy(); await farm.waitForDeployment();

    const Em = await ethers.getContractFactory("GaugeEmitterToFarmBps");
    const em = await Em.deploy(X.target, ctr.target, farm.target, owner.address);
    await em.waitForDeployment();

    await em.setPoolId(g0, 7); // leave g1 unmapped (pid=0)

    await X.mint(owner.address, E("100"));
    await X.connect(owner).approve(em.target, E("100"));
    await em.notifyRewardAmount(0, E("100"));

    const I = new ethers.Interface(["function notified(uint256) view returns (uint256)"]);
    const F = new ethers.Contract(farm.target, I, ethers.provider);
    expect(await F.notified(7)).to.equal(E("50"));
    expect(await F.notified(0)).to.equal(0n);
  });
});
