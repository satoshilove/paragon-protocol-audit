/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const WEEK = 7 * 24 * 60 * 60;

async function ff(sec){ await ethers.provider.send("evm_increaseTime",[sec]); await ethers.provider.send("evm_mine",[]); }
async function chainNow(){ return BigInt((await ethers.provider.getBlock("latest")).timestamp); }
function ceilWeek(ts){ const W = BigInt(WEEK); return ((ts + W - 1n) / W) * W; }

describe("VoterEscrow @spec", () => {
  it("INV-VE-02: bounds on lock creation & extension", async () => {
    const [owner, user] = await ethers.getSigners();
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN","XPGN",18); await X.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address); await ve.waitForDeployment();

    await X.mint(user.address, E("100"));
    await X.connect(user).approve(ve.target, ethers.MaxUint256);

    await expect(ve.connect(user).create_lock(0, WEEK)).to.be.reverted; // amount=0

    // lock 8 weeks (absolute, week-aligned)
    const end8 = ceilWeek(await chainNow() + BigInt(8 * WEEK));
    await expect(ve.connect(user).create_lock(E("10"), end8)).to.not.be.reverted;

    // extend to 9 weeks (absolute, week-aligned)
    const end9 = ceilWeek(await chainNow() + BigInt(9 * WEEK));
    await expect(ve.connect(user).increase_unlock_time(end9)).to.not.be.reverted;
  });

  it("INV-VE-01/03/04: voting power decays; withdraw after unlock; supply ≈ sum(user)", async () => {
    const [owner, user] = await ethers.getSigners();
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN","XPGN",18); await X.waitForDeployment();

    const VE = await ethers.getContractFactory("VoterEscrow");
    const ve = await VE.deploy(X.target, owner.address); await ve.waitForDeployment();

    await X.mint(user.address, E("20"));
    await X.connect(user).approve(ve.target, ethers.MaxUint256);

    const end2 = ceilWeek(await chainNow() + BigInt(2 * WEEK));
    await ve.connect(user).create_lock(E("20"), end2);

    const p0 = await ve.balanceOf(user.address);
    await ff(WEEK);
    const p1 = await ve.balanceOf(user.address);
    expect(p1).to.be.lt(p0);

    const ts = await ve.totalSupply();
    const ub = await ve.balanceOf(user.address);
    const diff = ts > ub ? ts - ub : ub - ts;
    expect(diff).to.lte(1_000_000_000_000n); // ≤ 1e12 wei tolerance

    // Jump exactly past unlock, regardless of week alignment
    const now = await chainNow();
    const jump = end2 > now ? Number(end2 - now + 2n) : 2; // +2s buffer
    await ff(jump);

    await expect(ve.connect(user).withdraw()).to.emit(ve, "Withdrawn");
    expect(await ve.balanceOf(user.address)).to.equal(0n);
  });
});
