// test/farms/DripperFarm.handshake.spec.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  loadFixture,
  time
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

// Helpers
const FQCN_ERC20 = "contracts/mocks/MockERC20.sol:MockERC20"; // <- disambiguates the two MockERC20s

async function deployFixture() {
  const [deployer, user] = await ethers.getSigners();

  // --- Tokens ---
  const ERC20 = await ethers.getContractFactory(FQCN_ERC20);
  const reward = await ERC20.deploy("Reward", "RWD", 18);
  const lp = await ERC20.deploy("LP", "LP", 18);

  // Mint a big stash to the deployer
  await reward.mint(deployer.address, ethers.parseEther("1000000"));
  await lp.mint(deployer.address, ethers.parseEther("1000000"));

  // --- Farm ---
  // constructor(address initialOwner, IERC20 rewardToken, uint256 rewardPerBlock, uint256 startBlock)
  const Farm = await ethers.getContractFactory("ParagonFarmController");
  const currentBlock = await ethers.provider.getBlockNumber();
  const rewardPerBlock = ethers.parseEther("1"); // 1 RWD / block (non-zero so _maybeTopUpFromDripper can compute need)
  const farm = await Farm.deploy(
    deployer.address,
    reward.target,
    rewardPerBlock,
    currentBlock + 1
  );

  // addPool(uint256 allocPoint, IERC20 lpToken, uint256 harvestDelay)
  await (await farm.addPool(1000, lp.target, 0)).wait();

  // --- Dripper ---
  // RewardDripperEscrow constructor:
  //   constructor(address owner_, IERC20 token_, address farm_, uint64 startTime_, uint192 ratePerSec_)
  const Dripper = await ethers.getContractFactory("RewardDripperEscrow");
  const nowTs = (await ethers.provider.getBlock("latest")).timestamp;
  // Target ~10 RWD/hour so we can easily pass minDripAmount after a short time jump
  const ratePerSec = ethers.parseEther("10") / 3600n;

  const dripper = await Dripper.deploy(
    deployer.address,
    reward.target,
    await farm.getAddress(),
    nowTs,
    ratePerSec
  );

  // Fund the dripper with enough tokens for a few drips
  await reward.transfer(await dripper.getAddress(), ethers.parseEther("1000"));

  // --- Wire farm <-> dripper and parameters ---
  // setDripperConfig(address _dripper, uint256 _days, uint64 _cooldown, uint256 _min)
  await (
    await farm.setDripperConfig(
      await dripper.getAddress(),
      1,                            // lowWaterDays (1 day runway)
      0,                            // dripCooldownSecs (no cooldown in tests)
      ethers.parseEther("1")        // minDripAmount
    )
  ).wait();

  return { deployer, user, reward, lp, farm, dripper };
}

describe("Dripper↔Farm handshake", function () {
  it("drips after cooldown + min amount + runway", async function () {
    const { reward, farm } = await loadFixture(deployFixture);

    const farmAddr = await farm.getAddress();

    // Farm starts with zero rewards available
    const beforeBal = await reward.balanceOf(farmAddr);
    expect(beforeBal).to.equal(0n);

    // Let some accrual happen on the dripper so pendingAccrued >= minDripAmount
    await time.increase(3600); // 1 hour

    // Trigger the farm's internal _maybeTopUpFromDripper via updatePool(pid=0)
    await expect(farm.updatePool(0)).to.not.be.reverted;

    const afterBal = await reward.balanceOf(farmAddr);
    expect(afterBal).to.be.gt(beforeBal); // should have received a top-up
  });

  it("skips without reverting when dripper is underfunded", async function () {
    const { deployer, reward, farm, dripper } = await loadFixture(deployFixture);
    const farmAddr = await farm.getAddress();

    // Drain the dripper balance to simulate underfunding
    await (await dripper.rescue(reward.target, deployer.address)).wait();
    const dripperBal = await reward.balanceOf(await dripper.getAddress());
    expect(dripperBal).to.equal(0n);

    // Let it accrue (pendingAccrued grows but balance is 0)
    await time.increase(3600);

    const beforeBal = await reward.balanceOf(farmAddr);

    // Should NOT revert; farm handles underfunded dripper gracefully
    await expect(farm.updatePool(0)).to.not.be.reverted;

    const afterBal = await reward.balanceOf(farmAddr);
    // With zero dripper balance, farm reward balance should remain unchanged
    expect(afterBal).to.equal(beforeBal);
  });
});
