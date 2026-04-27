const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const E = ethers.parseEther;

describe("P10 mint caps", function () {
  async function deployFixture() {
    const [owner, user] = await ethers.getSigners();

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
    const manager = await Manager.deploy(owner.address, await p10.getAddress(), await pricing.getAddress());
    await manager.waitForDeployment();

    const Vault = await ethers.getContractFactory("P10Vault");
    const vault = await Vault.deploy(owner.address, owner.address);
    await vault.waitForDeployment();

    await (await vault.setIndexManager(await manager.getAddress())).wait();
    await (await manager.setVault(await vault.getAddress())).wait();
    await (await p10.setIndexManager(await manager.getAddress())).wait();

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

    return { owner, user, tokenA, tokenB, p10, manager, vault };
  }

  it("enforces perTxMintCapUsdE18", async function () {
    const { manager, user } = await deployFixture();

    // Basket [0.5, 1] = $2
    await (await manager.setMintCaps(E("1.5"), 1000)).wait();

    await expect(
      manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)
    ).to.be.revertedWith("P10: per-tx cap");
  });

  it("enforces daily cap across multiple mints", async function () {
    const { manager, user } = await deployFixture();

    // First mint with supply=0 bypasses daily cap by design
    await (await manager.setMintCaps(0, 100)).wait(); // 1%
    await (await manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)).wait();

    // After first mint, supply ~= 0.999, daily cap ~= 0.00999
    await expect(
      manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)
    ).to.be.revertedWith("P10: daily mint cap");
  });

  it("resets daily cap after a new day", async function () {
    const { manager, user } = await deployFixture();

    await (await manager.setMintCaps(0, 100)).wait();
    await (await manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)).wait();

    await expect(
      manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)
    ).to.be.revertedWith("P10: daily mint cap");

    await time.increase(24 * 60 * 60 + 5);

    await expect(
      manager.connect(user).mintBasketExact([E("0.005"), E("0.01")], user.address)
    ).to.emit(manager, "Minted");
  });
  it("treats zero daily cap as disabled", async function () {
    const { manager, user } = await deployFixture();

    await (await manager.setMintCaps(0, 0)).wait();
    await (await manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)).wait();

    await expect(
      manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)
    ).to.emit(manager, "Minted");
  });
});