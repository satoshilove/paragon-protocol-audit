/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const WEEK = 7 * 24 * 60 * 60;
const E = (n) => ethers.parseEther(n);

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}
function mulberry32(seed) {
  return function () {
    let t = (seed += 0x6D2B79F5);
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function randInt(rng, min, max) {
  return Math.floor(rng() * (max - min + 1)) + min;
}

describe("Randomized gauge add/remove/map cycles @property", () => {
  it("removed historical gauges still finalize correctly if they had weight", async () => {
    const rng = mulberry32(777);
    const [owner, user] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    const U = await ethers.getContractFactory("UsagePoints");
    const usage = await U.deploy(owner.address);
    await usage.waitForDeployment();

    const GC = await ethers.getContractFactory("GaugeController");
    const gc = await GC.deploy(ve.target, usage.target, owner.address);
    await gc.waitForDeployment();
    await gc.setParams(E("1"), 10, 0);

    await X.mint(user.address, E("500"));
    await X.connect(user).approve(ve.target, ethers.MaxUint256);
    await ve.connect(user).create_lock(E("200"), Math.floor(Date.now() / 1000) + 40 * WEEK);
    await ff(2);
    if (typeof ve.checkpoint === "function") await ve.checkpoint();

    const gauges = Array.from({ length: 6 }, () => ethers.Wallet.createRandom().address);
    for (const g of gauges) await gc.addGauge(g);

    for (let cycle = 0; cycle < 4; cycle++) {
      const ep = await gc.epoch();

      // vote across 2-3 currently active gauges
      const active = [];
      for (const g of gauges) {
        if (await gc.isGauge(g)) active.push(g);
      }
      const picks = active.slice(0, Math.min(active.length, randInt(rng, 2, 3)));
      let rem = 10000;
      const bps = picks.map((_, i) => {
        if (i === picks.length - 1) return rem;
        const x = randInt(rng, 1000, rem - 1000 * (picks.length - i - 1));
        rem -= x;
        return x;
      });
      await gc.connect(user).vote(picks, bps);

      // remove one random active gauge after vote
      if (active.length > 0) {
        const victim = active[randInt(rng, 0, active.length - 1)];
        await gc.removeGauge(victim);
      }

      await ff(WEEK + 2);
      await gc.finalizeEpoch(ep);

      let sum = 0n;
      for (const g of gauges) {
        sum += await gc.gaugeWeightFinal(ep, g);
      }
      expect(await gc.totalWeightFinal(ep)).to.equal(sum);

      // reactivate one inactive gauge to keep churn going
      for (const g of gauges) {
        if (!(await gc.isGauge(g))) {
          await gc.addGauge(g);
          break;
        }
      }
    }
  });
});
