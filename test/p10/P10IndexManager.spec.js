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
    await (await manager.setVault(await vault.getAddress())).wait();

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

    await (await tokenA.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await tokenB.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await p10.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();

    return {
      owner,
      user,
      feeRecipient,
      tokenA,
      tokenB,
      pricing,
      p10,
      manager,
      vault,
    };
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
    ).to.be.revertedWith("P10: duplicate token");
  });

  it("mints only when the provided basket matches the exact snapshot ratio", async function () {
    const { manager, user, p10, feeRecipient } = await deployFixture();

    await expect(
      manager.connect(user).mintBasketExact([E("1"), E("1")], user.address)
    ).to.be.revertedWith("P10: basket ratio");

    await expect(
      manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)
    ).to.emit(manager, "Minted");

    expect(await p10.balanceOf(user.address)).to.equal(E("0.999"));
    expect(await p10.balanceOf(feeRecipient.address)).to.equal(E("0.001"));
  });

  it("redeems pro rata and keeps redeem fees inside supply", async function () {
    const { manager, user, tokenA, tokenB, p10, feeRecipient } = await deployFixture();

    await (await manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)).wait();

    await expect(
      manager.connect(user).redeemBasketProRata(E("0.5"), user.address)
    ).to.emit(manager, "Redeemed");

    expect(await tokenA.balanceOf(user.address)).to.equal(E("999.74975"));
    expect(await tokenB.balanceOf(user.address)).to.equal(E("999.4995"));
    expect(await p10.balanceOf(feeRecipient.address)).to.equal(E("0.0015"));
  });

  it("blocks minting when any constituent price is unsafe", async function () {
    const { manager, user, pricing, tokenA } = await deployFixture();

    await (await pricing.setPrice(await tokenA.getAddress(), E("2"), false)).wait();

    await expect(
      manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)
    ).to.be.revertedWith("P10: unsafe price");
  });

  it("supports exact basket checks across mixed decimals", async function () {
    const [owner, user, feeRecipient] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const token18 = await ERC.deploy("Token 18", "TK18", 18);
    const token6 = await ERC.deploy("Token 6", "TK6", 6);
    await token18.waitForDeployment();
    await token6.waitForDeployment();

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
    await (await manager.setVault(await vault.getAddress())).wait();
    await (await p10.setIndexManager(await manager.getAddress())).wait();
    await (await manager.setFeeRecipient(feeRecipient.address)).wait();

    await (await pricing.setPrice(await token18.getAddress(), E("1"), true)).wait();
    await (await pricing.setPrice(await token6.getAddress(), E("1"), true)).wait();

    await (await manager.activateSnapshot(
      [await token18.getAddress(), await token6.getAddress()],
      [18, 6],
      [E("1"), E("1")]
    )).wait();

    await (await token18.mint(user.address, E("1000"))).wait();
    await (await token6.mint(user.address, 1_000_000_000)).wait(); // 1000 units @ 6 decimals

    await (await token18.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await token6.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();

    await expect(
      manager.connect(user).mintBasketExact([E("1"), 1_000_000], user.address)
    ).to.emit(manager, "Minted");

    await expect(
      manager.connect(user).mintBasketExact([E("1"), 2_000_000], user.address)
    ).to.be.revertedWith("P10: basket ratio");
  });
});