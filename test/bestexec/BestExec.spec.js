/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ParagonBestExecutionV14 :: nonce consume @spec", () => {
  it("INV-BE-01: consumes each nonce exactly once; mismatch & replay revert", async () => {
    const [user] = await ethers.getSigners();

    const BE = await ethers.getContractFactory("contracts/mocks/MockBestExec.sol:MockBestExec");
    const be = await BE.deploy();
    await be.waitForDeployment();

    // initial expected nonce is 0
    expect(await be.nonces(user.address)).to.equal(0n);

    // consume(0) → OK, increments to 1
    await be.consume(user.address, 0);
    expect(await be.nonces(user.address)).to.equal(1n);

    // replay same nonce(0) → revert
    await expect(be.consume(user.address, 0)).to.be.reverted;

    // skipping ahead (2 while current=1) → revert
    await expect(be.consume(user.address, 2)).to.be.reverted;

    // consume(1) → OK, increments to 2
    await be.consume(user.address, 1);
    expect(await be.nonces(user.address)).to.equal(2n);
  });

  it("INV-BE-01 (cancel path): cancel increments by exactly 1 when expected matches", async () => {
    const [user] = await ethers.getSigners();
    const BE = await ethers.getContractFactory("contracts/mocks/MockBestExec.sol:MockBestExec");
    const be = await BE.deploy();
    await be.waitForDeployment();

    // nonce = 0 → cancel(0) OK → nonce = 1
    await be.cancel(user.address, 0);
    expect(await be.nonces(user.address)).to.equal(1n);

    // cancel with wrong expected (should be 1) → revert
    await expect(be.cancel(user.address, 0)).to.be.reverted;

    // cancel(1) OK → nonce = 2
    await be.cancel(user.address, 1);
    expect(await be.nonces(user.address)).to.equal(2n);
  });
});
