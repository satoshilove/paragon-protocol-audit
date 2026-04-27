const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10VenueParagon", function () {
  async function deployFixture() {
    const [owner, execManager, other] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const tokenA = await ERC.deploy("Token A", "TKA", 18);
    const tokenB = await ERC.deploy("Token B", "TKB", 18);
    const tokenC = await ERC.deploy("Token C", "TKC", 6);
    await tokenA.waitForDeployment();
    await tokenB.waitForDeployment();
    await tokenC.waitForDeployment();

    const Router = await ethers.getContractFactory("contracts/mocks/MockParagonRouter.sol:MockParagonRouter");
    const router = await Router.deploy();
    await router.waitForDeployment();

    const Venue = await ethers.getContractFactory("P10VenueParagon");
    const venue = await Venue.deploy(
      owner.address,
      await router.getAddress(),
      execManager.address
    );
    await venue.waitForDeployment();

    // preload router with output inventory
    await (await tokenA.mint(await router.getAddress(), E("100000"))).wait();
    await (await tokenB.mint(await router.getAddress(), E("100000"))).wait();
    await (await tokenC.mint(await router.getAddress(), 100_000_000_000)).wait();

    return {
      owner,
      execManager,
      other,
      tokenA,
      tokenB,
      tokenC,
      router,
      venue,
    };
  }

  async function futureDeadline(secondsAhead = 3600) {
    const block = await ethers.provider.getBlock("latest");
    return Number(block.timestamp) + secondsAhead;
  }

  async function expiredDeadline() {
    const block = await ethers.provider.getBlock("latest");
    return Number(block.timestamp) - 1;
  }

  function encodeBuyVenueData(deadline, swaps) {
    return ethers.AbiCoder.defaultAbiCoder().encode(
      [
        "tuple(uint256 deadline, tuple(address[] path, uint256 amountIn, uint256 minOut, bool supportFeeOnTransfer)[] swaps)"
      ],
      [{ deadline, swaps }]
    );
  }

  function encodeSellVenueData(deadline, swaps) {
    return ethers.AbiCoder.defaultAbiCoder().encode(
      [
        "tuple(uint256 deadline, tuple(address[] path, uint256 amountIn, uint256 minOut, bool supportFeeOnTransfer)[] swaps)"
      ],
      [{ deadline, swaps }]
    );
  }

  it("only execution manager can call buyBasketSingleToken", async function () {
    const { other, tokenB, venue } = await deployFixture();

    const deadline = await futureDeadline();
    const venueData = encodeBuyVenueData(deadline, []);

    await expect(
      venue.connect(other).buyBasketSingleToken(
        await tokenB.getAddress(),
        E("1"),
        [],
        other.address,
        venueData
      )
    ).to.be.reverted;
  });

  it("same-token buy leg transfers directly to receiver", async function () {
    const { execManager, tokenB, venue } = await deployFixture();

    await (await tokenB.mint(await venue.getAddress(), E("1"))).wait();

    const deadline = await futureDeadline();

    const legs = [{
      token: await tokenB.getAddress(),
      targetAmount: E("1"),
      minAmount: E("1"),
    }];

    const venueData = encodeBuyVenueData(deadline, [
      {
        path: [],
        amountIn: E("1"),
        minOut: E("1"),
        supportFeeOnTransfer: false,
      }
    ]);

    const before = await tokenB.balanceOf(execManager.address);

    const tx = await venue.connect(execManager).buyBasketSingleToken(
      await tokenB.getAddress(),
      E("1"),
      legs,
      execManager.address,
      venueData
    );
    await tx.wait();

    const afterBal = await tokenB.balanceOf(execManager.address);
    expect(afterBal - before).to.equal(E("1"));
  });

  it("buyBasketSingleToken swaps via router and delivers output to receiver", async function () {
    const { execManager, tokenA, tokenB, venue } = await deployFixture();

    await (await tokenB.mint(await venue.getAddress(), E("1"))).wait();

    const deadline = await futureDeadline();

    const legs = [{
      token: await tokenA.getAddress(),
      targetAmount: E("1"),
      minAmount: E("1"),
    }];

    const venueData = encodeBuyVenueData(deadline, [
      {
        path: [await tokenB.getAddress(), await tokenA.getAddress()],
        amountIn: E("1"),
        minOut: E("1"),
        supportFeeOnTransfer: false,
      }
    ]);

    const before = await tokenA.balanceOf(execManager.address);

    await (await venue.connect(execManager).buyBasketSingleToken(
      await tokenB.getAddress(),
      E("1"),
      legs,
      execManager.address,
      venueData
    )).wait();

    const afterBal = await tokenA.balanceOf(execManager.address);
    expect(afterBal - before).to.equal(E("1"));
  });

  it("reverts buy when router under-delivers below minOut", async function () {
    const { execManager, tokenA, tokenB, venue, router } = await deployFixture();

    await (await tokenB.mint(await venue.getAddress(), E("1"))).wait();
    await (await router.setMode(1)).wait(); // UNDER_DELIVER

    const deadline = await futureDeadline();

    const legs = [{
      token: await tokenA.getAddress(),
      targetAmount: E("1"),
      minAmount: E("0.9"),
    }];

    const venueData = encodeBuyVenueData(deadline, [
      {
        path: [await tokenB.getAddress(), await tokenA.getAddress()],
        amountIn: E("1"),
        minOut: E("0.9"),
        supportFeeOnTransfer: false,
      }
    ]);

    await expect(
      venue.connect(execManager).buyBasketSingleToken(
        await tokenB.getAddress(),
        E("1"),
        legs,
        execManager.address,
        venueData
      )
    ).to.be.reverted;
  });

  it("reverts buy when router sends output to wrong receiver", async function () {
    const { execManager, tokenA, tokenB, venue, router } = await deployFixture();

    await (await tokenB.mint(await venue.getAddress(), E("1"))).wait();
    await (await router.setMode(2)).wait(); // WRONG_RECEIVER

    const deadline = await futureDeadline();

    const legs = [{
      token: await tokenA.getAddress(),
      targetAmount: E("1"),
      minAmount: E("1"),
    }];

    const venueData = encodeBuyVenueData(deadline, [
      {
        path: [await tokenB.getAddress(), await tokenA.getAddress()],
        amountIn: E("1"),
        minOut: E("1"),
        supportFeeOnTransfer: false,
      }
    ]);

    await expect(
      venue.connect(execManager).buyBasketSingleToken(
        await tokenB.getAddress(),
        E("1"),
        legs,
        execManager.address,
        venueData
      )
    ).to.be.reverted;
  });

  it("same-token sell leg transfers directly to recipient", async function () {
    const { execManager, tokenA, venue } = await deployFixture();

    await (await tokenA.mint(await venue.getAddress(), E("1"))).wait();

    const deadline = await futureDeadline();

    const legs = [{
      token: await tokenA.getAddress(),
      targetAmount: E("1"),
      minAmount: E("1"),
    }];

    const venueData = encodeSellVenueData(deadline, [
      {
        path: [],
        amountIn: E("1"),
        minOut: E("1"),
        supportFeeOnTransfer: false,
      }
    ]);

    const before = await tokenA.balanceOf(execManager.address);

    const out = await venue.connect(execManager).sellBasketToSingleToken.staticCall(
      legs,
      await tokenA.getAddress(),
      E("1"),
      execManager.address,
      venueData
    );

    await (await venue.connect(execManager).sellBasketToSingleToken(
      legs,
      await tokenA.getAddress(),
      E("1"),
      execManager.address,
      venueData
    )).wait();

    const afterBal = await tokenA.balanceOf(execManager.address);
    expect(afterBal - before).to.equal(E("1"));
    expect(out).to.equal(E("1"));
  });

  it("sellBasketToSingleToken swaps via router and delivers output to recipient", async function () {
    const { execManager, tokenA, tokenB, venue } = await deployFixture();

    await (await tokenA.mint(await venue.getAddress(), E("1"))).wait();

    const deadline = await futureDeadline();

    const legs = [{
      token: await tokenA.getAddress(),
      targetAmount: E("1"),
      minAmount: E("1"),
    }];

    const venueData = encodeSellVenueData(deadline, [
      {
        path: [await tokenA.getAddress(), await tokenB.getAddress()],
        amountIn: E("1"),
        minOut: E("1"),
        supportFeeOnTransfer: false,
      }
    ]);

    const before = await tokenB.balanceOf(execManager.address);

    const out = await venue.connect(execManager).sellBasketToSingleToken.staticCall(
      legs,
      await tokenB.getAddress(),
      E("1"),
      execManager.address,
      venueData
    );

    await (await venue.connect(execManager).sellBasketToSingleToken(
      legs,
      await tokenB.getAddress(),
      E("1"),
      execManager.address,
      venueData
    )).wait();

    const afterBal = await tokenB.balanceOf(execManager.address);
    expect(afterBal - before).to.equal(E("1"));
    expect(out).to.equal(E("1"));
  });

  it("reverts sell when router under-delivers below minOut", async function () {
    const { execManager, tokenA, tokenB, venue, router } = await deployFixture();

    await (await tokenA.mint(await venue.getAddress(), E("1"))).wait();
    await (await router.setMode(1)).wait(); // UNDER_DELIVER

    const deadline = await futureDeadline();

    const legs = [{
      token: await tokenA.getAddress(),
      targetAmount: E("1"),
      minAmount: E("1"),
    }];

    const venueData = encodeSellVenueData(deadline, [
      {
        path: [await tokenA.getAddress(), await tokenB.getAddress()],
        amountIn: E("1"),
        minOut: E("0.9"),
        supportFeeOnTransfer: false,
      }
    ]);

    await expect(
      venue.connect(execManager).sellBasketToSingleToken(
        legs,
        await tokenB.getAddress(),
        E("0.9"),
        execManager.address,
        venueData
      )
    ).to.be.reverted;
  });

  it("supports fee-on-transfer router path flag", async function () {
    const { execManager, tokenA, tokenB, venue } = await deployFixture();

    await (await tokenA.mint(await venue.getAddress(), E("1"))).wait();

    const deadline = await futureDeadline();

    const legs = [{
      token: await tokenA.getAddress(),
      targetAmount: E("1"),
      minAmount: E("1"),
    }];

    const venueData = encodeSellVenueData(deadline, [
      {
        path: [await tokenA.getAddress(), await tokenB.getAddress()],
        amountIn: E("1"),
        minOut: E("1"),
        supportFeeOnTransfer: true,
      }
    ]);

    await expect(
      venue.connect(execManager).sellBasketToSingleToken(
        legs,
        await tokenB.getAddress(),
        E("1"),
        execManager.address,
        venueData
      )
    ).to.not.be.reverted;
  });

  it("reverts on expired deadline", async function () {
    const { execManager, tokenA, tokenB, venue } = await deployFixture();

    await (await tokenA.mint(await venue.getAddress(), E("1"))).wait();

    const deadline = await expiredDeadline();

    const legs = [{
      token: await tokenA.getAddress(),
      targetAmount: E("1"),
      minAmount: E("1"),
    }];

    const venueData = encodeSellVenueData(deadline, [
      {
        path: [await tokenA.getAddress(), await tokenB.getAddress()],
        amountIn: E("1"),
        minOut: E("1"),
        supportFeeOnTransfer: false,
      }
    ]);

    await expect(
      venue.connect(execManager).sellBasketToSingleToken(
        legs,
        await tokenB.getAddress(),
        E("1"),
        execManager.address,
        venueData
      )
    ).to.be.reverted;
  });
});