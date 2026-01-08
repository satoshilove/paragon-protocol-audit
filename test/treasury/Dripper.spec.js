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

describe("RewardDripperEscrow @spec (hardened)", () => {
  let owner, other;
  let X, dripper;
  let farmMock; // IMPORTANT: must be a contract exposing rewardToken()

  beforeEach(async () => {
    [owner, , other] = await ethers.getSigners();

    // Token
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();
    await X.mint(owner.address, E("1000000"));

    // Farm mock (implements rewardToken() via public immutable)
    const FarmMock = await ethers.getContractFactory("MockFarmRewards");
    farmMock = await FarmMock.deploy(X.target);
    await farmMock.waitForDeployment();

    // Hardened escrow
    const D = await ethers.getContractFactory("RewardDripperEscrow");

    // ctor: (owner_, token_, farm_, startTime_, ratePerSec_)
    const nowTs = await latestTs();
    dripper = await D.deploy(owner.address, X.target, await farmMock.getAddress(), nowTs, 0);
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

    const farmAddr = await farmMock.getAddress();
    const farmBefore = await X.balanceOf(farmAddr);

    const tx = await dripper.drip();
    const rcpt = await tx.wait();
    const [ev] = await dripper.queryFilter(dripper.filters.Dripped(), rcpt.blockNumber, rcpt.blockNumber);
    const [accruedBefore, sent, accruedAfter] = ev.args.map((x) => BigInt(x));

    expect(accruedAfter).to.equal(accruedBefore - sent);

    const farmAfter = await X.balanceOf(farmAddr);
    expect(farmAfter - farmBefore).to.equal(sent);
  });

  /* ───────── INV-RDE-04: rate changes apply accrual first ───────── */
  it("INV-RDE-04: setRatePerSec / setWeeklyAmount apply accrual first", async () => {
    await dripper.setRatePerSec(E("10"));
    await ff(30);

    const tBefore = await latestTs();
    const pendingBefore = await dripper.pendingAccrued();
    const oldRate = await dripper.currentRatePerSec();

    await dripper.setRatePerSec(E("20"));

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

    const funded = E("300");
    await dripper.fund(funded); // balance 300

    const cap = E("200");
    await dripper.setMaxDripPerTx(cap); // cap 200

    const farmAddr = await farmMock.getAddress();
    const farmBefore = await X.balanceOf(farmAddr);

    const tx = await dripper.drip();
    const rcpt = await tx.wait();
    const [ev] = await dripper.queryFilter(dripper.filters.Dripped(), rcpt.blockNumber, rcpt.blockNumber);
    const [accruedBefore, sent, accruedAfter] = ev.args.map((x) => BigInt(x));

    const expectedSent = (accruedBefore < funded
      ? (accruedBefore < cap ? accruedBefore : cap)
      : (funded < cap ? funded : cap));

    expect(sent).to.equal(expectedSent);
    expect(accruedAfter).to.equal(accruedBefore - sent);

    const farmAfter = await X.balanceOf(farmAddr);
    expect(farmAfter - farmBefore).to.equal(sent);
  });

  /* ───────── NEW: underfunded drip skips without reverting ───────── */
  it("HANDSHAKE: skips without reverting when dripper is underfunded", async () => {
    await dripper.setRatePerSec(E("1"));
    await ff(100);

    const pending = await dripper.pendingAccrued();
    expect(pending).to.be.gt(0n);

    // no fund() called => balance is 0
    const farmAddr = await farmMock.getAddress();
    const farmBefore = await X.balanceOf(farmAddr);

    const tx = await dripper.drip();
    const rcpt = await tx.wait();

    const [ev] = await dripper.queryFilter(dripper.filters.Dripped(), rcpt.blockNumber, rcpt.blockNumber);
    const sent = BigInt(ev.args.sent);
    expect(sent).to.equal(0n);

    const farmAfter = await X.balanceOf(farmAddr);
    expect(farmAfter - farmBefore).to.equal(0n);
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
    const D = await ethers.getContractFactory("RewardDripperEscrow");
    const nowTs = await latestTs();
    const farmAddr = await farmMock.getAddress();

    // OZ v5 Ownable(owner_) reverts with custom error before your require() string
    await expect(
      D.deploy(ethers.ZeroAddress, X.target, farmAddr, nowTs, 0)
    ).to.be.revertedWithCustomError(D, "OwnableInvalidOwner");

    await expect(D.deploy(owner.address, ethers.ZeroAddress, farmAddr, nowTs, 0)).to.be.revertedWith("Escrow: zero token");
    await expect(D.deploy(owner.address, X.target, ethers.ZeroAddress, nowTs, 0)).to.be.revertedWith("Escrow: zero farm");

    await expect(dripper.setFarm(ethers.ZeroAddress)).to.be.revertedWith("Escrow: zero farm");
    await expect(dripper.setMaxDripPerTx(0)).to.be.revertedWith("Escrow: zero max");

    await expect(dripper.rescue(X.target, ethers.ZeroAddress, 1)).to.be.revertedWith("Escrow: zero to");
    await expect(dripper.rescue(X.target, other.address, 0)).to.be.revertedWith("Escrow: zero amount");

    // rescue other token works (3-arg rescue)
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const O = await ERC.deploy("OTK", "OTK", 18);
    await O.waitForDeployment();

    await O.mint(dripper.target, E("123"));

    const before = await O.balanceOf(other.address);
    await dripper.rescue(O.target, other.address, E("123"));
    expect((await O.balanceOf(other.address)) - before).to.equal(E("123"));
  });

  /* ───────── Happy-path drip ───────── */
  it("Happy path: fund, accrue, drip to farm", async () => {
    await dripper.setRatePerSec(E("2"));
    await ff(10); // ~20 accrued
    await dripper.fund(E("100"));

    const farmAddr = await farmMock.getAddress();
    const farmBefore = await X.balanceOf(farmAddr);

    const tx = await dripper.drip();
    const rcpt = await tx.wait();
    const [ev] = await dripper.queryFilter(dripper.filters.Dripped(), rcpt.blockNumber, rcpt.blockNumber);
    const [accruedBefore, sent, accruedAfter] = ev.args.map((x) => BigInt(x));

    expect(accruedAfter).to.equal(accruedBefore - sent);
    expect(accruedAfter).to.equal(0n);

    const farmAfter = await X.balanceOf(farmAddr);
    expect(farmAfter - farmBefore).to.equal(sent);
  });
});
