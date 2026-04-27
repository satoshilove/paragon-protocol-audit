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

describe("TraderRewardsLocker rounding/dust @spec", () => {
  it("1/3/7 point split never exceeds frozen budget and dust stays bounded", async () => {
    const [owner, n, u1, u2, u3] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const xpgn = await ERC.deploy("XPGN", "XPGN", 18);
    await xpgn.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(xpgn.target, owner.address);
    await ve.waitForDeployment();

    const Usage = await ethers.getContractFactory("UsagePoints");
    const usage = await Usage.deploy(owner.address);
    await usage.waitForDeployment();
    await usage.setCaller(owner.address, true);

    const Locker = await ethers.getContractFactory("TraderRewardsLocker");
    const locker = await Locker.deploy(owner.address, xpgn.target, usage.target, ve.target, false);
    await locker.waitForDeployment();

    await locker.setRewardNotifier(n.address, true);
    await ve.setRewardDepositor(locker.target, true);

    const epoch = await usage.currentEpoch();
    await usage.onPayflowExecuted(u1.address, E("1"), 0, ethers.ZeroHash);
    await usage.onPayflowExecuted(u2.address, E("3"), 0, ethers.ZeroHash);
    await usage.onPayflowExecuted(u3.address, E("7"), 0, ethers.ZeroHash);

    await xpgn.mint(n.address, E("100"));
    await xpgn.connect(n).approve(locker.target, E("100"));
    await locker.connect(n).notifyRewardAmount(epoch, E("100"));

    await ff(WEEK + 2);
    await locker.connect(n).finalizeEpoch(epoch);

    await locker.connect(u1).claim(epoch);
    await locker.connect(u2).claim(epoch);
    await locker.connect(u3).claim(epoch);

    const l1 = (await ve.locked(u1.address))[0];
    const l2 = (await ve.locked(u2.address))[0];
    const l3 = (await ve.locked(u3.address))[0];

    const totalLocked = l1 + l2 + l3;
    const finalBudget = await locker.epochFinalBudget(epoch);

    expect(totalLocked).to.be.lte(finalBudget);
    expect(finalBudget - totalLocked).to.be.lt(11n);
    expect(l1).to.be.lt(l2);
    expect(l2).to.be.lt(l3);
  });
});
