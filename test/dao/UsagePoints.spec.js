/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const E = (n) => ethers.parseEther(n);

describe("UsagePoints @spec", () => {
  it("INV-UP-02: only authorized callers can award", async () => {
    const [owner, caller, u1] = await ethers.getSigners();
    const U = await ethers.getContractFactory("UsagePoints");
    const u = await U.deploy(owner.address); await u.waitForDeployment();

    await u.setCaller(caller.address, true);

    await expect(u.onPayflowExecuted(u1.address, E("1"), 0, ethers.ZeroHash)).to.be.reverted;
    await u.connect(caller).onPayflowExecuted(u1.address, E("1"), 0, ethers.ZeroHash);

    const ep = await u.currentEpoch();
    expect(await u.pointsOf(u1.address, ep)).to.equal(E("1")); // weightVolBips defaults to 100%
  });

  it("INV-UP-01: points are monotonic unless explicit burn", async () => {
    const [owner, caller, u1] = await ethers.getSigners();
    const U = await ethers.getContractFactory("UsagePoints");
    const u = await U.deploy(owner.address); await u.waitForDeployment();

    await u.setCaller(caller.address, true);

    // Award twice → points should strictly increase (no cap enforced in current spec/impl)
    await u.connect(caller).onPayflowExecuted(u1.address, E("1"), 0, ethers.ZeroHash);
    await u.connect(caller).onPayflowExecuted(u1.address, E("2"), 0, ethers.ZeroHash);

    const ep = await u.currentEpoch();
    expect(await u.pointsOf(u1.address, ep)).to.equal(E("3"));
  });
});
