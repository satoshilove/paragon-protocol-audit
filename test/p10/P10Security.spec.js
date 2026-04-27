const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10 security behaviors", function () {
  async function deployFixture() {
    const [owner, user, pauser, guardian, attacker] = await ethers.getSigners();

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
    await (await manager.setPauser(pauser.address)).wait();
    await (await manager.setGuardian(guardian.address)).wait();

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
      pauser,
      guardian,
      attacker,
      tokenA,
      tokenB,
      pricing,
      p10,
      manager,
      vault,
    };
  }

  it("mint pause blocks mint only", async function () {
    const { manager, user } = await deployFixture();

    await (await manager.setMintPaused(true)).wait();

    await expect(
      manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)
    ).to.be.revertedWith("P10: mint paused");
  });

  it("redeem pause blocks redeem only", async function () {
    const { manager, user } = await deployFixture();

    await (await manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)).wait();
    await (await manager.setRedeemPaused(true)).wait();

    await expect(
      manager.connect(user).redeemBasketProRata(E("0.5"), user.address)
    ).to.be.revertedWith("P10: redeem paused");
  });

  it("emergency freeze blocks both mint and redeem", async function () {
    const { manager, user } = await deployFixture();

    await (await manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)).wait();
    await (await manager.setEmergencyFrozen(true)).wait();

    await expect(
      manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)
    ).to.be.revertedWith("P10: frozen");

    await expect(
      manager.connect(user).redeemBasketProRata(E("0.5"), user.address)
    ).to.be.revertedWith("P10: frozen");
  });

  it("pauser and guardian cannot unpause or unfreeze", async function () {
    const { manager, pauser, guardian } = await deployFixture();

    await (await manager.connect(pauser).setMintPaused(true)).wait();
    await (await manager.connect(guardian).setEmergencyFrozen(true)).wait();

    await expect(manager.connect(pauser).setMintPaused(false)).to.be.revertedWith("P10: only owner unpause");
    await expect(manager.connect(guardian).setEmergencyFrozen(false)).to.be.revertedWith("P10: only owner unfreeze");
  });

  it("dust sent to vault does not break basket-exact mint/redeem", async function () {
    const { manager, user, attacker, tokenA } = await deployFixture();

    await (await tokenA.mint(attacker.address, E("1"))).wait();
    await (await tokenA.connect(attacker).transfer(await manager.vault(), E("0.0001"))).wait();

    await expect(
      manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)
    ).to.emit(manager, "Minted");

    await expect(
      manager.connect(user).redeemBasketProRata(E("0.5"), user.address)
    ).to.emit(manager, "Redeemed");
  });
});