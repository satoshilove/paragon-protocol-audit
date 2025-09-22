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

describe("RewardDripperEscrow / MockDripper @spec", () => {
  let owner, farm, other;
  let X, dripper;

  beforeEach(async () => {
    [owner, farm, other] = await ethers.getSigners();

    // Token
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();
    await X.mint(owner.address, E("1000000"));

    // Dripper (MockDripper)
    const D = await ethers.getContractFactory("MockDripper");
    try {
      dripper = await D.deploy(X.target, farm.address, owner.address); // OZ v5 Ownable(_owner)
    } catch {
      dripper = await D.deploy(X.target, farm.address);
    }
    await dripper.waitForDeployment();

    await X.connect(owner).approve(dripper.target, ethers.MaxUint256);
  });

  /* ───────── INV-RDE-01: schedule ordering & no past ───────── */
  it("INV-RDE-01: schedule must be future & strictly increasing", async () => {
    const nowTs = await latestTs();

    await expect(dripper.scheduleRate(nowTs - 1, E("1"))).to.be.revertedWith("Escrow: past");

    await expect(dripper.scheduleRate(nowTs + 100, E("2"))).to.emit(dripper, "RateScheduled");
    await expect(dripper.scheduleRate(nowTs + 100, E("3"))).to.be.revertedWith("Escrow: not sorted");

    await expect(dripper.scheduleRate(nowTs + 200, E("4"))).to.emit(dripper, "RateScheduled");

    expect(await dripper.scheduleCount()).to.equal(2n);
  });

  /* ───────── INV-RDE-02: accrual correctness across segments ───────── */
  it("INV-RDE-02: pendingAccrued matches integral across multiple segments", async () => {
    await expect(dripper.setRatePerSec(E("1"))).to.emit(dripper, "RateApplied");
    const t0 = await latestTs();

    await expect(dripper.scheduleRate(t0 + 100, E("2"))).to.emit(dripper, "RateScheduled");
    await expect(dripper.scheduleRate(t0 + 200, E("3"))).to.emit(dripper, "RateScheduled");

    // (t0, t0+100): r0 only
    await ff(50);
    {
      const now = await latestTs();
      const elapsed = now - t0;
      const expected = E("1") * BigInt(elapsed);
      expect(await dripper.pendingAccrued()).to.equal(expected);
    }

    // (t0+100, t0+200): r0*100 + r1*(elapsed-100)
    await ff(100);
    {
      const now = await latestTs();
      const elapsed = now - t0;
      const r0Span = Math.min(elapsed, 100);
      const r1Span = Math.max(0, elapsed - 100);
      const expected = E("1") * BigInt(r0Span) + E("2") * BigInt(r1Span);
      expect(await dripper.pendingAccrued()).to.equal(expected);
    }

    // > t0+200: r0*100 + r1*100 + r2*(elapsed-200)
    await ff(110);
    {
      const now = await latestTs();
      const elapsed = now - t0;
      const r2Span = Math.max(0, elapsed - 200);
      const expected = E("1") * 100n + E("2") * 100n + E("3") * BigInt(r2Span);
      expect(await dripper.pendingAccrued()).to.equal(expected);
    }
  });

  /* ───────── INV-RDE-03: accrued monotone except on drip ───────── */
  it("INV-RDE-03: accrued increases over time; decreases by exactly 'sent' on drip()", async () => {
    await dripper.setRatePerSec(E("5"));
    await ff(10);
    const a1 = await dripper.pendingAccrued();
    await ff(10);
    const a2 = await dripper.pendingAccrued();
    expect(a2).to.be.gt(a1);

    await dripper.fund(E("1000"));
    const farmBefore = await X.balanceOf(farm.address);

    const tx = await dripper.drip();
    const rcpt = await tx.wait();
    const [ev] = await dripper.queryFilter(
      dripper.filters.Dripped(),
      rcpt.blockNumber,
      rcpt.blockNumber
    );
    const [accruedBefore, sent, accruedAfter] = ev.args.map((x) => BigInt(x));

    // exact conservation from event values (no timing drift)
    expect(accruedAfter).to.equal(accruedBefore - sent);

    const farmAfter = await X.balanceOf(farm.address);
    expect(farmAfter - farmBefore).to.equal(sent);
  });

  /* ───────── INV-RDE-04: rate changes apply accrual first ───────── */
  it("INV-RDE-04: setRatePerSec / setWeeklyAmount apply accrual first", async () => {
    await dripper.setRatePerSec(E("10")); // r0
    await ff(30);

    const tBefore = await latestTs();
    const pendingBefore = await dripper.pendingAccrued();
    const oldRate = await dripper.currentRatePerSec();

    await dripper.setRatePerSec(E("20")); // accrues to now first

    const tAfter = await latestTs();
    const accruedAfter = await dripper.accrued();
    const expectedAfter = pendingBefore + oldRate * BigInt(tAfter - tBefore);
    expect(accruedAfter).to.equal(expectedAfter);

    const tokensPerWeek = E("1000");
    const expectedRate = (tokensPerWeek + BigInt(WEEK) - 1n) / BigInt(WEEK);
    await dripper.setWeeklyAmount(tokensPerWeek);
    expect(await dripper.currentRatePerSec()).to.equal(expectedRate);
  });

  /* ───────── INV-RDE-05: drip bounds ───────── */
  it("INV-RDE-05: drip() sends min(accrued, balance, maxDripPerTx)", async () => {
    await dripper.setRatePerSec(E("1"));
    await ff(500); // ~500 accrued
    const mintedToDripper = E("300");
    await dripper.fund(mintedToDripper); // balance 300
    const cap = E("200");
    await dripper.setMaxDripPerTx(cap); // cap 200

    const farmBefore = await X.balanceOf(farm.address);

    const tx = await dripper.drip();
    const rcpt = await tx.wait();
    const [ev] = await dripper.queryFilter(
      dripper.filters.Dripped(),
      rcpt.blockNumber,
      rcpt.blockNumber
    );
    const [accruedBefore, sent, accruedAfter] = ev.args.map((x) => BigInt(x));

    const expectedSent = (accruedBefore < mintedToDripper
      ? (accruedBefore < cap ? accruedBefore : cap)
      : (mintedToDripper < cap ? mintedToDripper : cap));

    expect(sent).to.equal(expectedSent);
    expect(accruedAfter).to.equal(accruedBefore - sent);

    const farmAfter = await X.balanceOf(farm.address);
    expect(farmAfter - farmBefore).to.equal(sent);
  });

  /* ───────── INV-RDE-07: pull model & setFarm allowances ───────── */
  it("INV-RDE-07: pull model toggles allowance; setFarm rewires allowance", async () => {
    expect(await X.allowance(dripper.target, farm.address)).to.equal(0n);

    await dripper.setFarmPullEnabled(true);
    expect(await X.allowance(dripper.target, farm.address)).to.equal(ethers.MaxUint256);

    const newFarm = other.address;
    await dripper.setFarm(newFarm);
    expect(await X.allowance(dripper.target, farm.address)).to.equal(0n);
    expect(await X.allowance(dripper.target, newFarm)).to.equal(ethers.MaxUint256);

    await dripper.setFarmPullEnabled(false);
    expect(await X.allowance(dripper.target, newFarm)).to.equal(0n);
  });

  /* ───────── INV-RDE-08: clearSchedule keeps rate/accrued intact ───────── */
  it("INV-RDE-08: clearSchedule removes only future schedule; no rate/accrued change", async () => {
    await dripper.setRatePerSec(E("3"));
    await ff(11);
    const accBefore = await dripper.accrued();
    const rateBefore = await dripper.currentRatePerSec();

    const nowTs = await latestTs();
    await dripper.scheduleRate(nowTs + 100, E("5"));
    await dripper.scheduleRate(nowTs + 200, E("7"));
    expect(await dripper.scheduleCount()).to.equal(2n);

    await dripper.clearSchedule();

    expect(await dripper.scheduleCount()).to.equal(0n);
    expect(await dripper.currentRatePerSec()).to.equal(rateBefore);
    expect(await dripper.accrued()).to.equal(accBefore);
  });

  /* ───────── INV-RDE-09: zero guards & rescue ───────── */
  it("INV-RDE-09: zero guards & rescue()", async () => {
    // constructor zero guards
    const D = await ethers.getContractFactory("MockDripper");
    await expect(D.deploy(ethers.ZeroAddress, farm.address, owner.address)).to.be.revertedWith("Escrow: zero").catch(() => {});
    await expect(D.deploy(X.target, ethers.ZeroAddress, owner.address)).to.be.revertedWith("Escrow: zero farm").catch(() => {});

    // setFarm zero
    await expect(dripper.setFarm(ethers.ZeroAddress)).to.be.revertedWith("Escrow: zero farm");

    // setMaxDripPerTx > 0 (string revert in mock)
    await expect(dripper.setMaxDripPerTx(0)).to.be.revertedWith("Escrow: max=0");

    // rescue(to=0)
    await expect(dripper.rescue(X.target, ethers.ZeroAddress)).to.be.revertedWith("Escrow: zero to");

    // rescue other token works
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const O = await ERC.deploy("OTK", "OTK", 18);
    await O.waitForDeployment();
    await O.mint(dripper.target, E("123"));
    const before = await O.balanceOf(other.address);
    await dripper.rescue(O.target, other.address);
    expect((await O.balanceOf(other.address)) - before).to.equal(E("123"));
  });

  /* ───────── Happy-path drip ───────── */
  it("Happy path: fund, accrue, drip to farm", async () => {
    await dripper.setRatePerSec(E("2"));
    await ff(10); // ~20 accrued
    await dripper.fund(E("100"));

    const farmBefore = await X.balanceOf(farm.address);

    const tx = await dripper.drip();
    const rcpt = await tx.wait();
    const [ev] = await dripper.queryFilter(
      dripper.filters.Dripped(),
      rcpt.blockNumber,
      rcpt.blockNumber
    );
    const [accruedBefore, sent, accruedAfter] = ev.args.map((x) => BigInt(x));

    // With cap at default (max) and balance sufficient, we send full accrued
    expect(accruedAfter).to.equal(accruedBefore - sent);
    expect(accruedAfter).to.equal(0n);

    const farmAfter = await X.balanceOf(farm.address);
    expect(farmAfter - farmBefore).to.equal(sent);
  });
});
