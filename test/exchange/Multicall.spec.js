const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Multicall @spec", function () {
  it("INV-MC-01: aggregate reverts if any subcall fails", async function () {
    const MC = await ethers.getContractFactory("Multicall3"); // ← was Multicall
    const mc = await MC.deploy();
    await mc.waitForDeployment();

    const target = await mc.getAddress();
    const calls = [
      { target, callData: "0x" },        // no selector → should fail
      { target, callData: "0xdeadbeef" } // invalid → fails
    ];

    await expect(mc.aggregate(calls)).to.be.reverted;
  });
});
