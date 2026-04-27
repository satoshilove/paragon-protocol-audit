/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const WEEK = 7 * 24 * 60 * 60;

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}

describe("TraderRewardsLocker @spec", () => {
  it("freezes budget, only notifier finalizes, and users claim once into ve locks", async () => {
    const [owner, notifier, alice, bob, other] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    const U = await ethers.getContractFactory("UsagePoints");
    const usage = await U.deploy(owner.address);
    await usage.waitForDeployment();
    await usage.setCaller(owner.address, true);

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    const L = await ethers.getContractFactory("TraderRewardsLocker");
    const locker = await L.deploy(owner.address, X.target, usage.target, ve.target, false);
    await locker.waitForDeployment();

    await locker.setRewardNotifier(notifier.address, true);
    await ve.setRewardDepositor(locker.target, true);

    const epoch = await usage.currentEpoch();

    // points in current epoch
    await usage.onPayflowExecuted(alice.address, E("60"), 0, ethers.ZeroHash);
    await usage.onPayflowExecuted(bob.address, E("40"), 0, ethers.ZeroHash);

    await X.mint(notifier.address, E("100"));
    await X.connect(notifier).approve(locker.target, E("100"));
    await expect(locker.connect(notifier).notifyRewardAmount(epoch, E("100")))
      .to.emit(locker, "BudgetNotified");

    // outsider cannot finalize
    await ff(WEEK + 2);
    await expect(locker.connect(other).finalizeEpoch(epoch)).to.be.revertedWith("not notifier");

    await expect(locker.connect(notifier).finalizeEpoch(epoch))
      .to.emit(locker, "EpochFinalized");

    // funding after finalization blocked
    await X.mint(notifier.address, E("1"));
    await X.connect(notifier).approve(locker.target, E("1"));
    await expect(locker.connect(notifier).notifyRewardAmount(epoch, E("1")))
      .to.be.revertedWith("epoch finalized");

    // alice claim ~= 60, bob ~= 40
    await expect(locker.connect(alice).claim(epoch)).to.emit(locker, "Claimed");
    await expect(locker.connect(bob).claim(epoch)).to.emit(locker, "Claimed");

    await expect(locker.connect(alice).claim(epoch)).to.be.revertedWith("already claimed");

    const lockAlice = await ve.locked(alice.address);
    const lockBob = await ve.locked(bob.address);

    expect(lockAlice[0]).to.equal(E("60"));
    expect(lockBob[0]).to.equal(E("40"));
  });

  it("top-up path requires existing lock to satisfy min reward lock", async () => {
    const [owner, notifier, user] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    const U = await ethers.getContractFactory("UsagePoints");
    const usage = await U.deploy(owner.address);
    await usage.waitForDeployment();
    await usage.setCaller(owner.address, true);

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    const L = await ethers.getContractFactory("TraderRewardsLocker");
    const locker = await L.deploy(owner.address, X.target, usage.target, ve.target, false);
    await locker.waitForDeployment();

    await locker.setRewardNotifier(notifier.address, true);
    await ve.setRewardDepositor(locker.target, true);

    // user creates a short-ish lock that will be valid but shorter than min reward lock after a bit of time
    await X.mint(user.address, E("10"));
    await X.connect(user).approve(ve.target, E("10"));
    await ve.connect(user).create_lock(E("10"), (await ethers.provider.getBlock("latest")).timestamp + 5 * WEEK);

    const epoch = await usage.currentEpoch();
    await usage.onPayflowExecuted(user.address, E("1"), 0, ethers.ZeroHash);

    await X.mint(notifier.address, E("5"));
    await X.connect(notifier).approve(locker.target, E("5"));
    await locker.connect(notifier).notifyRewardAmount(epoch, E("5"));

    await ff(WEEK + 2);
    await locker.connect(notifier).finalizeEpoch(epoch);

    await expect(locker.connect(user).claim(epoch)).to.be.revertedWith("existing lock too short");
  });
});
