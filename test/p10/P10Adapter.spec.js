const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10OneInchAdapter hardening", function () {
  async function deployFixture() {
    const [owner, caller, other] = await ethers.getSigners();

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

    await (await tokenIn.connect(caller).transfer(await adapter.getAddress(), E("1"))).wait();

    return { owner, caller, other, tokenIn, tokenOut, router, adapter };
  }

  it("rejects unauthorized caller", async function () {
    const { other, tokenIn, tokenOut, adapter } = await deployFixture();

    const desc = {
      srcToken: await tokenIn.getAddress(),
      dstToken: await tokenOut.getAddress(),
      srcReceiver: await adapter.getAddress(),
      dstReceiver: await adapter.getAddress(),
      amount: E("1"),
      minReturnAmount: E("1"),
      flags: 0
    };

    await expect(
      adapter.connect(other).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("1"),
        desc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        ethers.ZeroAddress,
        other.address
      )
    ).to.be.reverted;
  });

  it("rejects nonzero native value", async function () {
    const { caller, tokenIn, tokenOut, adapter } = await deployFixture();

    const desc = {
      srcToken: await tokenIn.getAddress(),
      dstToken: await tokenOut.getAddress(),
      srcReceiver: await adapter.getAddress(),
      dstReceiver: await adapter.getAddress(),
      amount: E("1"),
      minReturnAmount: E("1"),
      flags: 0
    };

    await expect(
      adapter.connect(caller).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("1"),
        desc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        ethers.ZeroAddress,
        caller.address,
        { value: 1 }
      )
    ).to.be.reverted;
  });

  it("rejects paused adapter", async function () {
    const { owner, caller, tokenIn, tokenOut, adapter } = await deployFixture();
    await (await adapter.connect(owner).pause()).wait();

    const desc = {
      srcToken: await tokenIn.getAddress(),
      dstToken: await tokenOut.getAddress(),
      srcReceiver: await adapter.getAddress(),
      dstReceiver: await adapter.getAddress(),
      amount: E("1"),
      minReturnAmount: E("1"),
      flags: 0
    };

    await expect(
      adapter.connect(caller).execute(
        await tokenIn.getAddress(),
        E("1"),
        await tokenOut.getAddress(),
        E("1"),
        desc,
        "0x",
        ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("1")]),
        ethers.ZeroAddress,
        caller.address
      )
    ).to.be.reverted;
  });
});