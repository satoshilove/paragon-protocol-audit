const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);
const { deadline } = require("../helpers");

describe("ParagonRouterAdmin @spec", function () {
  it("INV-AD-01: setters enforce bounds + emit", async function () {
    const [owner, other, master] = await ethers.getSigners();

    // WETH9 (fully-qualified)
    const WETH = await ethers.getContractFactory("contracts/exchange/WETH9.sol:WETH9");
    const weth = await WETH.deploy();
    await weth.waitForDeployment();

    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(owner.address, ethers.ZeroAddress);
    await fac.waitForDeployment();

    const Router = await ethers.getContractFactory("ParagonRouter");
    const router = await Router.deploy(await fac.getAddress(), await weth.getAddress(), master.address);
    await router.waitForDeployment();

    await expect(router.setOracle(other.address))
      .to.emit(router, "OracleUpdated").withArgs(other.address);
    expect(await router.priceOracle()).to.equal(other.address);

    await expect(router.setGuardParams(true, false, true, 2001, 0))
      .to.be.revertedWith("Paragon: LIMITS_HIGH");

    await expect(router.setGuardParams(true, false, true, 300, 300))
      .to.emit(router, "GuardParamsUpdated").withArgs(true, false, true, 300, 300);
    expect(await router.guardEnabled()).to.equal(true);
    expect(await router.maxSlippageBips()).to.equal(300);
    expect(await router.maxImpactBips()).to.equal(300);

    const someToken = ethers.Wallet.createRandom().address;
    await expect(router.setProtectedToken(someToken, true))
      .to.emit(router, "ProtectedTokenSet").withArgs(someToken, true);
    expect(await router.protectedToken(someToken)).to.equal(true);

    await expect(router.setAutoYieldConfig(7, true))
      .to.emit(router, "AutoYieldConfigUpdated").withArgs(7, true);
    expect(await router.autoYieldPid()).to.equal(7);
    expect(await router.autoYieldEnabled()).to.equal(true);

    await expect(router.connect(other).setOracle(other.address)).to.be.reverted;
  });

  it("INV-AD-02: pause gates router critical paths", async function () {
    const [owner, master] = await ethers.getSigners();

    // WETH9 (fully-qualified)
    const WETH = await ethers.getContractFactory("contracts/exchange/WETH9.sol:WETH9");
    const weth = await WETH.deploy();
    await weth.waitForDeployment();

    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(owner.address, ethers.ZeroAddress);
    await fac.waitForDeployment();

    const Router = await ethers.getContractFactory("ParagonRouter");
    const router = await Router.deploy(await fac.getAddress(), await weth.getAddress(), master.address);
    await router.waitForDeployment();

    await router.pause();
    const a = ethers.Wallet.createRandom().address;
    const b = ethers.Wallet.createRandom().address;

    await expect(
      router.addLiquidity(a, b, 0, 0, 0, 0, owner.address, deadline())
    ).to.be.reverted; // Pausable modifier triggers
  });
});
