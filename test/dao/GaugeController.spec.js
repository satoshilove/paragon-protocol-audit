/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { timeTravel } = require("../helpers"); // chain-time helper

describe("GaugeController @spec", () => {
  it("INV-GC-04: only owner can add/remove gauges", async () => {
    const [owner, other] = await ethers.getSigners();

    const Ve = await ethers.getContractFactory("contracts/mocks/MockVeBalance.sol:MockVeBalance");
    const ve = await Ve.deploy(); await ve.waitForDeployment();

    const GC = await ethers.getContractFactory("GaugeController");
    const gc = await GC.deploy(ve.target, owner.address); await gc.waitForDeployment();

    const g = ethers.Wallet.createRandom().address;

    // non-owner cannot add/remove
    await expect(gc.connect(other).addGauge(g)).to.be.reverted;
    await expect(gc.connect(other).removeGauge(g)).to.be.reverted;

    // owner can add
    await expect(gc.addGauge(g)).to.emit(gc, "GaugeAdded").withArgs(g);

    // owner can remove
    await expect(gc.removeGauge(g)).to.emit(gc, "GaugeRemoved").withArgs(g);
  });

  it("INV-GC-01/02/03: vote respects caps, cooldown and accounting", async () => {
    const [owner, user] = await ethers.getSigners();

    // mock ve with positive balance for user
    const Ve = await ethers.getContractFactory("contracts/mocks/MockVeBalance.sol:MockVeBalance");
    const ve = await Ve.deploy(); await ve.waitForDeployment();
    await ve.setBalance(user.address, 1); // any positive ve balance

    const GC = await ethers.getContractFactory("GaugeController");
    const gc = await GC.deploy(ve.target, owner.address); await gc.waitForDeployment();

    // set up two gauges
    const g0 = ethers.Wallet.createRandom().address;
    const g1 = ethers.Wallet.createRandom().address;
    await gc.addGauge(g0);
    await gc.addGauge(g1);

    // First vote to g0 = 6000 bps (OK)
    await expect(gc.connect(user).vote_for_gauge_weights(g0, 6000)).to.not.be.reverted;

    // Cooldown: immediate re-vote on same gauge should revert
    await expect(gc.connect(user).vote_for_gauge_weights(g0, 6000)).to.be.revertedWith("cooldown");

    // Pass cooldown, then vote on g1 = 4000 bps (total=10000 OK)
    await timeTravel(7 * 24 * 3600 + 1);
    await expect(gc.connect(user).vote_for_gauge_weights(g1, 4000)).to.not.be.reverted;

    // Sum bound: attempting to set g0 to 7001 (sum 7001 + 4000 = 11001) must revert
    await timeTravel(7 * 24 * 3600 + 1);
    await expect(gc.connect(user).vote_for_gauge_weights(g0, 7001)).to.be.revertedWith("sum>100%");

    // Accounting: userUsedBps reflects current allocations (6000 + 4000)
    expect(await gc.userUsedBps(user.address)).to.equal(10000n);

    // Clear g1 vote → userUsedBps drops to 6000
    await expect(gc.connect(user).clear_vote(g1)).to.not.be.reverted;
    expect(await gc.userUsedBps(user.address)).to.equal(6000n);
  });
});
