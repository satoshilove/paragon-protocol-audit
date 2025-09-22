/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const DAY = 24 * 60 * 60;

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}

describe("ParagonLockingVault @spec", () => {
  let owner, user, dao, ref;
  let X, LP, farm, vault;
  const pid = 0;

  beforeEach(async () => {
    [owner, user, dao, ref] = await ethers.getSigners();

    // Tokens
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    X = await ERC.deploy("XPGN", "XPGN", 18); await X.waitForDeployment();
    LP = await ERC.deploy("LP", "LP", 18); await LP.waitForDeployment();

    // Farm mock
    const MF = await ethers.getContractFactory("contracts/mocks/MockFarmRewards.sol:MockFarmRewards");
    farm = await MF.deploy(X.target); await farm.waitForDeployment();
    await farm.addPool(pid, LP.target);

    // Liquidity for rewards + user LP
    await X.mint(farm.target, E("1000000"));
    await LP.mint(user.address, E("1000"));

    // Vault (try OZ v5 Ownable(initialOwner) first, fallback to older ctor)
    const V = await ethers.getContractFactory("ParagonLockingVault");
    try {
      vault = await V.deploy(owner.address, LP.target, X.target, farm.target, pid, dao.address);
    } catch {
      vault = await V.deploy(LP.target, X.target, farm.target, pid, dao.address);
    }
    await vault.waitForDeployment();

    // Approvals
    await LP.connect(user).approve(vault.target, ethers.MaxUint256);

    // Normalize params (known multipliers)
    if (vault.setParams) {
      await vault.setParams(30 * DAY, 60 * DAY, 90 * DAY, 12000, 15000, 20000);
    }
  });

  it("INV-VLT-01/02/03: deposit tiers → shares & unlockTime; bad inputs revert", async () => {
    const t0 = (await ethers.provider.getBlock("latest")).timestamp;

    // valid tier 2 (90d, 2.0x)
    await expect(vault.connect(user).deposit(E("100"), 2, ref.address))
      .to.emit(vault, "Deposited");

    const pos = await vault.positions(user.address, 0);
    expect(pos.amount ?? pos[0]).to.equal(E("100"));
    const shares = (E("100") * 20000n) / 10000n;
    expect((pos.shares ?? pos[4])).to.equal(shares);
    const unlock = Number(pos.unlockTime ?? pos[1]);
    expect(unlock).to.be.gte(t0 + 90 * DAY);

    // bad tier
    await expect(vault.connect(user).deposit(E("1"), 3, ref.address)).to.be.revertedWith("bad tier");
    // amount=0
    await expect(vault.connect(user).deposit(0, 0, ref.address)).to.be.revertedWith("amount=0");
  });

  it("INV-VLT-06 preview: pending() reflects farm.pendingReward as-if harvested", async () => {
    await vault.connect(user).deposit(E("100"), 2, ref.address);
    await farm.setPending(pid, vault.target, E("20"));
    const pend = await vault.pending(0, user.address);
    expect(pend).to.equal(E("20"));
  });

  it("INV-VLT-04/05: harvest increases accRPS; claim pays and updates debt", async () => {
    await vault.connect(user).deposit(E("100"), 2, ref.address);

    const acc0 = await vault.accRewardPerShare();
    await farm.setPending(pid, vault.target, E("50"));
    await expect(vault.harvest()).to.emit(vault, "Harvested");
    const acc1 = await vault.accRewardPerShare();
    expect(acc1).to.be.gt(acc0);

    const x0 = await X.balanceOf(user.address);
    await expect(vault.connect(user).claim(0)).to.emit(vault, "Claimed").withArgs(user.address, 0, E("50"));
    const x1 = await X.balanceOf(user.address);
    expect(x1 - x0).to.equal(E("50"));

    // After claim, pending is zero (no new harvest)
    expect(await vault.pending(0, user.address)).to.equal(0n);
  });

  it("claimAll aggregates claims across positions", async () => {
    // two positions with different tiers → different shares → floor per-position
    await vault.connect(user).deposit(E("10"), 0, ref.address);
    await vault.connect(user).deposit(E("20"), 2, ref.address);

    // accrue and harvest to vault
    await farm.setPending(pid, vault.target, E("30"));
    await vault.harvest();

    // compute exact expected = sum of per-position pending (matches contract math)
    const p0 = await vault.pending(0, user.address);
    const p1 = await vault.pending(1, user.address);
    const expected = p0 + p1;

    const before = await X.balanceOf(user.address);
    await expect(vault.connect(user).claimAll())
      .to.emit(vault, "ClaimedAll")
      .withArgs(user.address, expected);
    const after = await X.balanceOf(user.address);

    expect(after - before).to.equal(expected);
  });

  it("INV-VLT-07: unlock before time reverts; after time succeeds", async () => {
    await vault.connect(user).deposit(E("10"), 0, ref.address); // 30d
    await expect(vault.connect(user).unlock(0)).to.be.revertedWith("locked");

    await ff(31 * DAY);
    const lp0 = await LP.balanceOf(user.address);
    await expect(vault.connect(user).unlock(0)).to.emit(vault, "Unlocked").withArgs(user.address, 0, E("10"));
    const lp1 = await LP.balanceOf(user.address);
    expect(lp1 - lp0).to.equal(E("10"));
  });

  it("INV-VLT-08/09: unlockEarly applies penalty to LP and burns shares", async () => {
    if (vault.setEarlyPenaltyBips) await vault.setEarlyPenaltyBips(250); // 2.5%
    await vault.connect(user).deposit(E("100"), 2, ref.address);

    const lpU0 = await LP.balanceOf(user.address);
    const lpD0 = await LP.balanceOf(dao.address);

    await expect(vault.connect(user).unlockEarly(0))
      .to.emit(vault, "EarlyUnlocked");

    const lpU1 = await LP.balanceOf(user.address);
    const lpD1 = await LP.balanceOf(dao.address);

    expect(lpU1 - lpU0).to.equal(E("97.5"));
    expect(lpD1 - lpD0).to.equal(E("2.5"));

    expect(await vault.totalShares()).to.equal(0n);
  });

  it("INV-VLT-10: emergency mode blocks deposit but allows unlock", async () => {
    await vault.connect(user).deposit(E("5"), 1, ref.address);
    await vault.setEmergencyMode(true);

    await expect(vault.connect(user).deposit(E("1"), 0, ref.address)).to.be.revertedWith("emergency");
    // even if not past unlock time
    await expect(vault.connect(user).unlock(0)).to.emit(vault, "Unlocked");
  });

  it("INV-VLT-11: rescueToken cannot rescue LP or reward; can rescue others", async () => {
    // blocked tokens
    await expect(vault.rescueToken(LP.target, 1, owner.address)).to.be.revertedWith("protected");
    await expect(vault.rescueToken(X.target, 1, owner.address)).to.be.revertedWith("protected");

    // allowed other token
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const O = await ERC.deploy("OTK", "OTK", 18); await O.waitForDeployment();
    await O.mint(vault.target, E("7"));

    const b0 = await O.balanceOf(owner.address);
    await expect(vault.rescueToken(O.target, E("7"), owner.address)).to.emit(vault, "Rescued");
    const b1 = await O.balanceOf(owner.address);
    expect(b1 - b0).to.equal(E("7"));
  });

  it("INV-VLT-12: constructor reverts if farm.poolLpToken(pid) != lpToken", async () => {
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const LP2 = await ERC.deploy("LP2", "LP2", 18); await LP2.waitForDeployment();
    await farm.addPool(1, LP2.target);

    const V = await ethers.getContractFactory("ParagonLockingVault");
    await expect(
      V.deploy(owner.address, LP2.target, X.target, farm.target, pid /* wrong pid */, dao.address)
    ).to.be.revertedWith("pool/lp mismatch").catch(async () => {
      await expect(
        V.deploy(LP2.target, X.target, farm.target, pid, dao.address)
      ).to.be.revertedWith("pool/lp mismatch");
    });
  });
});
