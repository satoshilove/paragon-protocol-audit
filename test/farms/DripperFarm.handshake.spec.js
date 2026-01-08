// test/farms/DripperFarm.handshake.spec.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

// Helpers
const FQCN_ERC20 = "contracts/mocks/MockERC20.sol:MockERC20"; // disambiguates the two MockERC20s

async function deployFixture() {
  const [deployer, user] = await ethers.getSigners();

  // --- Tokens ---
  const ERC20 = await ethers.getContractFactory(FQCN_ERC20);
  const reward = await ERC20.deploy("Reward", "RWD", 18);
  const lp = await ERC20.deploy("LP", "LP", 18);

  await reward.mint(deployer.address, ethers.parseEther("1000000"));
  await lp.mint(deployer.address, ethers.parseEther("1000000"));

  // --- Farm ---
  const Farm = await ethers.getContractFactory("ParagonFarmController");
  const currentBlock = await ethers.provider.getBlockNumber();
  const rewardPerBlock = ethers.parseEther("1");
  const farm = await Farm.deploy(deployer.address, reward.target, rewardPerBlock, currentBlock + 1);

  await (await farm.addPool(1000, lp.target, 0)).wait();

  // --- Dripper ---
  const Dripper = await ethers.getContractFactory("RewardDripperEscrow");
  const nowTs = (await ethers.provider.getBlock("latest")).timestamp;
  const ratePerSec = ethers.parseEther("10") / 3600n;

  const dripper = await Dripper.deploy(
    deployer.address,
    reward.target,
    await farm.getAddress(),
    nowTs,
    ratePerSec
  );

  // Fund dripper
  await reward.transfer(await dripper.getAddress(), ethers.parseEther("1000"));

  // Wire config
  await (
    await farm.setDripperConfig(
      await dripper.getAddress(),
      1,                       // lowWaterDays
      0,                       // cooldown
      ethers.parseEther("1")   // minDripAmount
    )
  ).wait();

  return { deployer, user, reward, lp, farm, dripper };
}

describe("Dripper↔Farm handshake", function () {
  it("drips after cooldown + min amount + runway", async function () {
    const { reward, farm } = await loadFixture(deployFixture);

    const farmAddr = await farm.getAddress();
    const beforeBal = await reward.balanceOf(farmAddr);
    expect(beforeBal).to.equal(0n);

    await time.increase(3600); // 1 hour

    await expect(farm.updatePool(0)).to.not.be.reverted;

    const afterBal = await reward.balanceOf(farmAddr);
    expect(afterBal).to.be.gt(beforeBal);
  });

  it("skips without reverting when dripper is underfunded", async function () {
    const { deployer, reward, farm, dripper } = await loadFixture(deployFixture);
    const farmAddr = await farm.getAddress();

    // Drain dripper:
    // Your hardened escrow has 3-arg rescue AND rewardToken rescue is limited to "excess".
    // So: first stop accrual (rate=0) and apply, then rescue exact balance.
    await (await dripper.setRatePerSec(0)).wait();
    await (await dripper.drip()).wait(); // apply accrual/cursor (safe even if sends 0)
    const bal = await reward.balanceOf(await dripper.getAddress());
    if (bal > 0n) {
      await (await dripper.rescue(reward.target, deployer.address, bal)).wait();
    }

    const dripperBal = await reward.balanceOf(await dripper.getAddress());
    expect(dripperBal).to.equal(0n);

    await time.increase(3600);

    const beforeBal = await reward.balanceOf(farmAddr);
    await expect(farm.updatePool(0)).to.not.be.reverted;
    const afterBal = await reward.balanceOf(farmAddr);
    expect(afterBal).to.equal(beforeBal);
  });
});
