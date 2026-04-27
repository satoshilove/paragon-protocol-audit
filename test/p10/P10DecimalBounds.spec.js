const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10 snapshot decimal bounds", function () {
  async function deployFixture() {
    const [owner, user] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const token18 = await ERC.deploy("Token 18", "TK18", 18);
    const token24 = await ERC.deploy("Token 24", "TK24", 24);
    await token18.waitForDeployment();
    await token24.waitForDeployment();

    const Broken = await ethers.getContractFactory("contracts/mocks/MockBrokenDecimalsERC20.sol:MockBrokenDecimalsERC20");
    const broken = await Broken.deploy("Broken", "BRK");
    await broken.waitForDeployment();

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

    await (await pricing.setPrice(await token18.getAddress(), E("1"), true)).wait();
    await (await pricing.setPrice(await token24.getAddress(), E("1"), true)).wait();
    await (await pricing.setPrice(await broken.getAddress(), E("1"), true)).wait();

    await (await token18.mint(user.address, E("1000"))).wait();
    await (await token24.mint(user.address, 1000n * 10n ** 24n)).wait();
    await (await broken.mint(user.address, E("1000"))).wait();

    await (await token18.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await token24.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await broken.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();

    return { user, token18, token24, broken, manager };
  }

  it("handles snapshot token decimals above 18 in basket-ratio checks", async function () {
    const { user, token18, token24, manager } = await deployFixture();

    await (await manager.activateSnapshot(
      [await token18.getAddress(), await token24.getAddress()],
      [18, 24],
      [E("1"), E("1")]
    )).wait();

    await expect(
      manager.connect(user).mintBasketExact([E("1"), 1n * 10n ** 24n], user.address)
    ).to.emit(manager, "Minted");

    await expect(
      manager.connect(user).mintBasketExact([E("1"), 2n * 10n ** 24n], user.address)
    ).to.be.revertedWith("P10: basket ratio");
  });

  it("uses fallback decimals behavior in preview path for tokens with broken decimals()", async function () {
    const { broken, manager } = await deployFixture();

    await (await manager.activateSnapshot(
      [await broken.getAddress()],
      [18],
      [E("1")]
    )).wait();

    await expect(
      manager.previewMintSingle(await broken.getAddress(), E("1"))
    ).to.not.be.reverted;
  });
});