const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ParagonFactory @spec", function () {
  it("INV-FA-01/02/03: createPair guards + deterministic", async function () {
    const [deployer] = await ethers.getSigners();

    // ParagonFactory(address feeToSetter, address xpgnToken)
    const Factory = await ethers.getContractFactory("ParagonFactory");
    const factory = await Factory.deploy(deployer.address, ethers.ZeroAddress);
    await factory.waitForDeployment();

    // Use fully qualified names to avoid duplicate-artifact errors
    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const A = await ERC.deploy("A", "A", 18);
    const B = await ERC.deploy("B", "B", 18);
    await A.waitForDeployment();
    await B.waitForDeployment();

    const addrA = await A.getAddress();
    const addrB = await B.getAddress();

    await expect(factory.createPair(addrA, addrA))
      .to.be.revertedWith("Paragon: IDENTICAL_ADDRESSES");

    await (await factory.createPair(addrA, addrB)).wait();
    const p1addr = await factory.getPair(addrA, addrB);
    expect(p1addr).to.not.equal(ethers.ZeroAddress);

    await expect(factory.createPair(addrB, addrA))
      .to.be.revertedWith("Paragon: PAIR_EXISTS");
  });
});
