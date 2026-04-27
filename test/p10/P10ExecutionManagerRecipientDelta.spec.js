const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10ExecutionManager recipient-delta regression", function () {
  async function deployFixture() {
    const [owner, user, feeRecipient] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const tokenA = await ERC.deploy("Token A", "TKA", 18);
    const tokenB = await ERC.deploy("Token B", "TKB", 18);
    await tokenA.waitForDeployment();
    await tokenB.waitForDeployment();

    const FOT = await ethers.getContractFactory("contracts/mocks/MockFeeOnTransferERC20.sol:MockFeeOnTransferERC20");
    const fotOut = await FOT.deploy("Fee Out", "FOUT", 100); // 1%
    await fotOut.waitForDeployment();

    const Pricing = await ethers.getContractFactory("contracts/mocks/MockP10Pricing.sol:MockP10Pricing");
    const pricing = await Pricing.deploy();
    await pricing.waitForDeployment();

    const P10 = await ethers.getContractFactory("P10Token");
    const p10 = await P10.deploy(owner.address);
    await p10.waitForDeployment();

    const Manager = await ethers.getContractFactory("P10IndexManager");
    const manager = await Manager.deploy(
      owner.address,
      await p10.getAddress(),
      await pricing.getAddress()
    );
    await manager.waitForDeployment();

    const Vault = await ethers.getContractFactory("P10Vault");
    const vault = await Vault.deploy(owner.address, owner.address);
    await vault.waitForDeployment();
    await (await vault.setIndexManager(await manager.getAddress())).wait();

    const Exec = await ethers.getContractFactory("P10ExecutionManager");
    const exec = await Exec.deploy(
      owner.address,
      await manager.getAddress(),
      await vault.getAddress()
    );
    await exec.waitForDeployment();
    await (await vault.setExecutionManager(await exec.getAddress())).wait();

    const MockRouter = await ethers.getContractFactory("contracts/mocks/MockParagonRouter.sol:MockParagonRouter");
    const router = await MockRouter.deploy();
    await router.waitForDeployment();

    const Venue = await ethers.getContractFactory("P10VenueParagon");
    const venue = await Venue.deploy(
      owner.address,
      await router.getAddress(),
      await exec.getAddress()
    );
    await venue.waitForDeployment();

    await (await exec.whitelistVenue(await venue.getAddress(), true)).wait();

    await (await p10.setIndexManager(await manager.getAddress())).wait();
    await (await manager.setVault(await vault.getAddress())).wait();
    await (await manager.setExecutionManager(await exec.getAddress())).wait();
    await (await manager.setMintVenue(await venue.getAddress())).wait();
    await (await manager.setRedeemVenue(await venue.getAddress())).wait();
    await (await manager.setFeeRecipient(feeRecipient.address)).wait();

    await (await pricing.setPrice(await tokenA.getAddress(), E("2"), true)).wait();
    await (await pricing.setPrice(await tokenB.getAddress(), E("1"), true)).wait();
    await (await pricing.setPrice(await fotOut.getAddress(), E("1"), true)).wait();

    await (await manager.activateSnapshot(
      [await tokenA.getAddress(), await tokenB.getAddress()],
      [18, 18],
      [E("0.5"), E("1")]
    )).wait();

    await (await tokenA.mint(user.address, E("1000"))).wait();
    await (await tokenB.mint(user.address, E("1000"))).wait();

    await (await tokenA.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await tokenB.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await p10.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();

    // router inventory for output token
    await (await fotOut.mint(await router.getAddress(), E("100000"))).wait();

    // seed P10 to user
    await (await manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)).wait();

    return {
      owner,
      user,
      tokenA,
      tokenB,
      fotOut,
      p10,
      manager,
      exec,
      venue,
      router,
    };
  }

  async function futureDeadline(secondsAhead = 3600) {
    const block = await ethers.provider.getBlock("latest");
    return Number(block.timestamp) + secondsAhead;
  }

  function encodeSellVenueData(deadline, swaps) {
    return ethers.AbiCoder.defaultAbiCoder().encode(
      [
        "tuple(uint256 deadline, tuple(address[] path, uint256 amountIn, uint256 minOut, bool supportFeeOnTransfer)[] swaps)"
      ],
      [{ deadline, swaps }]
    );
  }

  it("reverts when recipient receives less than minOutput due to fee-on-transfer on final transfer", async function () {
    const { user, tokenA, tokenB, fotOut, manager } = await deployFixture();

    const deadline = await futureDeadline();

    const sellData = encodeSellVenueData(deadline, [
      {
        path: [await tokenA.getAddress(), await fotOut.getAddress()],
        amountIn: E("0.24975"),
        minOut: E("0.20"),
        supportFeeOnTransfer: false,
      },
      {
        path: [await tokenB.getAddress(), await fotOut.getAddress()],
        amountIn: E("0.4995"),
        minOut: E("0.40"),
        supportFeeOnTransfer: false,
      },
    ]);

    const minOutput = E("0.74925");

    await expect(
      manager.connect(user).redeemSingle(
        E("0.5"),
        await fotOut.getAddress(),
        user.address,
        minOutput,
        sellData
      )
    ).to.be.reverted;
  });

  it("succeeds when minOutput is below the actual recipient delta after transfer fees", async function () {
    const { user, tokenA, tokenB, fotOut, manager } = await deployFixture();

    const deadline = await futureDeadline();

    const sellData = encodeSellVenueData(deadline, [
      {
        path: [await tokenA.getAddress(), await fotOut.getAddress()],
        amountIn: E("0.24975"),
        minOut: E("0.20"),
        supportFeeOnTransfer: false,
      },
      {
        path: [await tokenB.getAddress(), await fotOut.getAddress()],
        amountIn: E("0.4995"),
        minOut: E("0.40"),
        supportFeeOnTransfer: false,
      },
    ]);

    // Nominal output = 0.74925
    // After 1% router->exec fee: 0.7417575
    // After 1% exec->user fee: ~0.734339925
    const relaxedMinOutput = E("0.734");

    const before = await fotOut.balanceOf(user.address);

    await expect(
      manager.connect(user).redeemSingle(
        E("0.5"),
        await fotOut.getAddress(),
        user.address,
        relaxedMinOutput,
        sellData
      )
    ).to.emit(manager, "Redeemed");

    const afterBal = await fotOut.balanceOf(user.address);
    const delta = afterBal - before;

    expect(delta).to.be.gte(relaxedMinOutput);
    expect(delta).to.be.lt(E("0.7417575"));
  });
});