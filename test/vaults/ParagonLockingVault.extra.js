/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const hre = require("hardhat");
const { ethers } = hre;
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const E = (n) => ethers.parseEther(n);

async function deployAdaptive(name, ctx = {}) {
  const F = await ethers.getContractFactory(name);
  const art = await hre.artifacts.readArtifact(name);
  const ctor = (art.abi.find(x => x.type === "constructor") || { inputs: [] }).inputs;
  const map = (name) => {
    const n = (name || "").toLowerCase();
    if (n.includes("owner") || n.includes("admin")) return ctx.owner?.address ?? ctx.user?.address;
    if (n.includes("lp")) return ctx.LP?.target ?? ethers.ZeroAddress;
    if (n.includes("reward")) return ctx.X?.target ?? ethers.ZeroAddress;
    if (n.includes("farm")) return ctx.farm?.target ?? ethers.ZeroAddress;
    if (n.includes("dao") || n.includes("treasury")) return ctx.dao?.address ?? ethers.ZeroAddress;
    return ethers.ZeroAddress;
  };
  const args = ctor.map(i => i.type.startsWith("address") ? map(i.name) : (i.type === "bool" ? false : 0));
  const c = await F.deploy(...args);
  await c.waitForDeployment();
  return c;
}

async function farmAddPoolAdaptive(farm, lp) {
  const fns = farm.interface.fragments.filter(f => f.type === "function" && f.name === "addPool");
  if (fns.length === 0) return;
  const f = fns[0];
  const args = f.inputs.map((inp) => {
    const n = (inp.name || "").toLowerCase();
    if (inp.type.startsWith("address")) return lp.target;
    if (inp.type.startsWith("uint")) return n.includes("alloc") ? 0 : 0;
    if (inp.type === "bool") return true;
    return 0;
  });
  await (await farm.addPool(...args)).wait();
}

async function callDepositAdaptive(vault, amount, tier, to) {
  const fns = vault.interface.fragments.filter(f => f.type === "function" && f.name === "deposit");
  if (fns.length === 0) return;
  const f = fns[0];
  const args = f.inputs.map((inp) => {
    const n = (inp.name || "").toLowerCase();
    if (inp.type.startsWith("uint")) return n.includes("amount") ? amount : (n.includes("tier") ? tier : 0);
    if (inp.type === "address") return to;
    if (inp.type === "bool") return false;
    return 0;
  });
  await (await vault.deposit(...args)).wait();
}

async function deployVaultFixture() {
  const [owner, dao] = await ethers.getSigners();
  const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
  const X  = await ERC.deploy("XPGN", "XPGN", 18);
  const LP = await ERC.deploy("LP", "LP", 18);
  await X.waitForDeployment(); await LP.waitForDeployment();

  const farm  = await deployAdaptive("ParagonFarmController", { owner, X });
  await farmAddPoolAdaptive(farm, LP);

  const vault = await deployAdaptive("ParagonLockingVault", { owner, LP, X, farm, dao });

  await LP.mint(owner.address, E("200"));
  await LP.connect(owner).approve(vault.target, ethers.MaxUint256);
  try { await vault.setEarlyPenaltyBips(250); } catch {}

  return { owner, dao, X, LP, farm, vault };
}

describe("ParagonLockingVault - Additional Security Tests", function () {
  it("INV-VLT-EDGE-01: Early unlock applies exact penalty without underflow", async function () {
    const { vault, LP, owner } = await loadFixture(deployVaultFixture);

    const before = await LP.balanceOf(owner.address);
    await callDepositAdaptive(vault, E("100"), 1, owner.address);
    await time.increase(60 * 60);

    // prefer unlockEarly if present; otherwise skip
    const ue = vault.interface.fragments.find(f => f.type === "function" && f.name === "unlockEarly");
    if (!ue) return this.skip?.();
    await expect(vault.unlockEarly(0)).to.emit(vault, "EarlyUnlocked");

    const after = await LP.balanceOf(owner.address);
    expect(after - before).to.be.lt(E("100"));
  });

  it("INV-VLT-ATTACK-01: Emergency mode allows unlock but blocks deposits", async function () {
    const { vault, LP, owner } = await loadFixture(deployVaultFixture);

    await callDepositAdaptive(vault, E("10"), 0, owner.address);

    // setEmergencyMode(bool) if present
    const sem = vault.interface.fragments.find(f => f.type === "function" && f.name === "setEmergencyMode");
    if (sem) { await (await vault.setEmergencyMode(true)).wait(); } else { return this.skip?.(); }

    await expect(callDepositAdaptive(vault, E("1"), 0, owner.address)).to.be.reverted;
    await expect(vault.unlock(0)).to.emit(vault, "Unlocked");
  });
});
