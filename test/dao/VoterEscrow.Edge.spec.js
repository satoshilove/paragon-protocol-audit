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

describe("VoterEscrow edge paths @spec", () => {
  it("increase_amount, increase_unlock_time, expiry, withdraw, then re-lock", async () => {
    const [owner, user] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const token = await ERC.deploy("XPGN", "XPGN", 18);
    await token.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(token.target, owner.address);
    await ve.waitForDeployment();

    await token.mint(user.address, E("50"));
    await token.connect(user).approve(ve.target, ethers.MaxUint256);

    let end = Number(ceilWeek((await latestTs()) + 8 * WEEK));
    await ve.connect(user).create_lock(E("10"), end);

    await ve.connect(user).increase_amount(E("5"));
    let lock = await ve.locked(user.address);
    expect(lock[0]).to.equal(E("15"));

    end = Number(ceilWeek((await latestTs()) + 12 * WEEK));
    await ve.connect(user).increase_unlock_time(end);
    lock = await ve.locked(user.address);
    expect(lock[1]).to.equal(BigInt(end));

    await ff(end - (await latestTs()) + 2);
    await ve.connect(user).withdraw();

    expect((await ve.locked(user.address))[0]).to.equal(0n);

    const relockEnd = Number(ceilWeek((await latestTs()) + 8 * WEEK));
    await ve.connect(user).create_lock(E("20"), relockEnd);
    expect((await ve.locked(user.address))[0]).to.equal(E("20"));
  });

  it("two users expiring in the same week can both withdraw cleanly", async () => {
    const [owner, a, b] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const token = await ERC.deploy("XPGN", "XPGN", 18);
    await token.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(token.target, owner.address);
    await ve.waitForDeployment();

    const end = Number(ceilWeek((await latestTs()) + 10 * WEEK));

    for (const [acct, amt] of [[a, "10"], [b, "15"]]) {
      await token.mint(acct.address, E(amt));
      await token.connect(acct).approve(ve.target, ethers.MaxUint256);
      await ve.connect(acct).create_lock(E(amt), end);
    }

    await ff(end - (await latestTs()) + 2);
    await ve.connect(a).withdraw();
    await ve.connect(b).withdraw();

    expect((await ve.locked(a.address))[0]).to.equal(0n);
    expect((await ve.locked(b.address))[0]).to.equal(0n);
  });
});
