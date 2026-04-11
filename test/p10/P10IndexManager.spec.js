const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10IndexManager", function () {
  async function deployFixture() {
    const [owner, user, feeRecipient] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const tokenA = await ERC.deploy("Token A", "TKA", 18);
    const tokenB = await ERC.deploy("Token B", "TKB", 18);
    await tokenA.waitForDeployment();
    await tokenB.waitForDeployment();

    const Pricing = await ethers.getContractFactory("contracts/mocks/MockP10Pricing.sol:MockP10Pricing");
    const pricing = await Pricing.deploy();
    await pricing.waitForDeployment();

    const Router = await ethers.getContractFactory("contracts/mocks/MockP10Router.sol:MockP10Router");
    const router = await Router.deploy();
    await router.waitForDeployment();

    const P10 = await ethers.getContractFactory("P10Token");
    const p10 = await P10.deploy(owner.address);
    await p10.waitForDeployment();

    const Manager = await ethers.getContractFactory("P10IndexManager");
    const manager = await Manager.deploy(
      owner.address,
      await p10.getAddress(),
      await router.getAddress(),
      await pricing.getAddress()
    );
    await manager.waitForDeployment();

    await (await p10.setIndexManager(await manager.getAddress())).wait();
    await (await manager.setFeeRecipient(feeRecipient.address)).wait();

    await (await pricing.setPrice(await tokenA.getAddress(), E("2"), true)).wait();
    await (await pricing.setPrice(await tokenB.getAddress(), E("1"), true)).wait();

    await (await manager.activateSnapshot(
      [await tokenA.getAddress(), await tokenB.getAddress()],
      [18, 18],
      [E("0.5"), E("1")]
    )).wait();

    await (await tokenA.mint(user.address, E("1000"))).wait();
    await (await tokenB.mint(user.address, E("1000"))).wait();
    await (await tokenA.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();
    await (await tokenB.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();
    await (await p10.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();

    return { owner, user, feeRecipient, tokenA, tokenB, pricing, router, p10, manager };
  }

  it("computes NAV from the active snapshot", async function () {
    const { manager } = await deployFixture();
    expect(await manager.navPerP10USD()).to.equal(E("2"));
  });

  it("rejects duplicate assets in a snapshot", async function () {
    const { manager, tokenA } = await deployFixture();
    await expect(
      manager.activateSnapshot(
        [await tokenA.getAddress(), await tokenA.getAddress()],
        [18, 18],
        [E("1"), E("1")]
      )
    ).to.be.revertedWithCustomError(manager, "DuplicateToken");
  });

  it("mints only when the provided basket matches the exact snapshot ratio", async function () {
    const { manager, user, p10, feeRecipient } = await deployFixture();

    await expect(
      manager.connect(user).mintBasketExact([E("1"), E("1")], user.address)
    ).to.be.revertedWithCustomError(manager, "BasketRatioMismatch");

    await expect(manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address))
      .to.emit(manager, "Minted");

    expect(await p10.balanceOf(user.address)).to.equal(E("0.999"));
    expect(await p10.balanceOf(feeRecipient.address)).to.equal(E("0.001"));
  });

  it("redeems pro rata and keeps redeem fees inside supply", async function () {
    const { manager, user, tokenA, tokenB, p10, feeRecipient } = await deployFixture();

    await (await manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)).wait();

    await expect(manager.connect(user).redeemBasketProRata(E("0.5"), user.address))
      .to.emit(manager, "Redeemed");

    expect(await tokenA.balanceOf(user.address)).to.equal(E("999.74975"));
    expect(await tokenB.balanceOf(user.address)).to.equal(E("999.4995"));
    expect(await p10.balanceOf(feeRecipient.address)).to.equal(E("0.0015"));
  });

  it("blocks minting when any constituent price is unsafe", async function () {
    const { manager, user, pricing, tokenA } = await deployFixture();

    await (await pricing.setPrice(await tokenA.getAddress(), E("2"), false)).wait();
    await expect(
      manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)
    ).to.be.revertedWithCustomError(manager, "UnsafePrice");
  });
});
