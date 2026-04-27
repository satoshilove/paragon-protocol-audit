const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10 malicious venue protections", function () {
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

    const Exec = await ethers.getContractFactory("P10ExecutionManager");
    const exec = await Exec.deploy(
      owner.address,
      await manager.getAddress(),
      await vault.getAddress()
    );
    await exec.waitForDeployment();
    await (await vault.setExecutionManager(await exec.getAddress())).wait();

    const Mal = await ethers.getContractFactory("contracts/mocks/MockMaliciousVenue.sol:MockMaliciousVenue");
    const mal = await Mal.deploy();
    await mal.waitForDeployment();

    await (await exec.whitelistVenue(await mal.getAddress(), true)).wait();

    await (await p10.setIndexManager(await manager.getAddress())).wait();
    await (await manager.setVault(await vault.getAddress())).wait();
    await (await manager.setExecutionManager(await exec.getAddress())).wait();
    await (await manager.setMintVenue(await mal.getAddress())).wait();
    await (await manager.setRedeemVenue(await mal.getAddress())).wait();

    await (await pricing.setPrice(await tokenA.getAddress(), E("2"), true)).wait();
    await (await pricing.setPrice(await tokenB.getAddress(), E("1"), true)).wait();

    await (await manager.activateSnapshot(
      [await tokenA.getAddress(), await tokenB.getAddress()],
      [18, 18],
      [E("0.5"), E("1")]
    )).wait();

    await (await tokenA.mint(user.address, E("1000"))).wait();
    await (await tokenB.mint(user.address, E("1000"))).wait();

    // basket-exact path approvals
    await (await tokenA.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await tokenB.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();

    // single-token path approvals
    await (await tokenA.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();
    await (await tokenB.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();
    await (await p10.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();

    await (await tokenA.mint(await mal.getAddress(), E("1000"))).wait();
    await (await tokenB.mint(await mal.getAddress(), E("1000"))).wait();

    return { user, tokenA, tokenB, p10, manager, vault, exec, mal };
  }

  it("reverts if venue under-delivers to vault", async function () {
    const { user, tokenB, manager, mal } = await deployFixture();
    await (await mal.setMode(1)).wait(); // UNDER_DELIVER

    const venueData = "0x";
    await expect(
      manager.connect(user).mintSingle(
        await tokenB.getAddress(),
        E("2"),
        user.address,
        1,
        venueData
      )
    ).to.be.reverted;
  });

  it("reverts if venue lies about actualAcquired", async function () {
    const { user, tokenB, manager, mal } = await deployFixture();
    await (await mal.setMode(2)).wait(); // WRONG_ACQUIRED

    await expect(
      manager.connect(user).mintSingle(
        await tokenB.getAddress(),
        E("2"),
        user.address,
        1,
        "0x"
      )
    ).to.be.reverted;
  });

  it("reverts if venue over-reports output", async function () {
    const { user, tokenA, manager, mal } = await deployFixture();

    await (await manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)).wait();
    await (await mal.setMode(3)).wait(); // WRONG_OUTPUT

    await expect(
      manager.connect(user).redeemSingle(
        E("0.5"),
        await tokenA.getAddress(),
        user.address,
        1,
        "0x"
      )
    ).to.be.reverted;
  });

  it("reverts if venue sends to wrong receiver", async function () {
    const { user, tokenB, manager, mal } = await deployFixture();
    await (await mal.setMode(4)).wait(); // WRONG_RECEIVER

    await expect(
      manager.connect(user).mintSingle(
        await tokenB.getAddress(),
        E("2"),
        user.address,
        1,
        "0x"
      )
    ).to.be.reverted;
  });
});