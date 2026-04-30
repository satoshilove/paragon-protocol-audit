/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const WEEK = 7 * 24 * 60 * 60;
const DAY = 24 * 60 * 60;

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}

describe("ParagonShieldedLpIncentives @spec", () => {
  let owner, notifier, alice, bob, dao, referrer;
  let X, LP, farm, vault, ve, shield;
  const pid = 0;

  beforeEach(async () => {
    [owner, notifier, alice, bob, dao, referrer] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();
    LP = await ERC.deploy("LP", "LP", 18);
    await LP.waitForDeployment();

    const MF = await ethers.getContractFactory("contracts/mocks/MockFarmRewards.sol:MockFarmRewards");
    farm = await MF.deploy(X.target);
    await farm.waitForDeployment();
    await farm.addPool(pid, LP.target);

    await X.mint(farm.target, E("1000000"));
    await LP.mint(alice.address, E("1000"));
    await LP.mint(bob.address, E("1000"));

    const Vault = await ethers.getContractFactory("ParagonLockingVault");
    vault = await Vault.deploy(owner.address, LP.target, X.target, farm.target, pid, dao.address);
    await vault.waitForDeployment();
    await vault.setParams(30 * DAY, 90 * DAY, 180 * DAY, 11000, 14000, 18000);

    await LP.connect(alice).approve(vault.target, ethers.MaxUint256);
    await LP.connect(bob).approve(vault.target, ethers.MaxUint256);

    await vault.connect(alice).deposit(E("100"), 2, referrer.address);
    await vault.connect(bob).deposit(E("50"), 1, referrer.address);

    const VE = await ethers.getContractFactory("VoterEscrow");
    ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    const Shield = await ethers.getContractFactory("ParagonShieldedLpIncentives");
    shield = await Shield.deploy(owner.address, X.target, vault.target, ve.target, false);
    await shield.waitForDeployment();

    await shield.setRewardNotifier(notifier.address, true);
    await ve.setRewardDepositor(shield.target, true);
  });

  it("records useful-liquidity points only for active stakers and finalizes closed epochs", async () => {
    const epoch = await shield.currentEpoch();

    await expect(
      shield.connect(notifier).recordUsefulLiquidity(alice.address, E("20"), ethers.id("fill-a"))
    ).to.emit(shield, "UsefulLiquidityRecorded").withArgs(epoch, alice.address, E("20"), ethers.id("fill-a"));

    await expect(
      shield.connect(notifier).recordUsefulLiquidity(bob.address, E("10"), ethers.id("fill-b"))
    ).to.emit(shield, "UsefulLiquidityRecorded");

    expect(await shield.epochUserPoints(epoch, alice.address)).to.equal(E("20"));
    expect(await shield.epochTotalPoints(epoch)).to.equal(E("30"));

    await expect(
      shield.connect(notifier).recordUsefulLiquidity(alice.address, E("1"), ethers.id("fill-a"))
    ).to.be.revertedWith("ref used");

    await vault.connect(bob).unlockEarly(0);
    await expect(
      shield.connect(notifier).recordUsefulLiquidity(bob.address, E("5"), ethers.id("fill-c"))
    ).to.be.revertedWith("no active stake");

    await X.mint(notifier.address, E("90"));
    await X.connect(notifier).approve(shield.target, E("90"));
    await shield.connect(notifier).notifyRewardAmount(epoch, E("90"));

    await ff(WEEK + 2);
    await expect(shield.connect(notifier).finalizeEpoch(epoch))
      .to.emit(shield, "EpochFinalized")
      .withArgs(epoch, E("30"), E("90"));
  });

  it("locks finalized bonus rewards pro-rata into ve", async () => {
    const epoch = await shield.currentEpoch();

    await shield.connect(notifier).recordUsefulLiquidity(alice.address, E("60"), ethers.id("route-1"));
    await shield.connect(notifier).recordUsefulLiquidity(bob.address, E("40"), ethers.id("route-2"));

    await X.mint(notifier.address, E("100"));
    await X.connect(notifier).approve(shield.target, E("100"));
    await shield.connect(notifier).notifyRewardAmount(epoch, E("100"));

    await ff(WEEK + 2);
    await shield.connect(notifier).finalizeEpoch(epoch);

    await expect(shield.connect(alice).claim(epoch)).to.emit(shield, "Claimed");
    await expect(shield.connect(bob).claim(epoch)).to.emit(shield, "Claimed");

    const lockAlice = await ve.locked(alice.address);
    const lockBob = await ve.locked(bob.address);

    expect(lockAlice[0]).to.equal(E("60"));
    expect(lockBob[0]).to.equal(E("40"));

    await expect(shield.connect(alice).claim(epoch)).to.be.revertedWith("already claimed");
  });

  it("top-up path requires an existing lock long enough for shielded rewards", async () => {
    const epoch = await shield.currentEpoch();

    await shield.connect(notifier).recordUsefulLiquidity(alice.address, E("5"), ethers.id("route-short"));

    await X.mint(notifier.address, E("5"));
    await X.connect(notifier).approve(shield.target, E("5"));
    await shield.connect(notifier).notifyRewardAmount(epoch, E("5"));

    await X.mint(alice.address, E("10"));
    await X.connect(alice).approve(ve.target, E("10"));
    const latest = await ethers.provider.getBlock("latest");
    await ve.connect(alice).create_lock(E("10"), latest.timestamp + 5 * WEEK);

    await ff(WEEK + 2);
    await shield.connect(notifier).finalizeEpoch(epoch);

    await expect(shield.connect(alice).claim(epoch)).to.be.revertedWith("existing lock too short");
  });
});
