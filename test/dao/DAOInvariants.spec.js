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

describe("DAO invariant-style checks @spec", () => {
  it("sum(finalizedGaugeWeight) == finalizedTotalWeight across multiple epochs", async () => {
    const [owner, user] = await ethers.getSigners();

    const Ve = await ethers.getContractFactory("contracts/mocks/MockVeVotes.sol:MockVeVotes");
    const ve = await Ve.deploy();
    await ve.waitForDeployment();

    const Usage = await ethers.getContractFactory("contracts/mocks/MockUsageMultiplier.sol:MockUsageMultiplier");
    const usage = await Usage.deploy();
    await usage.waitForDeployment();

    const GC = await ethers.getContractFactory("GaugeController");
    const gc = await GC.deploy(ve.target, usage.target, owner.address);
    await gc.waitForDeployment();

    const gauges = [ethers.Wallet.createRandom().address, ethers.Wallet.createRandom().address, ethers.Wallet.createRandom().address];
    for (const g of gauges) await gc.addGauge(g);

    await ve.setBalance(user.address, E("1000"));

    for (let i = 0; i < 3; i++) {
      await gc.connect(user).vote([gauges[0], gauges[1]], [6000, 4000]);
      const ep = await gc.epoch();
      await ff(WEEK + 2);
      await gc.finalizeEpoch(ep);

      let sum = 0n;
      for (const g of gauges) sum += await gc.gaugeWeightFinal(ep, g);
      expect(await gc.totalWeightFinal(ep)).to.equal(sum);
    }
  });

  it("fee claims never exceed funded rewards and ve supply tracks users", async () => {
    const [owner, a, b] = await ethers.getSigners();

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

    for (const [acct, amt] of [[a, "100"], [b, "150"]]) {
      await token.mint(acct.address, E(amt));
      await token.connect(acct).approve(ve.target, ethers.MaxUint256);
      await ve.connect(acct).create_lock(E(amt), Number(ceilWeek((await latestTs()) + 50 * WEEK)));
    }

    for (let i = 0; i < 13; i++) await toNextWeek();
    const fundedWeek = BigInt(Math.floor((await latestTs()) / WEEK) * WEEK);

    await token.mint(owner.address, E("20"));
    await token.connect(owner).approve(fd.target, E("20"));
    await fd.notifyRewardAmount(E("20"));
    await toNextWeek();

    const weeks = [];
    for (let i = 11n; i >= 0n; i--) weeks.push(fundedWeek - i * BigInt(WEEK));
    await fd.batchFinalize(weeks);

    const beforeA = await token.balanceOf(a.address);
    const beforeB = await token.balanceOf(b.address);
    await fd.connect(a).claim(a.address);
    await fd.connect(b).claim(b.address);
    const feeTotal = ((await token.balanceOf(a.address)) - beforeA) + ((await token.balanceOf(b.address)) - beforeB);

    expect(feeTotal).to.be.lte(E("20"));

    const supply = await ve.totalSupply();
    const sumUsers = (await ve.balanceOf(a.address)) + (await ve.balanceOf(b.address));
    const diff = supply > sumUsers ? supply - sumUsers : sumUsers - supply;
    expect(diff).to.lte(1_000_000_000_000n);
  });
});
