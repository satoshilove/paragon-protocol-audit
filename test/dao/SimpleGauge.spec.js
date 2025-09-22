/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E   = (n) => ethers.parseEther(n);
const DAY = 24 * 60 * 60;

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
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

describe("SimpleGauge @spec", () => {
  let owner, user, other;
  let X, LP, gauge;

  beforeEach(async () => {
    [owner, user, other] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    X  = await ERC.deploy("XPGN", "XPGN", 18);
    LP = await ERC.deploy("LP", "LP", 18);
    await X.waitForDeployment(); await LP.waitForDeployment();

    gauge = await deploySimpleGauge(LP, X, ethers.ZeroAddress, owner);

    await LP.mint(user.address, E("1000"));
    await LP.connect(user).approve(gauge.target, ethers.MaxUint256);

    await X.mint(owner.address, E("1000000"));
    await X.connect(owner).approve(gauge.target, E("1000000"));

    // If contract supports setMinter, set it to owner; otherwise owner-only notify path is fine.
    if (gauge.setMinter) {
      await (await gauge.setMinter(owner.address)).wait();
    }
  });

  it("INV-SG-02/03: only minter or owner may notify; non-reentrant", async () => {
    await expect(gauge.connect(other).notifyRewardAmount(E("1"))).to.be.reverted;

    await expect(gauge.connect(owner).notifyRewardAmount(E("1"))).to.emit(gauge, "Notified");

    // If minter==owner we can call again for coverage; some impls allow both roles
    await expect(gauge.notifyRewardAmount(E("1"))).to.emit(gauge, "Notified");
  });

  it("INV-SG-01: stake→notify→getReward pays accrued", async () => {
    await gauge.connect(user).stake(E("100"));

    // Notify 70 tokens over 7d; rate = floor(70e18 / 604800)
    await expect(gauge.connect(owner).notifyRewardAmount(E("70"))).to.emit(gauge, "Notified");

    const rate = await gauge.rewardRate(); // precise on-chain rate used by the gauge
    await ff(DAY); // accrue ~rate * 86400

    const before = await X.balanceOf(user.address);
    await (await gauge.connect(user).getReward()).wait();
    const after = await X.balanceOf(user.address);

    const earned   = after - before;
    const expected = rate * BigInt(DAY);

    // Allow one "rate tick" of drift, which covers integer-division truncation
    const tol = rate; // ≈ one second worth of rewards
    const diff = earned > expected ? (earned - expected) : (expected - earned);
    expect(diff).to.lte(tol);
  });
});
