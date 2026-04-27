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
function mulberry32(seed) {
  return function () {
    let t = (seed += 0x6D2B79F5);
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function randInt(rng, min, max) {
  return Math.floor(rng() * (max - min + 1)) + min;
}

describe("Randomized trader rewards @property", () => {
  it("many users with uneven points never claim/lock above epochFinalBudget", async () => {
    const rng = mulberry32(9001);
    const [owner, notifier, ...rest] = await ethers.getSigners();
    const users = rest.slice(0, 5);

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    const U = await ethers.getContractFactory("UsagePoints");
    const usage = await U.deploy(owner.address);
    await usage.waitForDeployment();
    await usage.setCaller(owner.address, true);

    const L = await ethers.getContractFactory("TraderRewardsLocker");
    const locker = await L.deploy(owner.address, X.target, usage.target, ve.target, false);
    await locker.waitForDeployment();

    await locker.setRewardNotifier(notifier.address, true);
    await ve.setRewardDepositor(locker.target, true);
    await locker.setLockConfig(4, 52, 0);

    const epoch = await usage.currentEpoch();

    // Create long-enough existing locks and uneven points
    let totalPts = 0n;
    for (const user of users) {
      const base = randInt(rng, 1, 15);
      totalPts += BigInt(base);
      await usage.onPayflowExecuted(user.address, E(String(base)), 0, ethers.ZeroHash);

      await X.mint(user.address, E("50"));
      await X.connect(user).approve(ve.target, ethers.MaxUint256);
      await ve.connect(user).create_lock(E("10"), (await latestTs()) + 30 * WEEK);
    }

    const budget = E("101");
    await X.mint(notifier.address, budget);
    await X.connect(notifier).approve(locker.target, budget);
    await locker.connect(notifier).notifyRewardAmount(epoch, budget);

    await toNextWeek();
    await locker.connect(notifier).finalizeEpoch(epoch);

    let totalLockedIncrease = 0n;

    for (const user of users) {
      const before = await ve.locked(user.address);
      await locker.connect(user).claim(epoch);
      const after = await ve.locked(user.address);
      totalLockedIncrease += after[0] - before[0];
    }

    const finalBudget = await locker.epochFinalBudget(epoch);
    expect(totalLockedIncrease).to.be.lte(finalBudget);

    // one-claim-only invariant
    await expect(locker.connect(users[0]).claim(epoch)).to.be.revertedWith("already claimed");
  });
});
