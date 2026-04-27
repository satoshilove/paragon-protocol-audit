const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

describe("P10 unsupported token single-flow behavior", function () {
  async function deployMintFixture() {
    const [owner, user, feeRecipient] = await ethers.getSigners();

    const FOT = await ethers.getContractFactory("contracts/mocks/MockFeeOnTransferERC20.sol:MockFeeOnTransferERC20");
    const fot = await FOT.deploy("Fee Token", "FOT", 100); // 1%
    await fot.waitForDeployment();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const tokenB = await ERC.deploy("Token B", "TKB", 18);
    const tokenC = await ERC.deploy("Token C", "TKC", 6);
    await tokenB.waitForDeployment();
    await tokenC.waitForDeployment();

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

    const MockRouter = await ethers.getContractFactory("contracts/mocks/Mock1inchRouterV6.sol:Mock1inchRouterV6");
    const mock1inch = await MockRouter.deploy();
    await mock1inch.waitForDeployment();

    const Adapter = await ethers.getContractFactory("P10OneInchAdapter");
    const adapter = await Adapter.deploy(
      owner.address,
      owner.address,
      await mock1inch.getAddress()
    );
    await adapter.waitForDeployment();

    const Venue = await ethers.getContractFactory("P10Venue1Inch");
    const venue = await Venue.deploy(
      owner.address,
      await adapter.getAddress(),
      await exec.getAddress()
    );
    await venue.waitForDeployment();

    await (await adapter.setAuthorizedCaller(await venue.getAddress())).wait();
    await (await exec.whitelistVenue(await venue.getAddress(), true)).wait();

    await (await p10.setIndexManager(await manager.getAddress())).wait();
    await (await manager.setVault(await vault.getAddress())).wait();
    await (await manager.setExecutionManager(await exec.getAddress())).wait();
    await (await manager.setMintVenue(await venue.getAddress())).wait();
    await (await manager.setRedeemVenue(await venue.getAddress())).wait();
    await (await manager.setFeeRecipient(feeRecipient.address)).wait();

    await (await pricing.setPrice(await fot.getAddress(), E("1"), true)).wait();
    await (await pricing.setPrice(await tokenB.getAddress(), E("1"), true)).wait();
    await (await pricing.setPrice(await tokenC.getAddress(), E("1"), true)).wait();

    await (await manager.activateSnapshot(
      [await fot.getAddress(), await tokenB.getAddress(), await tokenC.getAddress()],
      [18, 18, 6],
      [E("1"), E("1"), E("1")]
    )).wait();

    await (await fot.mint(user.address, E("1000"))).wait();
    await (await tokenB.mint(user.address, E("1000"))).wait();
    await (await tokenC.mint(user.address, 1_000_000_000)).wait();

    await (await fot.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();
    await (await tokenB.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();
    await (await tokenC.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();

    await (await p10.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();

    await (await fot.mint(await mock1inch.getAddress(), E("100000"))).wait();
    await (await tokenB.mint(await mock1inch.getAddress(), E("100000"))).wait();
    await (await tokenC.mint(await mock1inch.getAddress(), 100_000_000_000)).wait();

    return { user, fot, tokenB, tokenC, p10, manager };
  }

  async function deployRedeemFixture() {
    const [owner, user, feeRecipient] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const tokenA = await ERC.deploy("Token A", "TKA", 18);
    const tokenB = await ERC.deploy("Token B", "TKB", 18);
    await tokenA.waitForDeployment();
    await tokenB.waitForDeployment();

    const FOT = await ethers.getContractFactory("contracts/mocks/MockFeeOnTransferERC20.sol:MockFeeOnTransferERC20");
    const fotOut = await FOT.deploy("Fee Out", "FOUT", 100); // 1%
    await fotOut.waitForDeployment();

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

    const MockRouter = await ethers.getContractFactory("contracts/mocks/Mock1inchRouterV6.sol:Mock1inchRouterV6");
    const mock1inch = await MockRouter.deploy();
    await mock1inch.waitForDeployment();

    const Adapter = await ethers.getContractFactory("P10OneInchAdapter");
    const adapter = await Adapter.deploy(
      owner.address,
      owner.address,
      await mock1inch.getAddress()
    );
    await adapter.waitForDeployment();

    const Venue = await ethers.getContractFactory("P10Venue1Inch");
    const venue = await Venue.deploy(
      owner.address,
      await adapter.getAddress(),
      await exec.getAddress()
    );
    await venue.waitForDeployment();

    await (await adapter.setAuthorizedCaller(await venue.getAddress())).wait();
    await (await exec.whitelistVenue(await venue.getAddress(), true)).wait();

    await (await p10.setIndexManager(await manager.getAddress())).wait();
    await (await manager.setVault(await vault.getAddress())).wait();
    await (await manager.setExecutionManager(await exec.getAddress())).wait();
    await (await manager.setMintVenue(await venue.getAddress())).wait();
    await (await manager.setRedeemVenue(await venue.getAddress())).wait();
    await (await manager.setFeeRecipient(feeRecipient.address)).wait();

    await (await pricing.setPrice(await tokenA.getAddress(), E("2"), true)).wait();
    await (await pricing.setPrice(await tokenB.getAddress(), E("1"), true)).wait();
    await (await pricing.setPrice(await fotOut.getAddress(), E("1"), true)).wait();

    await (await manager.activateSnapshot(
      [await tokenA.getAddress(), await tokenB.getAddress()],
      [18, 18],
      [E("0.5"), E("1")]
    )).wait();

    await (await tokenA.mint(user.address, E("1000"))).wait();
    await (await tokenB.mint(user.address, E("1000"))).wait();

    await (await tokenA.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await tokenB.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await p10.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();

    await (await fotOut.mint(await mock1inch.getAddress(), E("100000"))).wait();

    await (await manager.connect(user).mintBasketExact([E("0.5"), E("1")], user.address)).wait();

    return { user, tokenA, tokenB, fotOut, p10, manager, adapter };
  }

  function encodeBuyVenueData(swaps) {
    return ethers.AbiCoder.defaultAbiCoder().encode(
      ["tuple(tuple(address executor, bytes oneInchData, uint256 amountIn, uint256 minOut)[] swaps)"],
      [{ swaps }]
    );
  }

  function encodeSellVenueData(swaps) {
    return ethers.AbiCoder.defaultAbiCoder().encode(
      ["tuple(tuple(address executor, bytes oneInchData, uint256 amountIn, uint256 minOut)[] swaps)"],
      [{ swaps }]
    );
  }

  it("fee-on-transfer input token is rejected at the intended boundary in mintSingle", async function () {
    const { user, fot, manager } = await deployMintFixture();

    const buyData = encodeBuyVenueData([
      {
        executor: ethers.ZeroAddress,
        oneInchData: "0x",
        amountIn: E("0.666666666666666667"),
        minOut: E("0.66"),
      },
      {
        executor: ethers.ZeroAddress,
        oneInchData: "0x",
        amountIn: E("0.666666666666666666"),
        minOut: E("0.66"),
      },
      {
        executor: ethers.ZeroAddress,
        oneInchData: ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [666666]),
        amountIn: E("0.666666666666666667"),
        minOut: 660000,
      },
    ]);

    await expect(
      manager.connect(user).mintSingle(
        await fot.getAddress(),
        E("2"),
        user.address,
        1,
        buyData
      )
    )
      .to.be.revertedWithCustomError(fot, "ERC20InsufficientBalance")
      .withArgs(await manager.getAddress(), E("1.96"), E("1.98"));
  });

  it("fee-on-transfer output token is rejected at the intended boundary in redeemSingle", async function () {
    const { user, fotOut, manager, adapter } = await deployRedeemFixture();

    const sellData = encodeSellVenueData([
      {
        executor: ethers.ZeroAddress,
        oneInchData: ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("0.4995")]),
        amountIn: E("0.24975"),
        minOut: E("0.49"),
      },
      {
        executor: ethers.ZeroAddress,
        oneInchData: ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [E("0.4995")]),
        amountIn: E("0.4995"),
        minOut: E("0.49"),
      },
    ]);

    await expect(
      manager.connect(user).redeemSingle(
        E("0.5"),
        await fotOut.getAddress(),
        user.address,
        1,
        sellData
      )
    ).to.be.revertedWithCustomError(adapter, "OutputMismatch");
  });
});
