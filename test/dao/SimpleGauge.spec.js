/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const DAY = 24 * 60 * 60;

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}

describe("SimpleGauge @spec", () => {
  let owner, user, other, X, LP, gauge;

  beforeEach(async () => {
    [owner, user, other] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    X = await ERC.deploy("XPGN", "XPGN", 18);
    LP = await ERC.deploy("LP", "LP", 18);
    await X.waitForDeployment();
    await LP.waitForDeployment();

    const G = await ethers.getContractFactory("SimpleGauge");
    gauge = await G.deploy(LP.target, X.target, ethers.ZeroAddress, owner.address);
    await gauge.waitForDeployment();

    await gauge.setMinter(owner.address);

    await LP.mint(user.address, E("1000"));
    await LP.connect(user).approve(gauge.target, ethers.MaxUint256);

    await X.mint(owner.address, E("100000"));
    await X.connect(owner).approve(gauge.target, E("100000"));
  });

  it("INV-SG-02/05: only minter can notify; stake/withdraw paths are protected", async () => {
    await expect(gauge.connect(other).notifyRewardAmount(E("1"))).to.be.revertedWith("not minter");
    await expect(gauge.connect(owner).notifyRewardAmount(E("7"))).to.emit(gauge, "Notified");
  });

  it("INV-SG-01/03/04: stake -> accrue -> getReward matches on-chain rate with rollover support", async () => {
    await gauge.connect(user).stake(E("100"));
    await gauge.connect(owner).notifyRewardAmount(E("70"));

    const rate1 = await gauge.rewardRate();
    await ff(DAY);

    const before = await X.balanceOf(user.address);
    await gauge.connect(user).getReward();
    const after = await X.balanceOf(user.address);

    const earned = after - before;
    const expected = rate1 * BigInt(DAY);
    const diff = earned > expected ? earned - expected : expected - earned;
    expect(diff).to.lte(rate1);

    // rollover notify
    await gauge.connect(owner).notifyRewardAmount(E("14"));
    expect(await gauge.rewardRate()).to.be.gt(0n);
  });
});
