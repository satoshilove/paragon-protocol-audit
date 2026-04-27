/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseEther(n);

describe("RevenueRouter @spec", () => {
  it("checks token compatibility in notify mode and requires trader epoch in trader notify mode", async () => {
    const [owner] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const X = await ERC.deploy("XPGN", "XPGN", 18);
    const Y = await ERC.deploy("OTHER", "OTHER", 18);
    await X.waitForDeployment();
    await Y.waitForDeployment();

    const F = await ethers.getContractFactory("contracts/mocks/MockFeeDistributorNotify.sol:MockFeeDistributorNotify");
    const feeSink = await F.deploy(X.target);
    await feeSink.waitForDeployment();

    const T = await ethers.getContractFactory("contracts/mocks/MockTraderRewardsNotify.sol:MockTraderRewardsNotify");
    const traderSink = await T.deploy(X.target);
    await traderSink.waitForDeployment();

    const Router = await ethers.getContractFactory("RevenueRouter");
    const router = await Router.deploy(
      owner.address,
      feeSink.target,
      owner.address,
      traderSink.target,
      3000,
      2000,
      5000
    );
    await router.waitForDeployment();

    await X.mint(router.target, E("10"));

    await expect(
      router["distribute(address,uint256)"](X.target, 1)
    ).to.emit(router, "Distributed");

    await Y.mint(router.target, E("10"));
    await expect(
      router["distribute(address,uint256)"](Y.target, 1)
    ).to.be.revertedWith("fee sink token mismatch");

    await router.setSinkModes(0, 2); // fee transfer, trader notify

    // re-fund router so we do not fail early with "no balance"
    await X.mint(router.target, E("5"));

    await expect(
      router["distribute(address)"](X.target)
    ).to.be.revertedWith("trader epoch required");
  });
});