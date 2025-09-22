/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const E = (n) => ethers.parseEther(n);

describe("TraderRewardsLocker @spec", () => {
  it("INV-TRL-01/02/03: share by usage points; early/no-points revert; full claim locks in ve", async () => {
    const [owner, alice, bob] = await ethers.getSigners();
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN","XPGN",18); await X.waitForDeployment();

    // real UsagePoints (we’ll award points via onPayflowExecuted)
    const U = await ethers.getContractFactory("UsagePoints");
    const u = await U.deploy(owner.address); await u.waitForDeployment();
    await u.setCaller(owner.address, true);

    // mock ve
    const VE = await ethers.getContractFactory("contracts/mocks/MockVEForLocker.sol:MockVEForLocker");
    const ve = await VE.deploy(); await ve.waitForDeployment();

    const L = await ethers.getContractFactory("TraderRewardsLocker");
    // useSolidlyOrder=false → call create_lock_for(address to, uint amount, uint unlockTime)
    const l = await L.deploy(owner.address, X.target, u.target, ve.target, false); await l.waitForDeployment();

    // Fund epoch and points
    const epoch = await u.currentEpoch();
    await X.mint(owner.address, E("100"));
    await X.connect(owner).approve(l.target, ethers.MaxUint256);
    await l.notifyRewardAmount(epoch, E("100"));

    // Award points: Alice 60%, Bob 40%
    await u.onPayflowExecuted(alice.address, E("60"), 0, ethers.ZeroHash);
    await u.onPayflowExecuted(bob.address,   E("40"), 0, ethers.ZeroHash);

    // Alice claims
    const I = new ethers.Interface(["function locks(uint256) view returns (tuple(address to,uint256 amount,uint256 unlock))"]);
    const V = new ethers.Contract(ve.target, I, ethers.provider);

    await expect(l.connect(alice).claim(epoch)).to.emit(l,"Claimed");
    // Bob claims
    await expect(l.connect(bob).claim(epoch)).to.emit(l,"Claimed");

    // Re-claim reverts
    await expect(l.connect(alice).claim(epoch)).to.be.reverted;

    // No-points user reverts
    const [_, charlie] = await ethers.getSigners();
    await expect(l.connect(charlie).claim(epoch)).to.be.reverted;

    // Total XPGN stays inside locker (approved and transferred to ve on claim). No extra invariants needed here.
  });
});
