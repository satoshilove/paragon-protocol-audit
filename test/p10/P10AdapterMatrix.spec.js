const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10OneInchAdapter parameter matrix", function () {
  async function deployFixture() {
    const [owner, caller, other, recipient] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const tokenIn = await ERC.deploy("Token In", "TIN", 18);
    const tokenOut = await ERC.deploy("Token Out", "TOUT", 18);
    await tokenIn.waitForDeployment();
    await tokenOut.waitForDeployment();

    const MockRouter = await ethers.getContractFactory("contracts/mocks/Mock1inchRouterV6.sol:Mock1inchRouterV6");
    const router = await MockRouter.deploy();
    await router.waitForDeployment();

    const Adapter = await ethers.getContractFactory("P10OneInchAdapter");
    const adapter = await Adapter.deploy(
      owner.address,
      caller.address,
      await router.getAddress()
    );
    await adapter.waitForDeployment();

    await (await tokenIn.mint(caller.address, E("10"))).wait();
    await (await tokenOut.mint(await router.getAddress(), E("100"))).wait();

    // caller funds adapter directly because execute expects funds already present there
    await (await tokenIn.connect(caller).transfer(await adapter.getAddress(), E("1"))).wait();

    return { owner, caller, other, recipient, tokenIn, tokenOut, router, adapter };
  }

  function desc(adapter, tokenIn, tokenOut, amount, minReturnAmount, srcReceiver, dstReceiver) {
    return {
      srcToken: tokenIn,
      dstToken: tokenOut,
      srcReceiver,
      dstReceiver,
      amount,
      minReturnAmount,
      flags: 0
    };
  }

  it("rejects wrong srcToken", async function () {
    const { caller, recipient, tokenIn, tokenOut, adapter } = await deployFixture();

    const badDesc = desc(
      await adapter.getAddress(),
      await tokenOut.getAddress(),
      await tokenOut.getAddress(),
      E("1"),
      E("1"),
      await adapter.getAddress(),
      await adapter.getAddress()
    );

    await expect(
      adapter.connect(caller).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("1"),
        badDesc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        ethers.ZeroAddress,
        recipient.address
      )
    ).to.be.reverted;
  });

  it("rejects wrong dstToken", async function () {
    const { caller, recipient, tokenIn, tokenOut, adapter } = await deployFixture();

    const badDesc = desc(
      await adapter.getAddress(),
      await tokenIn.getAddress(),
      await tokenIn.getAddress(),
      E("1"),
      E("1"),
      await adapter.getAddress(),
      await adapter.getAddress()
    );

    await expect(
      adapter.connect(caller).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("1"),
        badDesc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        ethers.ZeroAddress,
        recipient.address
      )
    ).to.be.reverted;
  });

  it("rejects wrong desc.amount", async function () {
    const { caller, recipient, tokenIn, tokenOut, adapter } = await deployFixture();

    const badDesc = desc(
      await adapter.getAddress(),
      await tokenIn.getAddress(),
      await tokenOut.getAddress(),
      E("0.5"),
      E("1"),
      await adapter.getAddress(),
      await adapter.getAddress()
    );

    await expect(
      adapter.connect(caller).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("1"),
        badDesc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        ethers.ZeroAddress,
        recipient.address
      )
    ).to.be.reverted;
  });

  it("rejects wrong srcReceiver", async function () {
    const { caller, recipient, tokenIn, tokenOut, adapter } = await deployFixture();

    const badDesc = desc(
      await adapter.getAddress(),
      await tokenIn.getAddress(),
      await tokenOut.getAddress(),
      E("1"),
      E("1"),
      recipient.address,
      await adapter.getAddress()
    );

    await expect(
      adapter.connect(caller).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("1"),
        badDesc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        ethers.ZeroAddress,
        recipient.address
      )
    ).to.be.reverted;
  });

  it("rejects wrong dstReceiver", async function () {
    const { caller, recipient, tokenIn, tokenOut, adapter } = await deployFixture();

    const badDesc = desc(
      await adapter.getAddress(),
      await tokenIn.getAddress(),
      await tokenOut.getAddress(),
      E("1"),
      E("1"),
      await adapter.getAddress(),
      recipient.address
    );

    await expect(
      adapter.connect(caller).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("1"),
        badDesc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        ethers.ZeroAddress,
        recipient.address
      )
    ).to.be.reverted;
  });

  it("rejects disallowed nonzero executor", async function () {
    const { caller, other, recipient, tokenIn, tokenOut, adapter } = await deployFixture();

    const goodDesc = desc(
      await adapter.getAddress(),
      await tokenIn.getAddress(),
      await tokenOut.getAddress(),
      E("1"),
      E("1"),
      await adapter.getAddress(),
      await adapter.getAddress()
    );

    await expect(
      adapter.connect(caller).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("1"),
        goodDesc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        other.address,
        recipient.address
      )
    ).to.be.reverted;
  });

  it("rejects nonzero native value", async function () {
    const { caller, recipient, tokenIn, tokenOut, adapter } = await deployFixture();

    const goodDesc = desc(
      await adapter.getAddress(),
      await tokenIn.getAddress(),
      await tokenOut.getAddress(),
      E("1"),
      E("1"),
      await adapter.getAddress(),
      await adapter.getAddress()
    );

    await expect(
      adapter.connect(caller).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("1"),
        goodDesc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        ethers.ZeroAddress,
        recipient.address,
        { value: 1 }
      )
    ).to.be.reverted;
  });

  it("rejects paused adapter", async function () {
    const { owner, caller, recipient, tokenIn, tokenOut, adapter } = await deployFixture();
    await (await adapter.connect(owner).pause()).wait();

    const goodDesc = desc(
      await adapter.getAddress(),
      await tokenIn.getAddress(),
      await tokenOut.getAddress(),
      E("1"),
      E("1"),
      await adapter.getAddress(),
      await adapter.getAddress()
    );

    await expect(
      adapter.connect(caller).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("1"),
        goodDesc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        ethers.ZeroAddress,
        recipient.address
      )
    ).to.be.reverted;
  });

  it("rejects return amount below min", async function () {
    const { caller, recipient, tokenIn, tokenOut, adapter } = await deployFixture();

    const goodDesc = desc(
      await adapter.getAddress(),
      await tokenIn.getAddress(),
      await tokenOut.getAddress(),
      E("1"),
      E("2"),
      await adapter.getAddress(),
      await adapter.getAddress()
    );

    await expect(
      adapter.connect(caller).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("2"),
        goodDesc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        ethers.ZeroAddress,
        recipient.address
      )
    ).to.be.reverted;
  });
});