/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const WEEK = 7 * 24 * 60 * 60;

async function ff(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}
async function chainNow() {
  return BigInt((await ethers.provider.getBlock("latest")).timestamp);
}
function ceilWeek(ts) {
  const W = BigInt(WEEK);
  return ((ts + W - 1n) / W) * W;
}

describe("VoterEscrow @spec", () => {
  it("INV-VE-02/03/04: lock bounds, decay, withdraw-after-unlock, supply consistency", async () => {
    const [owner, user] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    await X.mint(user.address, E("20"));
    await X.connect(user).approve(ve.target, ethers.MaxUint256);

    await expect(ve.connect(user).create_lock(0, Number(await chainNow()) + 8 * WEEK)).to.be.revertedWith("amount=0");

    const end2 = ceilWeek((await chainNow()) + BigInt(8 * WEEK));
    await expect(ve.connect(user).create_lock(E("20"), end2)).to.emit(ve, "Deposit");

    const p0 = await ve.balanceOf(user.address);
    await ff(WEEK);
    const p1 = await ve.balanceOf(user.address);
    expect(p1).to.be.lt(p0);

    const ts = await ve.totalSupply();
    const ub = await ve.balanceOf(user.address);
    const diff = ts > ub ? ts - ub : ub - ts;
    expect(diff).to.lte(1_000_000_000_000n);

    const now = await chainNow();
    const jump = end2 > now ? Number(end2 - now + 2n) : 2;
    await ff(jump);

    await expect(ve.connect(user).withdraw()).to.emit(ve, "Withdraw");
    expect(await ve.balanceOf(user.address)).to.equal(0n);
  });

  it("INV-VE-05/06/07: only reward depositor can create_lock_for and increase_amount_for", async () => {
    const [owner, depositor, user, other] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    await X.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address);
    await ve.waitForDeployment();

    await X.mint(depositor.address, E("10"));
    await X.connect(depositor).approve(ve.target, ethers.MaxUint256);
    await X.mint(other.address, E("10"));
    await X.connect(other).approve(ve.target, ethers.MaxUint256);

    const unlock = Number((await chainNow()) + BigInt(8 * WEEK));

    await expect(ve.connect(other)["create_lock_for(address,uint256,uint256)"](user.address, E("1"), unlock))
      .to.be.revertedWith("not reward depositor");

    await ve.setRewardDepositor(depositor.address, true);
    await expect(ve.connect(depositor)["create_lock_for(address,uint256,uint256)"](user.address, E("1"), unlock))
      .to.emit(ve, "Deposit");

    await expect(ve.connect(other).increase_amount_for(user.address, E("1")))
      .to.be.revertedWith("not reward depositor");

    await expect(ve.connect(depositor).increase_amount_for(user.address, E("1")))
      .to.emit(ve, "Deposit");
  });
});
