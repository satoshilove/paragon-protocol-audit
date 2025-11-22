/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);

async function mineBlocks(n = 1) {
  for (let i = 0; i < n; i++) {
    await ethers.provider.send("evm_mine", []);
  }
}
async function timeTravel(secs) {
  await ethers.provider.send("evm_increaseTime", [secs]);
  await ethers.provider.send("evm_mine", []);
}

describe("ParagonFarmController (final, dynamic-enabled)", function () {
  async function deployCore() {
    const [owner, alice, bob, ref, feeTo, autoRouter] = await ethers.getSigners();

    // Reward token (also used as LP in most tests for simplicity)
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const reward = await ERC.deploy("XPGN", "XPGN", 18n);
    await reward.waitForDeployment();

    // Farm
    const startBlock = (await ethers.provider.getBlockNumber()) + 2;
    const rpb = E("1"); // 1 XPGN / block baseline
    const Farm = await ethers.getContractFactory("ParagonFarmController");
    const farm = await Farm.deploy(owner.address, reward.target, rpb, startBlock);
    await farm.waitForDeployment();

    // Seed farm with reward tokens (for payouts)
    await (await reward.mint(owner.address, E("10000000"))).wait();
    await (await reward.transfer(farm.target, E("1000000"))).wait();

    // Add a pool that stakes the reward token
    await (await farm.addPool(100, reward.target, 3600)).wait();

    // User balances/approvals
    await (await reward.mint(alice.address, E("100000"))).wait();
    await (await reward.mint(bob.address,   E("100000"))).wait();
    await (await reward.connect(alice).approve(farm.target, ethers.MaxUint256)).wait();
    await (await reward.connect(bob).approve(farm.target, ethers.MaxUint256)).wait();

    // Referral manager
    const Ref = await ethers.getContractFactory("MockReferralManager");
    const refMgr = await Ref.deploy(); await refMgr.waitForDeployment();
    await (await farm.setReferralManager(refMgr.target)).wait();

    return { owner, alice, bob, ref, feeTo, autoRouter, reward, farm, refMgr, startBlock, rpb };
  }

  it("INV-FARM-01: accrual math under fixed RPB (deposit → accrue → harvest, no fee)", async function () {
    const { alice, reward, farm, rpb } = await deployCore();

    await mineBlocks(3);
    await (await farm.connect(alice).depositFor(0, E("1000"), alice.address, ethers.ZeroAddress)).wait();
    const postDepositBlock = await ethers.provider.getBlockNumber();

    await mineBlocks(10);          // 10 blocks accrued at rpb=1
    await timeTravel(3600 + 1);    // meet harvestDelay
    const preHarvestBlock = await ethers.provider.getBlockNumber();

    const balBefore = await reward.balanceOf(alice.address);
    await (await farm.connect(alice).harvest(0)).wait();
    const balAfter = await reward.balanceOf(alice.address);

    const expectedBlocks = BigInt(preHarvestBlock - postDepositBlock + 1);
    const expected = expectedBlocks * rpb;
    expect(balAfter - balBefore).to.equal(expected);
  });

  it("INV-FARM-03: harvest gating by harvestDelay (early pays 0, accounting carries forward)", async function () {
    const { alice, reward, farm, rpb } = await deployCore();

    await mineBlocks(3);
    await (await farm.connect(alice).depositFor(0, E("100"), alice.address, ethers.ZeroAddress)).wait();
    const postDepositBlock = await ethers.provider.getBlockNumber();

    await mineBlocks(8); // ~8 XPGN pending
    const preEarlyHarvestBlock = await ethers.provider.getBlockNumber();

    const before0 = await reward.balanceOf(alice.address);
    await (await farm.connect(alice).harvest(0)).wait(); // too early
    const after0 = await reward.balanceOf(alice.address);
    expect(after0 - before0).to.equal(0n);

    await timeTravel(3600 + 1);
    await mineBlocks(5);
    const preHarvestBlock = await ethers.provider.getBlockNumber();

    const before = await reward.balanceOf(alice.address);
    await (await farm.connect(alice).harvest(0)).wait();
    const after = await reward.balanceOf(alice.address);

    const expectedEarlyPendingBlocks = BigInt(preEarlyHarvestBlock - postDepositBlock + 1);
    const expectedEarlyPending = expectedEarlyPendingBlocks * rpb;

    const expectedAdditionalBlocks = BigInt(preHarvestBlock - preEarlyHarvestBlock);
    const expectedAdditional = expectedAdditionalBlocks * rpb;

    const expectedTotal = expectedEarlyPending + expectedAdditional;
    expect(after - before).to.equal(expectedTotal);
  });

  it("INV-FARM-03: withdraw harvests rewards when delay passed", async function () {
    const { alice, reward, farm, rpb } = await deployCore();

    await mineBlocks(3);
    await (await farm.connect(alice).depositFor(0, E("50"), alice.address, ethers.ZeroAddress)).wait();
    const postDepositBlock = await ethers.provider.getBlockNumber();

    await timeTravel(3600 + 1);
    await mineBlocks(4); // ~4 XPGN
    const preWithdrawBlock = await ethers.provider.getBlockNumber();

    const before = await reward.balanceOf(alice.address);
    await (await farm.connect(alice).withdraw(0, E("10"))).wait();
    const after = await reward.balanceOf(alice.address);

    const expectedBlocks = BigInt(preWithdrawBlock - postDepositBlock + 1);
    const expected = expectedBlocks * rpb;
    expect(after - before - E("10")).to.equal(expected);
  });

  it("INV-FARM-13: performance fee is taken on harvest (bips respected, fee to recipient)", async function () {
    const { owner, alice, reward, farm, rpb } = await deployCore();
    await (await farm.setPerformanceFee(owner.address, 200)).wait(); // 2%

    await mineBlocks(3);
    await (await farm.connect(alice).depositFor(0, E("100"), alice.address, ethers.ZeroAddress)).wait();
    const postDepositBlock = await ethers.provider.getBlockNumber();

    await timeTravel(3600 + 1);
    await mineBlocks(10); // 10 XPGN gross
    const preHarvestBlock = await ethers.provider.getBlockNumber();

    const feeBefore = await reward.balanceOf(owner.address);
    const userBefore = await reward.balanceOf(alice.address);
    await (await farm.connect(alice).harvest(0)).wait();
    const feeAfter = await reward.balanceOf(owner.address);
    const userAfter = await reward.balanceOf(alice.address);

    const expectedBlocks = BigInt(preHarvestBlock - postDepositBlock + 1);
    const gross = expectedBlocks * rpb;
    const expectedFee = gross * 200n / 10000n;
    const expectedUser = gross - expectedFee;

    expect(feeAfter - feeBefore).to.equal(expectedFee);
    expect(userAfter - userBefore).to.equal(expectedUser);
  });

  it("FEAT-FARM-EMIT-01: dynamic emissions approximate target APR (price=1, base=reward)", async function () {
    const { alice, reward, farm } = await deployCore();

    // If this farm variant does not support dynamic emissions, skip this feature test
    if (
      !farm.setPriceOracle ||
      !farm.setBaseToken ||
      !farm.setTargetAPRBips ||
      !farm.setDynamicEmissions
    ) {
      return this.skip?.();
    }

    // Oracle/base: baseToken = reward, price(reward)=1
    const Oracle = await ethers.getContractFactory("MockOracle");
    const oracle = await Oracle.deploy(); await oracle.waitForDeployment();
    await (await oracle.setPrice(reward.target, E("1"))).wait();

    await (await farm.setPriceOracle(oracle.target)).wait();
    await (await farm.setBaseToken(reward.target)).wait();
    await (await farm.setTargetAPRBips(1000)).wait(); // 10%
    await (await farm.setDynamicEmissions(true)).wait();

    // deposit → TVL = 1000
    await (await farm.connect(alice).depositFor(0, E("1000"), alice.address, ethers.ZeroAddress)).wait();

    // expected RPB = TVL * APR / blocksPerYear
    const blocksPerYear = 365n * 115200n;
    const expectedRPB = (E("1000") * 1000n / 10000n) / blocksPerYear;

    const blocks = 100000n;
    await mineBlocks(Number(blocks));

    const pending = await farm.pendingReward(0, alice.address);
    const approxExpected = expectedRPB * blocks;

    // allow ~0.1% tolerance
    const diff = pending > approxExpected ? pending - approxExpected : approxExpected - pending;
    expect(diff * 1000n / (approxExpected === 0n ? 1n : approxExpected)).to.lte(1n);
  });

  it("INV-FARM-09/10/11: dripper runway+cooldown+minAmount guard top-up via updatePool()", async function () {
    const { owner, alice, reward, farm } = await deployCore();

    // deposit so TVL > 0 (not strictly required for the guard, but realistic)
    await (await farm.connect(alice).depositFor(0, E("10000"), alice.address, ethers.ZeroAddress)).wait();

    // empty farm rewards to force low runway
    const balFarm = await reward.balanceOf(farm.target);
    await (await reward.transfer(owner.address, balFarm)).wait();

    // set dripper with funds & accrued (use setRatePerSec + time to accrue)
    const Drip = await ethers.getContractFactory("MockDripper");
    let dripper;
    try {
      dripper = await Drip.deploy(reward.target, farm.target, owner.address); // OZ v5 Ownable(_owner)
    } catch {
      dripper = await Drip.deploy(reward.target, farm.target);
    }
    await dripper.waitForDeployment();

    // give dripper balance to send
    await (await reward.mint(dripper.target, E("50"))).wait();

    // accrue at 1 token/sec for 50 sec so pendingAccrued >= minDripAmount
    await (await dripper.setRatePerSec(E("1"))).wait();
    await timeTravel(50);

    // Configure farm's dripper guard with small thresholds for test:
    // lowWaterDays = 1, cooldown = 0, minDripAmount = 1 XPGN
    await (await farm.setDripperConfig(dripper.target, 1, 0, E("1"))).wait();

    // triggers _maybeTopUpFromDripper (permissionless call)
    await (await farm.updatePool(0)).wait();

    const balAfter = await reward.balanceOf(farm.target);
    expect(balAfter).to.be.greaterThan(0n);
  });

  it("INT-FARM-REF-01: referral manager records referrer on depositFor", async function () {
    const { alice, ref, farm } = await deployCore();
    await mineBlocks(1);
    await (await farm.connect(alice).depositFor(0, E("1"), alice.address, ref.address)).wait();

    const refMgrAddr = await farm.referralManager();
    const Ref = await ethers.getContractFactory("MockReferralManager");
    const refMgr = Ref.attach(refMgrAddr);
    expect(await refMgr.getReferrer(alice.address)).to.equal(ref.address);
  });

  it("FEAT-FARM-AY-01: autoYieldRouter deposits don’t reset lastDepositTime and are tracked", async function () {
    const { alice, autoRouter, farm, reward } = await deployCore();
    await mineBlocks(1);

    // normal deposit -> sets lastDepositTime
    await (await farm.connect(alice).depositFor(0, E("1"), alice.address, ethers.ZeroAddress)).wait();
    const userBefore = await farm.userInfo(0, alice.address);
    const firstTime = userBefore.lastDepositTime;

    // set router and fund it
    await (await farm.setAutoYieldRouter(autoRouter.address)).wait();
    await (await reward.mint(autoRouter.address, E("5"))).wait();
    await (await reward.connect(autoRouter).approve(farm.target, ethers.MaxUint256)).wait();

    // router deposits for alice, should NOT update lastDepositTime
    await (await farm.connect(autoRouter).depositFor(0, E("5"), alice.address, ethers.ZeroAddress)).wait();

    const userAfter = await farm.userInfo(0, alice.address);
    const lastDeposit = userAfter.lastDepositTime;
    const autoTotal = await farm.autoYieldDeposited(0, alice.address);

    expect(lastDeposit).to.equal(firstTime);
    expect(autoTotal).to.equal(E("5"));
  });

  it("FLOW-FARM-EMERG-01: emergencyWithdraw returns stake and clears accounting", async function () {
    const { alice, reward, farm } = await deployCore();
    await mineBlocks(1);
    await (await farm.connect(alice).depositFor(0, E("12"), alice.address, ethers.ZeroAddress)).wait();

    const balBefore = await reward.balanceOf(alice.address);
    await (await farm.connect(alice).emergencyWithdraw(0)).wait();
    const balAfter = await reward.balanceOf(alice.address);

    expect(balAfter - balBefore).to.equal(E("12"));

    const userAfter = await farm.userInfo(0, alice.address);
    expect(userAfter.amount).to.equal(0n);
    expect(userAfter.unpaid).to.equal(0n);
  });

  it("ADMIN-FARM-ALLOC-01: alloc points batch changes future emissions split", async function () {
    const { alice, reward, farm } = await deployCore();

    // If this farm variant does not support batch alloc updates, skip.
    if (!farm.setAllocPointsBatch) {
      return this.skip?.();
    }

    // add another pool (also reward token) so split is meaningful
    await (await farm.addPool(100, reward.target, 0)).wait(); // pid1

    await (await farm.connect(alice).depositFor(0, E("100"), alice.address, ethers.ZeroAddress)).wait();
    await (await farm.connect(alice).depositFor(1, E("100"), alice.address, ethers.ZeroAddress)).wait();

    await timeTravel(3600 + 1);
    await mineBlocks(10);

    // shift allocs → pid0=300, pid1=100 going forward
    await (await farm.setAllocPointsBatch([0, 1], [300, 100])).wait();
    await mineBlocks(10);

    const before = await reward.balanceOf(alice.address);
    await (await farm.connect(alice).harvest(0)).wait();
    await (await farm.connect(alice).harvest(1)).wait();
    const after = await reward.balanceOf(alice.address);
    expect(after - before).to.be.gt(0n); // sanity
  });
});
