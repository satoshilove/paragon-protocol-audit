const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10 access control", function () {
  async function deployFixture() {
    const [owner, user, attacker] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const tokenA = await ERC.deploy("Token A", "TKA", 18);
    const tokenB = await ERC.deploy("Token B", "TKB", 18);
    const extra = await ERC.deploy("Extra", "EXT", 18);
    await tokenA.waitForDeployment();
    await tokenB.waitForDeployment();
    await extra.waitForDeployment();

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

    const Exec = await ethers.getContractFactory("P10ExecutionManager");
    const exec = await Exec.deploy(owner.address, await manager.getAddress(), await vault.getAddress());
    await exec.waitForDeployment();

    await (await vault.setIndexManager(await manager.getAddress())).wait();
    await (await vault.setExecutionManager(await exec.getAddress())).wait();
    await (await manager.setVault(await vault.getAddress())).wait();
    await (await manager.setExecutionManager(await exec.getAddress())).wait();
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

    return { owner, user, attacker, tokenA, tokenB, extra, pricing, p10, manager, vault, exec };
  }

  it("non-owner cannot set admin/config params", async function () {
    const { attacker, manager } = await deployFixture();

    await expect(manager.connect(attacker).setPricing(attacker.address)).to.be.reverted;
    await expect(manager.connect(attacker).setVault(attacker.address)).to.be.reverted;
    await expect(manager.connect(attacker).setExecutionManager(attacker.address)).to.be.reverted;
    await expect(manager.connect(attacker).setMintVenue(attacker.address)).to.be.reverted;
    await expect(manager.connect(attacker).setRedeemVenue(attacker.address)).to.be.reverted;
    await expect(manager.connect(attacker).setFees(10, 10)).to.be.reverted;
    await expect(manager.connect(attacker).setMintCaps(0, 100)).to.be.reverted;
    await expect(manager.connect(attacker).setPauser(attacker.address)).to.be.reverted;
    await expect(manager.connect(attacker).setGuardian(attacker.address)).to.be.reverted;
  });

  it("non-index manager cannot mint or burn P10", async function () {
    const { attacker, p10 } = await deployFixture();

    await expect(p10.connect(attacker).mint(attacker.address, E("1"))).to.be.revertedWith("P10: not index manager");
    await expect(p10.connect(attacker).burn(attacker.address, E("1"))).to.be.revertedWith("P10: not index manager");
  });

  it("non-index manager cannot move vault funds", async function () {
    const { user, attacker, tokenA, tokenB, manager, vault } = await deployFixture();

    await (await manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)).wait();

    await expect(
      vault.connect(attacker).directWithdrawToUser(await tokenA.getAddress(), attacker.address, E("0.1"))
    ).to.be.reverted;

    await expect(
      vault.connect(attacker).withdrawToExecutionManager(await tokenB.getAddress(), E("0.1"))
    ).to.be.reverted;
  });

  it("non-index manager cannot call execution manager paths", async function () {
    const { attacker, tokenA, exec } = await deployFixture();

    await expect(
      exec.connect(attacker).buyBasketSingleToken(
        attacker.address,
        await tokenA.getAddress(),
        E("1"),
        [],
        0,
        "0x"
      )
    ).to.be.reverted;
  });

  it("vault rescue rejects active basket assets and allows non-basket assets", async function () {
    const { owner, user, extra, tokenA, manager, vault } = await deployFixture();

    await (await extra.mint(await vault.getAddress(), E("1"))).wait();

    await expect(
      vault.connect(owner).rescueToken(await tokenA.getAddress(), owner.address, E("0.1"))
    ).to.be.revertedWith("P10Vault: active basket asset");

    await expect(
      vault.connect(owner).rescueToken(await extra.getAddress(), owner.address, E("1"))
    ).to.emit(vault, "Withdrawn");
  });
});