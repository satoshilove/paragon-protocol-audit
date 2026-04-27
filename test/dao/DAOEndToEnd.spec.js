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

describe("DAO end-to-end wiring @spec", () => {
  it("RevenueRouter -> FeeDistributorERC20 -> finalize -> claim", async () => {
    const [owner, user] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const reward = await ERC.deploy("XPGN", "XPGN", 18);
    await reward.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(reward.target, owner.address);
    await ve.waitForDeployment();

    const FD = await ethers.getContractFactory("FeeDistributorERC20");
    const feeDistributor = await FD.deploy(reward.target, ve.target, owner.address);
    await feeDistributor.waitForDeployment();

    const Trader = await ethers.getContractFactory("contracts/mocks/MockTraderRewardsNotify.sol:MockTraderRewardsNotify");
    const traderSink = await Trader.deploy(reward.target);
    await traderSink.waitForDeployment();

    const Router = await ethers.getContractFactory("RevenueRouter");
    const router = await Router.deploy(owner.address, feeDistributor.target, owner.address, traderSink.target, 10000, 0, 0);
    await router.waitForDeployment();

    await feeDistributor.setRewardNotifier(router.target, true);

    await reward.mint(user.address, E("100"));
    await reward.connect(user).approve(ve.target, ethers.MaxUint256);
    await ve.connect(user).create_lock(E("100"), Number(ceilWeek((await latestTs()) + 40 * WEEK)));

    for (let i = 0; i < 13; i++) await toNextWeek();

    const fundedWeek = BigInt(Math.floor((await latestTs()) / WEEK) * WEEK);
    await reward.mint(router.target, E("50"));
    await router["distribute(address,uint256)"](reward.target, 1);

    await toNextWeek();
    const weeks = [];
    for (let i = 11n; i >= 0n; i--) weeks.push(fundedWeek - i * BigInt(WEEK));
    await feeDistributor.batchFinalize(weeks);

    const before = await reward.balanceOf(user.address);
    await feeDistributor.connect(user).claim(user.address);
    const after = await reward.balanceOf(user.address);
    expect(after - before).to.be.gt(0n);
  });

  it("RevenueRouter -> TraderRewardsLocker -> finalize -> claim -> VoterEscrow lock", async () => {
    const [owner, user] = await ethers.getSigners();

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

    const FDMock = await ethers.getContractFactory("contracts/mocks/MockFeeDistributorNotify.sol:MockFeeDistributorNotify");
    const feeSink = await FDMock.deploy(xpgn.target);
    await feeSink.waitForDeployment();

    const Router = await ethers.getContractFactory("RevenueRouter");
    const router = await Router.deploy(owner.address, feeSink.target, owner.address, locker.target, 0, 0, 10000);
    await router.waitForDeployment();

    await locker.setRewardNotifier(router.target, true);
    await ve.setRewardDepositor(locker.target, true);

    const epoch = await usage.currentEpoch();
    await usage.onPayflowExecuted(user.address, E("5"), 0, ethers.ZeroHash);

    await xpgn.mint(router.target, E("25"));
    await router["distribute(address,uint256)"](xpgn.target, epoch);

    await ff(WEEK + 2);
    await locker.finalizeEpoch(epoch);
    await locker.connect(user).claim(epoch);

    const lock = await ve.locked(user.address);
    expect(lock[0]).to.equal(E("25"));
    expect(lock[1]).to.be.gt(0n);
  });
});
