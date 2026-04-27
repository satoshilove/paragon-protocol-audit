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

describe("DAO deployment wiring @spec", () => {
  it("runs post-deploy role wiring and a full weekly cycle", async () => {
    const [owner, user, treasury] = await ethers.getSigners();

    // -------------------------------------------------------------------------
    // Deploy core token + LP
    // -------------------------------------------------------------------------
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    const LP = await ERC.deploy("LP", "LP", 18);
    await X.waitForDeployment();
    await LP.waitForDeployment();

    // -------------------------------------------------------------------------
    // Deploy core DAO contracts
    // -------------------------------------------------------------------------
    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    const Usage = await ethers.getContractFactory("UsagePoints");
    const usage = await Usage.deploy(owner.address);
    await usage.waitForDeployment();

    const GC = await ethers.getContractFactory("GaugeController");
    const gc = await GC.deploy(ve.target, usage.target, owner.address);
    await gc.waitForDeployment();

    // Lower governance threshold for this wiring test
    await gc.setParams(E("1"), 10, 0);

    const FD = await ethers.getContractFactory("FeeDistributorERC20");
    const fd = await FD.deploy(X.target, ve.target, owner.address);
    await fd.waitForDeployment();

    const L = await ethers.getContractFactory("TraderRewardsLocker");
    const locker = await L.deploy(owner.address, X.target, usage.target, ve.target, false);
    await locker.waitForDeployment();

    const G = await ethers.getContractFactory("SimpleGauge");
    const gauge = await G.deploy(LP.target, X.target, gc.target, owner.address);
    await gauge.waitForDeployment();

    const Farm = await ethers.getContractFactory("contracts/mocks/MockFarmNotify.sol:MockFarmNotify");
    const farm = await Farm.deploy();
    await farm.waitForDeployment();

    const UED = await ethers.getContractFactory("UnifiedEmissionsDistributor");
    const ued = await UED.deploy(X.target, gc.target, farm.target, owner.address);
    await ued.waitForDeployment();

    const Router = await ethers.getContractFactory("RevenueRouter");
    const router = await Router.deploy(
      owner.address,
      fd.target,
      treasury.address,
      locker.target,
      3000, // fee distributor
      2000, // treasury
      5000  // trader rewards
    );
    await router.waitForDeployment();

    // -------------------------------------------------------------------------
    // Post-deploy wiring
    // -------------------------------------------------------------------------
    await fd.setRewardNotifier(router.target, true);
    await locker.setRewardNotifier(router.target, true);
    await ve.setRewardDepositor(locker.target, true);

    await gauge.setMinter(ued.target);
    await ued.setWeeklyEmission(E("100"));
    await ued.setFundingMode(false, treasury.address);

    await gc.addGauge(gauge.target);
    await ued.mapGauge(gauge.target, 0, true);

    await usage.setCaller(owner.address, true);

    // -------------------------------------------------------------------------
    // User gets LP and ve lock
    // -------------------------------------------------------------------------
    await LP.mint(user.address, E("1000"));
    await LP.connect(user).approve(gauge.target, ethers.MaxUint256);

    await X.mint(user.address, E("500"));
    await X.connect(user).approve(ve.target, ethers.MaxUint256);

    const unlock = (await latestTs()) + 40 * WEEK;
    await ve.connect(user).create_lock(E("100"), unlock);

    await ff(2);
    if (typeof ve.checkpoint === "function") {
      await ve.checkpoint();
    }

    expect(await ve.balanceOf(user.address)).to.be.gt(0n);

    // -------------------------------------------------------------------------
    // Epoch E: vote
    // -------------------------------------------------------------------------
    const epochE = await gc.epoch();
    await gc.connect(user).vote([gauge.target], [10_000]);

    expect(await gc.gaugeWeightAt(epochE, gauge.target)).to.be.gt(0n);

    // -------------------------------------------------------------------------
    // Move into epoch E+1 and finalize E
    // -------------------------------------------------------------------------
    await toNextWeek();
    expect(await gc.epoch()).to.equal(epochE + 1n);

    await gc.finalizeEpoch(epochE);
    expect(await gc.totalWeightFinal(epochE)).to.be.gt(0n);

    // -------------------------------------------------------------------------
    // While current epoch is E+1, kick should use sourceEp = E
    // -------------------------------------------------------------------------
    await X.mint(treasury.address, E("100"));
    await X.connect(treasury).approve(ued.target, E("100"));

    await expect(ued.kick()).to.emit(ued, "EmissionsPushed");
    expect(await X.balanceOf(gauge.target)).to.equal(E("100"));

    // -------------------------------------------------------------------------
    // Stake LP before second reward cycle
    // -------------------------------------------------------------------------
    await gauge.connect(user).stake(E("100"));

    // -------------------------------------------------------------------------
    // Epoch E+1: vote again
    // -------------------------------------------------------------------------
    const epochE1 = await gc.epoch();
    await gc.connect(user).vote([gauge.target], [10_000]);

    // Move into epoch E+2 and finalize E+1
    await toNextWeek();
    expect(await gc.epoch()).to.equal(epochE1 + 1n);

    await gc.finalizeEpoch(epochE1);

    // Kick again while current epoch is E+2, so sourceEp = E+1
    await X.mint(treasury.address, E("100"));
    await X.connect(treasury).approve(ued.target, E("100"));

    await expect(ued.kick()).to.emit(ued, "EmissionsPushed");

    await ff(WEEK / 2);

    const gaugeRewardBefore = await X.balanceOf(user.address);
    await gauge.connect(user).getReward();
    const gaugeRewardAfter = await X.balanceOf(user.address);

    expect(gaugeRewardAfter - gaugeRewardBefore).to.be.gt(0n);

    // -------------------------------------------------------------------------
    // RevenueRouter -> FeeDistributorERC20 flow
    // -------------------------------------------------------------------------
    await X.mint(router.target, E("50"));

    const feeEpoch = await gc.epoch();
    await expect(
      router["distribute(address,uint256)"](X.target, feeEpoch)
    ).to.emit(router, "Distributed");

    const feeWeek = BigInt(Math.floor((await latestTs()) / WEEK) * WEEK);

    await toNextWeek();
    await fd.finalizeEpoch(feeWeek);

    expect(await fd.epochRewards(feeWeek)).to.be.gt(0n);

    // -------------------------------------------------------------------------
    // RevenueRouter -> TraderRewardsLocker -> claim -> ve lock flow
    // -------------------------------------------------------------------------
    const traderEpoch = await usage.currentEpoch();
    await usage.onPayflowExecuted(user.address, E("10"), 0, ethers.ZeroHash);

    await X.mint(router.target, E("40"));
    await expect(
      router["distribute(address,uint256)"](X.target, traderEpoch)
    ).to.emit(router, "Distributed");

    await toNextWeek();

    // Match existing lock policy for this test
    await locker.setLockConfig(4, 52, 0);
    await locker.finalizeEpoch(traderEpoch);

    const lockBefore = await ve.locked(user.address);
    await locker.connect(user).claim(traderEpoch);
    const lockAfter = await ve.locked(user.address);

    expect(lockAfter[0]).to.be.gt(lockBefore[0]);
  });
});