const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const E = ethers.parseEther;

const BSC_CHAIN_ID = 56;

// ---- ENV YOU NEED ----
// BNB_FORK_RPC_URL=...
// FORK_BLOCK_NUMBER=optional
// ONEINCH_ROUTER_V6=0x111111125421ca6dc452d289314280a0f8842a65
// P10_FORK_WBNB=...
// P10_FORK_USDT=...
// P10_FORK_BTCB=...
// P10_FORK_WETH=...
// P10_FORK_USER= funded fork account to impersonate
//
// Optional, but recommended for real swap execution:
// P10_ONEINCH_BUY_VENUE_DATA='{"swaps":[...]}'
// P10_ONEINCH_SELL_VENUE_DATA='{"swaps":[...]}'
//
// Notes:
// 1) This test assumes you already know how to obtain a real 1inch route payload.
// 2) The venueData format must match your P10Venue1Inch structs.
// 3) This is intentionally wiring-focused. It proves your live router / adapter / venue flow.

function addr(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env ${name}`);
  return v;
}

function maybeInt(name, fallback) {
  return process.env[name] ? Number(process.env[name]) : fallback;
}

function encodeVenueDataFromEnv(envName) {
  const raw = process.env[envName];
  if (!raw) throw new Error(`Missing env ${envName}`);
  const parsed = JSON.parse(raw);

  return ethers.AbiCoder.defaultAbiCoder().encode(
    ["tuple(tuple(address executor, bytes oneInchData, uint256 amountIn, uint256 minOut)[] swaps)"],
    [parsed]
  );
}

async function impersonate(address) {
  await network.provider.request({
    method: "hardhat_impersonateAccount",
    params: [address],
  });
  return ethers.getSigner(address);
}

describe("P10 fork integration with real 1inch wiring", function () {
  async function deployForkFixture() {
    if (network.name !== "hardhat") {
      throw new Error("Run this on hardhat fork only");
    }

    const [owner, feeRecipient] = await ethers.getSigners();

    const forkUserAddr = addr("P10_FORK_USER");
    const forkUser = await impersonate(forkUserAddr);

    // Give impersonated user ETH/BNB for tx gas on fork
    await network.provider.send("hardhat_setBalance", [
      forkUserAddr,
      "0x56BC75E2D63100000", // 100 BNB-ish in wei
    ]);

    const WBNB = await ethers.getContractAt("contracts/mocks/MockERC20.sol:MockERC20", addr("P10_FORK_WBNB"));
    const USDT = await ethers.getContractAt("contracts/mocks/MockERC20.sol:MockERC20", addr("P10_FORK_USDT"));
    const BTCB = await ethers.getContractAt("contracts/mocks/MockERC20.sol:MockERC20", addr("P10_FORK_BTCB"));
    const WETH = await ethers.getContractAt("contracts/mocks/MockERC20.sol:MockERC20", addr("P10_FORK_WETH"));

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

    const Adapter = await ethers.getContractFactory("P10OneInchAdapter");
    const adapter = await Adapter.deploy(
      owner.address,
      owner.address,
      addr("ONEINCH_ROUTER_V6")
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

    // ---- Use mock pricing for deterministic NAV on fork ----
    await (await pricing.setPrice(await BTCB.getAddress(), E("100000"), true)).wait();
    await (await pricing.setPrice(await WETH.getAddress(), E("2500"), true)).wait();
    await (await pricing.setPrice(await WBNB.getAddress(), E("600"), true)).wait();
    await (await pricing.setPrice(await USDT.getAddress(), E("1"), true)).wait();

    // Example basket:
    // 0.001 BTCB ($100)
    // 0.02 WETH ($50)
    // 0.05 WBNB ($30)
    // 20 USDT ($20)
    // NAV = $200
    await (await manager.activateSnapshot(
      [
        await BTCB.getAddress(),
        await WETH.getAddress(),
        await WBNB.getAddress(),
        await USDT.getAddress(),
      ],
      [18, 18, 18, 18],
      [
        E("0.001"),
        E("0.02"),
        E("0.05"),
        E("20"),
      ]
    )).wait();

    await (await USDT.connect(forkUser).approve(await manager.getAddress(), ethers.MaxUint256)).wait();
    await (await BTCB.connect(forkUser).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await WETH.connect(forkUser).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await WBNB.connect(forkUser).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await USDT.connect(forkUser).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    await (await p10.connect(forkUser).approve(await manager.getAddress(), ethers.MaxUint256)).wait();

    return {
      owner,
      feeRecipient,
      forkUser,
      p10,
      manager,
      vault,
      exec,
      adapter,
      venue,
      BTCB,
      WETH,
      WBNB,
      USDT,
    };
  }

  it("fork mintSingle via real 1inch venue wiring", async function () {
    const { forkUser, manager, USDT, p10 } = await deployForkFixture();

    const amountIn = E("200"); // $200 nominal
    const beforeP10 = await p10.balanceOf(await forkUser.getAddress());

    const buyVenueData = encodeVenueDataFromEnv("P10_ONEINCH_BUY_VENUE_DATA");

    await expect(
      manager.connect(forkUser).mintSingle(
        await USDT.getAddress(),
        amountIn,
        await forkUser.getAddress(),
        1,
        buyVenueData
      )
    ).to.emit(manager, "Minted");

    const afterP10 = await p10.balanceOf(await forkUser.getAddress());
    expect(afterP10).to.be.gt(beforeP10);
  });

  it("fork redeemSingle via real 1inch venue wiring", async function () {
    const { forkUser, manager, p10, USDT } = await deployForkFixture();

    // Seed supply using basket-exact path first
    await (await manager.connect(forkUser).mintBasketExact(
      [
        E("0.001"),
        E("0.02"),
        E("0.05"),
        E("20"),
      ],
      await forkUser.getAddress()
    )).wait();

    const p10In = E("0.5");
    const beforeUSDT = await USDT.balanceOf(await forkUser.getAddress());

    const sellVenueData = encodeVenueDataFromEnv("P10_ONEINCH_SELL_VENUE_DATA");

    await expect(
      manager.connect(forkUser).redeemSingle(
        p10In,
        await USDT.getAddress(),
        await forkUser.getAddress(),
        1,
        sellVenueData
      )
    ).to.emit(manager, "Redeemed");

    const afterUSDT = await USDT.balanceOf(await forkUser.getAddress());
    expect(afterUSDT).to.be.gt(beforeUSDT);
  });
});