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
  const delta = WEEK - (ts % WEEK) + 1; // +1s nudge past the boundary
  await ff(delta);
}
async function tryCall(c, fn, ...args) {
  if (typeof c[fn] === "function") {
    const tx = await c[fn](...args);
    await tx.wait();
    return true;
  }
  return false;
}

describe("FeeDistributorERC20 @spec", () => {
  it("INV-FD-01/02: notify snapshots ve supply; single-lock user gets ~full amount on claim (≤2e13 wei drift ok)", async () => {
    const [owner, user] = await ethers.getSigners();

    // Token
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    // VoterEscrow (real)
    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    // Fee distributor
    const FD = await ethers.getContractFactory("FeeDistributorERC20");
    const fd = await FD.deploy(X.target, ve.target, owner.address);
    await fd.waitForDeployment();

    // --- IMPORTANT ORDER ---
    // 1) Nudge time a little to avoid exact boundary
    await ff(2);

    // Nudge close to the end of the current week to minimize time between lock creation and epoch snapshot
    let ts = await latestTs();
    let mod = ts % WEEK;
    const nudge = WEEK - mod - 1;
    await ff(nudge);

    // 2) Create a healthy multi-week lock BEFORE any epoch alignment
    await X.mint(user.address, E("100"));
    await X.connect(user).approve(ve.target, ethers.MaxUint256);

    // Make the unlock far enough in the future so any snapshot week we touch is < end.
    const unlock = (await latestTs()) + 8 * WEEK;
    await expect(ve.connect(user).create_lock(E("100"), unlock)).to.emit(ve, "LockCreated");

    // Optional checkpoints (no-op if function not present)
    await tryCall(ve, "checkpoint");
    await tryCall(fd, "checkpointTotalSupply");
    await tryCall(fd, "checkpointUser", user.address);

    // 3) Move to the start of the NEXT epoch and notify rewards
    await toNextWeek();
    await X.mint(owner.address, E("50"));
    await X.connect(owner).approve(fd.target, E("50"));
    await expect(fd.connect(owner).notifyRewardAmount(E("50"))).to.emit(fd, "Notified");

    // Take snapshots for funded epoch (defensive)
    await tryCall(fd, "checkpointTotalSupply");
    await tryCall(fd, "checkpointUser", user.address);

    // 4) After that epoch completes, user should receive ~all the reward
    await toNextWeek();

    const b0 = await X.balanceOf(user.address);
    await expect(fd.connect(user).claim(user.address)).to.emit(fd, "Claimed");
    const b1 = await X.balanceOf(user.address);

    const got = b1 - b0;
    const notified = E("50");
    const drift = got > notified ? got - notified : notified - got;

    // Allow small rounding drift from weekly bucketting + linear ve decay
    const MAX_DRIFT = 20_000_000_000_000n; // 2e13 wei
    expect(drift).to.lte(MAX_DRIFT);
  });

  it("INV-FD-03: pause/unpause gates claim/notify", async () => {
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

    await fd.pause();
    await expect(fd.connect(user).claim(user.address)).to.be.reverted;
    await fd.unpause();

    // also verify notify is gated by pause
    await fd.pause();
    await X.mint(owner.address, E("1"));
    await X.connect(owner).approve(fd.target, E("1"));
    await expect(fd.connect(owner).notifyRewardAmount(E("1"))).to.be.reverted;
    await fd.unpause();
  });
});