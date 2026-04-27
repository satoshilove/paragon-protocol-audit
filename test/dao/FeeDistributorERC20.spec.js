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
function absDiff(a, b) {
  return a > b ? a - b : b - a;
}

describe("FeeDistributorERC20 @spec", () => {
  it("INV-FD-02/04: notify uses actual received amount and a single locker gets ~full funded week reward", async () => {
    const [owner, user] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    const FD = await ethers.getContractFactory("FeeDistributorERC20");
    const fd = await FD.deploy(X.target, ve.target, owner.address);
    await fd.waitForDeployment();

    await fd.setRewardNotifier(owner.address, true);

    // Create lock FIRST, then move forward enough weeks so the first-claim lookback
    // window is fully after lock creation.
    await X.mint(user.address, E("100"));
    await X.connect(user).approve(ve.target, ethers.MaxUint256);

    const unlock = (await latestTs()) + 40 * WEEK;
    await ve.connect(user).create_lock(E("100"), unlock);

    // Move forward 12+ weeks so the first-claim window is safe to finalize contiguously
    for (let i = 0; i < 13; i++) {
      await toNextWeek();
    }

    // Fund one target week
    const fundedWeek = BigInt(Math.floor((await latestTs()) / WEEK) * WEEK);

    await X.mint(owner.address, E("50"));
    await X.connect(owner).approve(fd.target, E("50"));
    await expect(fd.notifyRewardAmount(E("50"))).to.emit(fd, "RewardNotified");

    expect(await fd.epochRewards(fundedWeek)).to.equal(E("50"));

    // Move into the next week so fundedWeek is closed
    await toNextWeek();

    // Finalize the exact 12-week initial claim window ending at fundedWeek
    const weeks = [];
    for (let i = 11n; i >= 0n; i--) {
      weeks.push(fundedWeek - i * BigInt(WEEK));
    }
    await fd.batchFinalize(weeks);

    const b0 = await X.balanceOf(user.address);
    await expect(fd.connect(user).claim(user.address)).to.emit(fd, "Claimed");
    const b1 = await X.balanceOf(user.address);

    const got = b1 - b0;
    expect(got).to.be.gt(0n);

    // Since user is the only locker, fundedWeek should contribute almost all 50 tokens.
    // Earlier finalized weeks had zero rewards.
    const drift = absDiff(got, E("50"));
    expect(drift).to.lte(20_000_000_000_000n);
  });

  it("INV-FD-03/05: cannot finalize open week; unfinalized later week is not claimable yet", async () => {
    const [owner, user] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    const FD = await ethers.getContractFactory("FeeDistributorERC20");
    const fd = await FD.deploy(X.target, ve.target, owner.address);
    await fd.waitForDeployment();

    await fd.setRewardNotifier(owner.address, true);

    await X.mint(user.address, E("100"));
    await X.connect(user).approve(ve.target, ethers.MaxUint256);

    const unlock = (await latestTs()) + 40 * WEEK;
    await ve.connect(user).create_lock(E("100"), unlock);

    // Again move forward 12+ weeks to make the first-claim window safe
    for (let i = 0; i < 13; i++) {
      await toNextWeek();
    }

    // Fund week 1
    const week1 = BigInt(Math.floor((await latestTs()) / WEEK) * WEEK);

    await X.mint(owner.address, E("10"));
    await X.connect(owner).approve(fd.target, E("20"));
    await fd.notifyRewardAmount(E("10"));

    // Cannot finalize open week
    await expect(fd.finalizeEpoch(week1)).to.be.reverted;

    // Move forward, now week1 is closed
    await toNextWeek();
    await fd.finalizeEpoch(week1);

    // Fund week 2, but don't finalize it yet
    const week2 = BigInt(Math.floor((await latestTs()) / WEEK) * WEEK);
    await X.mint(owner.address, E("10"));
    await fd.notifyRewardAmount(E("10"));

    // Move one more week forward so week2 is closed but still unfinalized
    await toNextWeek();

    // Finalize all earlier weeks in the first-claim window EXCEPT week2
    const olderWeeks = [];
    for (let i = 11n; i >= 1n; i--) {
      olderWeeks.push(week2 - i * BigInt(WEEK));
    }
    await fd.batchFinalize(olderWeeks);

    const before = await X.balanceOf(user.address);
    await fd.connect(user).claim(user.address);
    const after = await X.balanceOf(user.address);

    const received = after - before;

    // User should have received week1 rewards only, not both funded weeks.
    expect(received).to.be.gt(0n);
    expect(received).to.be.lt(E("20"));

    // Now finalize week2 and claim again; second claim should add more
    await fd.finalizeEpoch(week2);

    const before2 = await X.balanceOf(user.address);
    await fd.connect(user).claim(user.address);
    const after2 = await X.balanceOf(user.address);

    expect(after2 - before2).to.be.gt(0n);
  });

  it("INV-FD-06 + pause gates notify/claim", async () => {
    const [owner, user] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    const FD = await ethers.getContractFactory("FeeDistributorERC20");
    const fd = await FD.deploy(X.target, ve.target, owner.address);
    await fd.waitForDeployment();

    await fd.setRewardNotifier(owner.address, true);

    await fd.pause();

    await X.mint(owner.address, E("1"));
    await X.connect(owner).approve(fd.target, E("1"));

    await expect(fd.notifyRewardAmount(E("1"))).to.be.reverted;
    await expect(fd.connect(user).claim(user.address)).to.be.reverted;
  });
});