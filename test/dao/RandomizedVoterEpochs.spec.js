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

describe("Randomized voter/epoch behavior @property", () => {
  it("many voters changing locks across many epochs keeps finalized totals consistent", async () => {
    const seed = 1337;
    const rng = mulberry32(seed);

    const [owner, u1, u2, u3, u4] = await ethers.getSigners();
    const users = [u1, u2, u3, u4];

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
    await usage.setCaller(owner.address, true);

    const gauges = [
      ethers.Wallet.createRandom().address,
      ethers.Wallet.createRandom().address,
      ethers.Wallet.createRandom().address
    ];
    for (const g of gauges) {
      await gc.addGauge(g);
    }

    // Create initial locks for all users
    for (let i = 0; i < users.length; i++) {
      await X.mint(users[i].address, E("1000"));
      await X.connect(users[i]).approve(ve.target, ethers.MaxUint256);
      const unlock = (await latestTs()) + (30 + i * 2) * WEEK;
      await ve.connect(users[i]).create_lock(E(String(200 + i * 50)), unlock);
    }
    await ff(2);
    if (typeof ve.checkpoint === "function") await ve.checkpoint();

    const epochsToRun = 6;

    for (let step = 0; step < epochsToRun; step++) {
      const ep = await gc.epoch();

      // Random user actions before votes
      for (const user of users) {
        const roll = randInt(rng, 1, 100);
        if (roll <= 35) {
          const addAmt = E(String(randInt(rng, 1, 20)));
          await X.mint(user.address, addAmt);
          await X.connect(user).approve(ve.target, addAmt);
          await ve.connect(user).increase_amount(addAmt);
        } else if (roll <= 60) {
          const extendWeeks = randInt(rng, 1, 4);
          const current = await ve.locked(user.address);
          const newUnlock = Number(current[1]) + extendWeeks * WEEK;
          await ve.connect(user).increase_unlock_time(newUnlock);
        }
      }

      // Random votes
      for (const user of users) {
        const picks = [];
        const bps = [];
        let remaining = 10000;

        const order = [...gauges].sort(() => rng() - 0.5).slice(0, randInt(rng, 1, 3));
        for (let i = 0; i < order.length; i++) {
          const last = i === order.length - 1;
          let share;
          if (last) {
            share = remaining;
          } else {
            share = randInt(rng, 1000, Math.max(1000, remaining - (order.length - i - 1) * 1000));
          }
          remaining -= share;
          picks.push(order[i]);
          bps.push(share);
        }

        await gc.connect(user).vote(picks, bps);
      }

      await toNextWeek();
      await gc.finalizeEpoch(ep);

      let sum = 0n;
      for (const g of gauges) {
        sum += await gc.gaugeWeightFinal(ep, g);
      }
      expect(await gc.totalWeightFinal(ep)).to.equal(sum);
    }
  });
});
