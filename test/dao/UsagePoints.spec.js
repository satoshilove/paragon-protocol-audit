/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const DAY = 24 * 60 * 60;

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}

describe("UsagePoints @spec", () => {
  it("INV-UP-01/03: only callers can accrue and points write into current epoch", async () => {
    const [owner, caller, user] = await ethers.getSigners();
    const U = await ethers.getContractFactory("UsagePoints");
    const u = await U.deploy(owner.address);
    await u.waitForDeployment();

    await expect(u.onPayflowExecuted(user.address, E("1"), 0, ethers.ZeroHash)).to.be.revertedWith("not notifier");
    await u.setCaller(caller.address, true);
    await u.connect(caller).onPayflowExecuted(user.address, E("1"), 0, ethers.ZeroHash);

    const ep = await u.currentEpoch();
    expect(await u.pointsOf(user.address, ep)).to.equal(E("1"));
  });

  it("INV-UP-02/04/05/06: daily caps apply, usage score is bounded, decay never increases", async () => {
    const [owner, caller, user] = await ethers.getSigners();
    const U = await ethers.getContractFactory("UsagePoints");
    const u = await U.deploy(owner.address);
    await u.waitForDeployment();

    await u.setCaller(caller.address, true);
    await u.setDailyCaps(E("1"), E("1"), E("1"), E("1"), E("1"), E("1"), E("2"));

    await u.connect(caller).onPayflowExecuted(user.address, E("1"), 0, ethers.ZeroHash);
    await u.connect(caller).onPayflowExecuted(user.address, E("10"), 0, ethers.ZeroHash); // capped / ignored above limit

    const ep = await u.currentEpoch();
    expect(await u.pointsOf(user.address, ep)).to.equal(E("1"));

    const before = await u.usageScoreOf(user.address);
    await u.setDecayParams(0, 700);
    await ff(DAY + 2);
    await u.applyDecay(user.address);
    const after = await u.usageScoreOf(user.address);

    expect(after).to.lte(before);
    const mult = await u.multiplierBps(user.address);
    expect(mult).to.be.gte(2500n);
    expect(mult).to.be.lte(15000n);
  });
});
