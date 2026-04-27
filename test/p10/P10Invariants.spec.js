const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10 invariants", function () {
  async function deployFixture() {
    const [owner, user, feeRecipient] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const token18 = await ERC.deploy("Token 18", "TK18", 18);
    const usdc = await ERC.deploy("Mock USDC", "USDC", 6);
    const wbtc = await ERC.deploy("Mock WBTC", "WBTC", 8);
    await token18.waitForDeployment();
    await usdc.waitForDeployment();
    await wbtc.waitForDeployment();

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

    await (await pricing.setPrice(await usdc.getAddress(), E("1"), true)).wait();
    await (await pricing.setPrice(await wbtc.getAddress(), E("100000"), true)).wait();
    await (await pricing.setPrice(await token18.getAddress(), E("2000"), true)).wait();

    // 1 USDC + 0.001 WBTC + 0.5 TK18 = 1 + 100 + 1000 = $1101 NAV
    await (await manager.activateSnapshot(
      [await usdc.getAddress(), await wbtc.getAddress(), await token18.getAddress()],
      [6, 8, 18],
      [E("1"), E("0.001"), E("0.5")]
    )).wait();

    await (await usdc.mint(user.address, 1_000_000_000)).wait();
    await (await wbtc.mint(user.address, 100_000_000)).wait();
    await (await token18.mint(user.address, E("1000"))).wait();

    await (await usdc.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await wbtc.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await token18.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await p10.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();

    return {
      owner,
      user,
      feeRecipient,
      usdc,
      wbtc,
      token18,
      pricing,
      p10,
      manager,
      vault,
    };
  }

  it("computes exact NAV with mixed decimals", async function () {
    const { manager } = await deployFixture();
    expect(await manager.navPerP10USD()).to.equal(E("1101"));
  });

  it("round-trip basket mint/redeem returns underlying minus fees only", async function () {
    const { manager, user, usdc, wbtc, token18, p10, feeRecipient } = await deployFixture();

    const usdcIn = 2_000_000;
    const wbtcIn = 200_000;
    const token18In = E("1");

    const usdcBefore = await usdc.balanceOf(user.address);
    const wbtcBefore = await wbtc.balanceOf(user.address);
    const token18Before = await token18.balanceOf(user.address);

    await expect(
      manager.connect(user).mintBasketExact([usdcIn, wbtcIn, token18In], user.address)
    ).to.emit(manager, "Minted");

    const minted = await p10.balanceOf(user.address);
    expect(minted).to.be.gt(0);

    await expect(
      manager.connect(user).redeemBasketProRata(minted, user.address)
    ).to.emit(manager, "Redeemed");

    const usdcAfter = await usdc.balanceOf(user.address);
    const wbtcAfter = await wbtc.balanceOf(user.address);
    const token18After = await token18.balanceOf(user.address);

    expect(usdcAfter).to.be.lte(usdcBefore);
    expect(wbtcAfter).to.be.lte(wbtcBefore);
    expect(token18After).to.be.lte(token18Before);

    expect(await p10.balanceOf(feeRecipient.address)).to.be.gt(0);
  });

  it("does not mint fee P10 when fee recipient is zero", async function () {
    const { manager, user, p10 } = await deployFixture();

    await (await manager.setFeeRecipient(ethers.ZeroAddress)).wait();

    await expect(
      manager.connect(user).mintBasketExact([1_000_000, 100_000, E("0.5")], user.address)
    ).to.emit(manager, "Minted");

    expect(await p10.totalSupply()).to.equal(await p10.balanceOf(user.address));
  });

  it("reverts preview and mint paths when a constituent becomes unsafe", async function () {
    const { manager, user, pricing, wbtc } = await deployFixture();

    await (await pricing.setPrice(await wbtc.getAddress(), E("100000"), false)).wait();

    await expect(manager.navPerP10USD()).to.be.revertedWith("P10: unsafe price");
    await expect(manager.previewMintSingle(await wbtc.getAddress(), 100_000)).to.be.revertedWith("P10: unsafe price");
    await expect(
      manager.connect(user).mintBasketExact([1_000_000, 100_000, E("0.5")], user.address)
    ).to.be.revertedWith("P10: unsafe price");
  });

  it("rejects zero units and still reads old snapshots after a new one is activated", async function () {
    const { manager, usdc, wbtc, token18 } = await deployFixture();

    await expect(
      manager.activateSnapshot(
        [await usdc.getAddress(), await wbtc.getAddress()],
        [6, 8],
        [E("1"), 0]
      )
    ).to.be.revertedWith("P10: zero units");

    const oldNav = await manager.getSnapshotNAV(1);

    await (await manager.activateSnapshot(
      [await usdc.getAddress(), await token18.getAddress()],
      [6, 18],
      [E("1"), E("0.25")]
    )).wait();

    expect(await manager.getSnapshotNAV(1)).to.equal(oldNav);
    expect(await manager.snapshotId()).to.equal(2n);
  });
});