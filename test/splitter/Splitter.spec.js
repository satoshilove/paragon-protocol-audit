/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { E } = require("../helpers");

describe("TreasurySplitter :: 60/35/5", () => {
  it("INV-TS-01: setSinks requires non-zero sinks", async () => {
    const [owner, a, b, c] = await ethers.getSigners();

    const Splitter = await ethers.getContractFactory("TreasurySplitter");
    const s = await Splitter.deploy(owner.address, a.address, b.address, c.address);
    await s.waitForDeployment();

    // requires non-zero sinks
    await expect(s.setSinks(a.address, ethers.ZeroAddress, c.address)).to.be.reverted;

    // Optional (uncomment if your contract emits SinksUpdated):
    // await expect(s.setSinks(b.address, a.address, c.address))
    //   .to.emit(s, "SinksUpdated")
    //   .withArgs(b.address, a.address, c.address);
  });

  it("INV-TS-02: distribute(token) sends exactly 60%/35%/5% of current balance", async () => {
    const [owner, a, b, c] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const T = await ERC.deploy("T", "T", 18);
    await T.waitForDeployment();

    const Splitter = await ethers.getContractFactory("TreasurySplitter");
    // constructor(address owner_, address sink60, address sink35, address sink05)
    const s = await Splitter.deploy(owner.address, a.address, b.address, c.address);
    await s.waitForDeployment();

    await (await T.mint(s.target, E("1000"))).wait();

    // Optional (uncomment if your contract emits Distributed):
    // await expect(s.distribute(T.target))
    //   .to.emit(s, "Distributed")
    //   .withArgs(T.target, E("1000"), E("600"), E("350"), E("50"));

    await (await s.distribute(T.target)).wait();

    expect(await T.balanceOf(a.address)).to.equal(E("600")); // 60%
    expect(await T.balanceOf(b.address)).to.equal(E("350")); // 35%
    expect(await T.balanceOf(c.address)).to.equal(E("50"));  // 5%
  });
});
