/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const WEEK = 7 * 24 * 60 * 60;
const VOTE_COOLDOWN = 7 * 24 * 60 * 60;

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}
async function latestTs() {
  const b = await ethers.provider.getBlock("latest");
  return BigInt(b.timestamp);
}

async function deployGaugeController(ve, owner) {
  const GC = await ethers.getContractFactory("GaugeController");
  try {
    const c = await GC.deploy(ve.target, owner.address);
    await c.waitForDeployment();
    return c;
  } catch {}
  const c = await GC.deploy(ve.target);
  await c.waitForDeployment();
  return c;
}

async function deploySimpleGauge(lp, reward, controllerAddr, owner) {
  const G = await ethers.getContractFactory("SimpleGauge");
  // Try: (lp, reward, controller, initialOwner)
  try {
    const g = await G.deploy(lp.target, reward.target, controllerAddr ?? ethers.ZeroAddress, owner.address);
    await g.waitForDeployment();
    return g;
  } catch {}
  // Try: (lp, reward, controller)
  try {
    const g = await G.deploy(lp.target, reward.target, controllerAddr ?? ethers.ZeroAddress);
    await g.waitForDeployment();
    return g;
  } catch {}
  // Fallback: (lp, reward)
  const g = await G.deploy(lp.target, reward.target);
  await g.waitForDeployment();
  return g;
}

async function deployMinter(token, controller, owner) {
  const M = await ethers.getContractFactory("EmissionsMinter");
  try {
    const m = await M.deploy(token.target, controller.target, owner.address);
    await m.waitForDeployment();
    return m;
  } catch {}
  const m = await M.deploy(token.target, controller.target);
  await m.waitForDeployment();
  return m;
}

describe("EmissionsMinter @spec", () => {
  let owner, other;
  let X, LP, ve, gc, g0, g1, minter;

  beforeEach(async () => {
    [owner, other] = await ethers.getSigners();

    // Tokens
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    X  = await ERC.deploy("XPGN", "XPGN", 18);
    LP = await ERC.deploy("LP", "LP", 18);
    await X.waitForDeployment(); await LP.waitForDeployment();

    // VE with a lock so voting is allowed
    const VE = await ethers.getContractFactory("VoterEscrow");
    let _ve;
    try {
      _ve = await VE.deploy(X.target, owner.address);
    } catch {
      _ve = await VE.deploy(X.target);
    }
    await _ve.waitForDeployment();
    ve = _ve;

    await X.mint(owner.address, E("1000"));
    await X.approve(ve.target, ethers.MaxUint256);
    const unlock = Number((await latestTs()) + BigInt(8 * WEEK));
    await ve.create_lock(E("100"), unlock);

    // Controller & gauges
    gc = await deployGaugeController(ve, owner);
    g0 = await deploySimpleGauge(LP, X, ethers.ZeroAddress, owner);
    g1 = await deploySimpleGauge(LP, X, ethers.ZeroAddress, owner);

    await gc.addGauge(g0.target);
    await gc.addGauge(g1.target);

    // Vote weights 60/40 with cooldown respected between votes
    await gc.vote_for_gauge_weights(g0.target, 6000);
    await ff(VOTE_COOLDOWN + 1); // <-- respect 7d cooldown
    await gc.vote_for_gauge_weights(g1.target, 4000);

    // Minter
    minter = await deployMinter(X, gc, owner);

    // If gauges support minter wiring, set it
    if (g0.setMinter) await (await g0.setMinter(minter.target)).wait();
    if (g1.setMinter) await (await g1.setMinter(minter.target)).wait();
  });

  it("INV-EM-01: epochEmission setter gated & emits", async () => {
    await expect(minter.connect(other).setWeeklyEmission(E("100"))).to.be.reverted;
    await expect(minter.setWeeklyEmission(E("123")))
      .to.emit(minter, "SetWeeklyEmission")
      .withArgs(E("123"));
  });

  it("INV-EM-02: kick() only once per week (already pushed)", async () => {
    await minter.setWeeklyEmission(E("100"));
    await expect(minter.kick()).to.emit(minter, "Pushed");
    await expect(minter.kick()).to.be.reverted; // same week
    await ff(WEEK + 1);
    await expect(minter.kick()).to.emit(minter, "Pushed");
  });

  it("INV-EM-03: distribution splits to gauges by weight", async () => {
    await minter.setWeeklyEmission(E("100"));
    await expect(minter.kick()).to.emit(minter, "Pushed");

    // rewardRate = floor(share / 7d)
    const D = 7n * 24n * 60n * 60n;
    const rate0 = await g0.rewardRate();
    const rate1 = await g1.rewardRate();

    const exp0 = (E("100") * 6000n / 10000n) / D;
    const exp1 = (E("100") * 4000n / 10000n) / D;

    expect(rate0).to.equal(exp0);
    expect(rate1).to.equal(exp1);
  });
});
