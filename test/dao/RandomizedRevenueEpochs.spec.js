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

describe("Randomized revenue/finalize/claim cycles @property", () => {
  it("repeated fee deposits/finalizations/claims never exceed funded rewards", async () => {
    const seed = 424242;
    const rng = mulberry32(seed);

    const [owner, treasury, u1, u2, u3] = await ethers.getSigners();
    const users = [u1, u2, u3];

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    const FD = await ethers.getContractFactory("FeeDistributorERC20");
    const fd = await FD.deploy(X.target, ve.target, owner.address);
    await fd.waitForDeployment();
    await fd.setRewardNotifier(owner.address, true);

    // Locks before the randomized weeks begin
    for (let i = 0; i < users.length; i++) {
      await X.mint(users[i].address, E("500"));
      await X.connect(users[i]).approve(ve.target, ethers.MaxUint256);
      const unlock = (await latestTs()) + (35 + i * 5) * WEEK;
      await ve.connect(users[i]).create_lock(E(String(100 + i * 50)), unlock);
    }

    // Move into a safe future window so first-claim lookback is post-lock
    for (let i = 0; i < 13; i++) await toNextWeek();

    const funded = new Map();
    let totalFunded = 0n;
    let totalClaimed = 0n;

    for (let i = 0; i < 5; i++) {
      const week = BigInt(Math.floor((await latestTs()) / WEEK) * WEEK);
      const amt = E(String(randInt(rng, 5, 30)));

      await X.mint(owner.address, amt);
      await X.connect(owner).approve(fd.target, amt);
      await fd.notifyRewardAmount(amt);

      funded.set(week.toString(), amt);
      totalFunded += amt;

      await toNextWeek();
      await fd.finalizeEpoch(week);

      for (const user of users) {
        const before = await X.balanceOf(user.address);
        await fd.connect(user).claim(user.address);
        const after = await X.balanceOf(user.address);
        totalClaimed += after - before;
      }
    }

    expect(totalClaimed).to.be.lte(totalFunded);

    // Spot-check funded weeks retain recorded rewards
    for (const [week, amt] of funded.entries()) {
      expect(await fd.epochRewards(BigInt(week))).to.equal(amt);
    }
  });
});
