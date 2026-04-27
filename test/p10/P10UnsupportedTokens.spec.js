const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10 unsupported token behavior", function () {
  async function deployFixture() {
    const [owner, user] = await ethers.getSigners();

    const FOT = await ethers.getContractFactory("contracts/mocks/MockFeeOnTransferERC20.sol:MockFeeOnTransferERC20");
    const fot = await FOT.deploy("Fee Token", "FOT", 100); // 1%
    await fot.waitForDeployment();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const tokenB = await ERC.deploy("Token B", "TKB", 18);
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

    await (await pricing.setPrice(await fot.getAddress(), E("1"), true)).wait();
    await (await pricing.setPrice(await tokenB.getAddress(), E("1"), true)).wait();

    await (await manager.activateSnapshot(
      [await fot.getAddress(), await tokenB.getAddress()],
      [18, 18],
      [E("1"), E("1")]
    )).wait();

    await (await fot.mint(user.address, E("1000"))).wait();
    await (await tokenB.mint(user.address, E("1000"))).wait();

    await (await fot.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await tokenB.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();

    return { user, fot, tokenB, manager };
  }

  it("fee-on-transfer tokens revert cleanly in basket-exact deposits", async function () {
    const { user, manager } = await deployFixture();

    await expect(
      manager.connect(user).mintBasketExact([E("1"), E("1")], user.address)
    ).to.be.revertedWith("P10Vault: unsupported transfer token");
  });
});