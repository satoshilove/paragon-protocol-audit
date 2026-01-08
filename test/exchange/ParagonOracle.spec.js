const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ParagonOracle @spec", function () {
  it("INV-OR: admin price path returns normalized USD value", async function () {
    // 1) Deploy a factory (needed by oracle ctor)
    const [owner] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("ParagonFactory");
    const fac = await Factory.deploy(owner.address, ethers.ZeroAddress);
    await fac.waitForDeployment();

    // 2) Deploy Oracle with factory address (NO LIBRARY LINKING)
    const Oracle = await ethers.getContractFactory("ParagonOracle");
    const oracle = await Oracle.deploy(await fac.getAddress());
    await oracle.waitForDeployment();

    // 3) Mocks
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const ASSET = await ERC.deploy("ASSET", "A", 18n);
    const USDT  = await ERC.deploy("USDT", "USDT", 18n);
    const WBNB  = await ERC.deploy("WBNB", "WBNB", 18n);
    await ASSET.waitForDeployment();
    await USDT.waitForDeployment();
    await WBNB.waitForDeployment();

    const asset = await ASSET.getAddress();
    const usdt  = await USDT.getAddress();
    const wbnb  = await WBNB.getAddress();

    // 4) Enable admin price: 2.0 USD (1e18 = $1)
    await (await oracle.setAdminPrice(asset, ethers.parseEther("2"), true)).wait();

    // 5) 1 ASSET (18 decimals) -> $2e18
    const out = await oracle.valueUsd1e18(asset, ethers.parseEther("1"), usdt, wbnb);
    expect(out).to.equal(ethers.parseEther("2"));
  });
});
