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

describe("FeeDistributorERC20 multi-user @spec", () => {
  it("distributes rewards proportionally across 3 lockers", async () => {
    const [owner, a, b, c] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const token = await ERC.deploy("XPGN", "XPGN", 18);
    await token.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(token.target, owner.address);
    await ve.waitForDeployment();

    const FD = await ethers.getContractFactory("FeeDistributorERC20");
    const fd = await FD.deploy(token.target, ve.target, owner.address);
    await fd.waitForDeployment();
    await fd.setRewardNotifier(owner.address, true);

    for (const [acct, amt] of [[a, "100"], [b, "200"], [c, "300"]]) {
      await token.mint(acct.address, E(amt));
      await token.connect(acct).approve(ve.target, ethers.MaxUint256);
      await ve.connect(acct).create_lock(E(amt), Number(ceilWeek((await latestTs()) + 50 * WEEK)));
    }

    for (let i = 0; i < 13; i++) await toNextWeek();
    const fundedWeek = BigInt(Math.floor((await latestTs()) / WEEK) * WEEK);

    await token.mint(owner.address, E("60"));
    await token.connect(owner).approve(fd.target, E("60"));
    await fd.notifyRewardAmount(E("60"));

    await toNextWeek();
    const weeks = [];
    for (let i = 11n; i >= 0n; i--) weeks.push(fundedWeek - i * BigInt(WEEK));
    await fd.batchFinalize(weeks);

    const beforeA = await token.balanceOf(a.address);
    const beforeB = await token.balanceOf(b.address);
    const beforeC = await token.balanceOf(c.address);

    await fd.connect(a).claim(a.address);
    await fd.connect(b).claim(b.address);
    await fd.connect(c).claim(c.address);

    const gotA = (await token.balanceOf(a.address)) - beforeA;
    const gotB = (await token.balanceOf(b.address)) - beforeB;
    const gotC = (await token.balanceOf(c.address)) - beforeC;

    expect(gotA).to.be.lt(gotB);
    expect(gotB).to.be.lt(gotC);

    const total = gotA + gotB + gotC;
    expect(total).to.be.lte(E("60"));
  });
});
