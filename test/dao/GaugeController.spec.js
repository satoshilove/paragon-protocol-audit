/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const WEEK = 7 * 24 * 60 * 60;

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}

describe("GaugeController @spec", () => {
  let owner, user, other, ve, usage, gc, g0, g1, g2;

  beforeEach(async () => {
    [owner, user, other] = await ethers.getSigners();

    const Ve = await ethers.getContractFactory("contracts/mocks/MockVeVotes.sol:MockVeVotes");
    ve = await Ve.deploy();
    await ve.waitForDeployment();

    const Usage = await ethers.getContractFactory("contracts/mocks/MockUsageMultiplier.sol:MockUsageMultiplier");
    usage = await Usage.deploy();
    await usage.waitForDeployment();

    const GC = await ethers.getContractFactory("GaugeController");
    gc = await GC.deploy(ve.target, usage.target, owner.address);
    await gc.waitForDeployment();

    g0 = ethers.Wallet.createRandom().address;
    g1 = ethers.Wallet.createRandom().address;
    g2 = ethers.Wallet.createRandom().address;

    await gc.addGauge(g0);
    await gc.addGauge(g1);
    await gc.addGauge(g2);

    await ve.setBalance(user.address, E("1000"));
  });

  it("INV-GC-01/05: only owner manages gauges; removed gauge stays historical but inactive", async () => {
    const ghost = ethers.Wallet.createRandom().address;
    await expect(gc.connect(other).addGauge(ghost)).to.be.reverted;
    await expect(gc.connect(other).removeGauge(g0)).to.be.reverted;

    await gc.removeGauge(g0);
    expect(await gc.isGauge(g0)).to.equal(false);

    const first = await gc.gaugesAt(0);
    expect(first).to.equal(g0);
  });

  it("INV-GC-03/04: vote respects 100%, cooldown, and reset is blocked in closed window", async () => {
    await gc.setParams(E("250"), 10, 3600);

    await expect(gc.connect(user).vote([g0, g1], [6000, 4000]))
      .to.emit(gc, "Voted");

    const ep = await gc.epoch();
    expect(await gc.userUsedBps(ep, user.address)).to.equal(10000n);

    await expect(gc.connect(user).vote([g0], [5000])).to.be.reverted;

    await ff(3601);
    await expect(gc.connect(user).vote([g0], [7000])).to.emit(gc, "Voted");
    expect(await gc.userUsedBps(ep, user.address)).to.equal(7000n);

    await gc.setVoteWindowEndBuffer(3600);
    const block = await ethers.provider.getBlock("latest");
    const curEp = Number(await gc.epoch());
    const epochEnd = (curEp + 1) * WEEK;
    const delta = epochEnd - block.timestamp - 3599;
    if (delta > 0) await ff(delta);

    await expect(gc.connect(user).reset()).to.be.revertedWith("vote window closed");
    await expect(gc.connect(user).vote([g1], [1000])).to.be.revertedWith("vote window closed");
  });

  it("INV-GC-02/06: finalization copies weights and total from historical gauges", async () => {
    // Make this deterministic: no end-window restriction during setup vote
    await gc.setVoteWindowEndBuffer(0);

    await gc.connect(user).vote([g0, g1], [5500, 4500]);
    const ep = await gc.epoch();

    await gc.removeGauge(g1);

    await ff(WEEK + 2);
    await expect(gc.finalizeEpoch(ep)).to.emit(gc, "EpochFinalized");

    expect(await gc.gaugeWeightFinal(ep, g0)).to.equal(await gc.gaugeWeightAt(ep, g0));
    expect(await gc.gaugeWeightFinal(ep, g1)).to.equal(await gc.gaugeWeightAt(ep, g1));

    const total =
      (await gc.gaugeWeightFinal(ep, g0)) +
      (await gc.gaugeWeightFinal(ep, g1)) +
      (await gc.gaugeWeightFinal(ep, g2));

    expect(await gc.totalWeightFinal(ep)).to.equal(total);
  });
});