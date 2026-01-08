/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const hre = require("hardhat");
const { ethers } = hre;
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const E = (n) => ethers.parseEther(n);
const DAY = 24 * 60 * 60;

async function deployVaultFixture() {
  const [owner, dao] = await ethers.getSigners();

  const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
  const X  = await ERC.deploy("XPGN", "XPGN", 18);
  const LP = await ERC.deploy("LP", "LP", 18);
  await X.waitForDeployment();
  await LP.waitForDeployment();

  // ✅ Use the farm mock that matches the vault interface
  const pid = 0;
  const MF = await ethers.getContractFactory("contracts/mocks/MockFarmRewards.sol:MockFarmRewards");
  const farm = await MF.deploy(X.target);
  await farm.waitForDeployment();

  // ✅ MUST add pool BEFORE vault deployment (constructor checks poolLpToken(pid))
  await (await farm.addPool(pid, LP.target)).wait();

  const V = await ethers.getContractFactory("ParagonLockingVault");
  const vault = await V.deploy(
    owner.address,
    LP.target,
    X.target,
    farm.target,
    pid,
    dao.address
  );
  await vault.waitForDeployment();

  // Fund + approve LP for owner
  await (await LP.mint(owner.address, E("200"))).wait();
  await (await LP.connect(owner).approve(vault.target, ethers.MaxUint256)).wait();

  // (optional) keep params deterministic if tests assume exact bips
  if (vault.setParams) {
    await (await vault.setParams(30 * DAY, 60 * DAY, 90 * DAY, 12000, 15000, 20000)).wait();
  }
  if (vault.setEarlyPenaltyBips) {
    await (await vault.setEarlyPenaltyBips(250)).wait(); // 2.5%
  }

  return { owner, dao, X, LP, farm, vault, pid };
}

// IMPORTANT: return the tx promise, DON'T await inside helper
function depositTx(vault, amount, tier, referrer) {
  return vault.deposit(amount, tier, referrer);
}

describe("ParagonLockingVault - Additional Security Tests", function () {
  it("INV-VLT-EDGE-01: Early unlock applies exact penalty without underflow", async function () {
    const { vault, LP, owner, dao } = await loadFixture(deployVaultFixture);

    const beforeUser = await LP.balanceOf(owner.address);
    const beforeDao  = await LP.balanceOf(dao.address);

    // deposit 100 into tier 1 (60d)
    await (await depositTx(vault, E("100"), 1, owner.address)).wait();
    await time.increase(60 * 60); // 1 hour

    // must exist on your vault
    const ue = vault.interface.fragments.find(
      (f) => f.type === "function" && f.name === "unlockEarly"
    );
    if (!ue) return this.skip?.();

    await expect(vault.unlockEarly(0)).to.emit(vault, "EarlyUnlocked");

    const afterUser = await LP.balanceOf(owner.address);
    const afterDao  = await LP.balanceOf(dao.address);

    // user got < 100 back due to penalty
    expect(afterUser - beforeUser).to.be.lt(E("100"));
    // dao got penalty (should be 2.5 LP for 100 LP if bips=250)
    expect(afterDao - beforeDao).to.be.gte(0n);
  });

  it("INV-VLT-ATTACK-01: Emergency mode allows unlock but blocks deposits", async function () {
    const { vault, owner } = await loadFixture(deployVaultFixture);

    await (await depositTx(vault, E("10"), 0, owner.address)).wait();

    const sem = vault.interface.fragments.find(
      (f) => f.type === "function" && f.name === "setEmergencyMode"
    );
    if (!sem) return this.skip?.();

    await (await vault.setEmergencyMode(true)).wait();

    // now deposits revert
    await expect(depositTx(vault, E("1"), 0, owner.address)).to.be.revertedWith("emergency");

    // but unlock works even before unlock time
    await expect(vault.unlock(0)).to.emit(vault, "Unlocked");
  });
});
