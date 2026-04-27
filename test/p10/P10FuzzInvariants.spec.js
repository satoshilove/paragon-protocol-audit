const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = ethers.parseEther;

function rng(seed) {
  let x = BigInt(seed);
  return () => {
    x ^= x << 13n;
    x ^= x >> 7n;
    x ^= x << 17n;
    x &= (1n << 63n) - 1n;
    return x;
  };
}

function randInt(next, min, max) {
  const span = BigInt(max - min + 1);
  return Number(next() % span) + min;
}

function normalizeTo1e18(amount, decimals) {
  const amt = BigInt(amount);
  if (decimals === 18) return amt;
  if (decimals < 18) return amt * (10n ** BigInt(18 - decimals));
  return amt / (10n ** BigInt(decimals - 18));
}

describe("P10 fuzz / invariant stress", function () {
  async function deployBase() {
    const [owner, user] = await ethers.getSigners();

    const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
    const tokens = [];
    const decimalsList = [6, 8, 12, 18, 24];

    for (let i = 0; i < 5; i++) {
      const t = await ERC.deploy(`Token${i}`, `TK${i}`, decimalsList[i]);
      await t.waitForDeployment();
      tokens.push(t);
    }

    const Pricing = await ethers.getContractFactory("contracts/mocks/MockP10Pricing.sol:MockP10Pricing");
    const pricing = await Pricing.deploy();
    await pricing.waitForDeployment();

    const P10 = await ethers.getContractFactory("P10Token");
    const p10 = await P10.deploy(owner.address);
    await p10.waitForDeployment();

    const Manager = await ethers.getContractFactory("P10IndexManager");
    const manager = await Manager.deploy(owner.address, await p10.getAddress(), await pricing.getAddress());
    await manager.waitForDeployment();

    const Vault = await ethers.getContractFactory("P10Vault");
    const vault = await Vault.deploy(owner.address, owner.address);
    await vault.waitForDeployment();

    await (await vault.setIndexManager(await manager.getAddress())).wait();
    await (await manager.setVault(await vault.getAddress())).wait();
    await (await p10.setIndexManager(await manager.getAddress())).wait();
    await (await p10.connect(user).approve(await manager.getAddress(), ethers.MaxUint256)).wait();

    for (const t of tokens) {
      await (await t.mint(user.address, 10_000_000n * 10n ** BigInt(await t.decimals()))).wait();
      await (await t.connect(user).approve(await vault.getAddress(), ethers.MaxUint256)).wait();
    }

    return { owner, user, tokens, pricing, p10, manager, vault };
  }

  it("randomized NAV matches expected math across mixed decimals / prices / weights", async function () {
    const { tokens, pricing, manager } = await deployBase();
    const next = rng(42);

    for (let iter = 0; iter < 20; iter++) {
      const chosen = [];
      const decimals = [];
      const units = [];
      let expectedNav = 0n;

      for (let i = 0; i < 3; i++) {
        const idx = i;
        const token = tokens[idx];
        const dec = await token.decimals();
        const price = BigInt(randInt(next, 1, 5000)) * 10n ** 18n;
        const weight = BigInt(randInt(next, 1, 5)) * 10n ** 17n; // 0.1 to 0.5

        await (await pricing.setPrice(await token.getAddress(), price, true)).wait();

        chosen.push(await token.getAddress());
        decimals.push(Number(dec));
        units.push(weight.toString());

        expectedNav += (weight * price) / 10n ** 18n;
      }

      await (await manager.activateSnapshot(chosen, decimals, units)).wait();
      expect(await manager.navPerP10USD()).to.equal(expectedNav);
    }
  });

  it("randomized basket ratio deposits mint and redeem symmetrically up to fees", async function () {
    const next = rng(777);

    for (let iter = 0; iter < 10; iter++) {
      const { user, tokens, pricing, p10, manager } = await deployBase();

      const chosen = [];
      const decimals = [];
      const units = [];
      const amounts = [];

      const k = BigInt(randInt(next, 1, 5)); // one scalar shared across all legs

      for (let i = 0; i < 3; i++) {
        const token = tokens[i];
        const dec = Number(await token.decimals());
        const price = BigInt(randInt(next, 1, 3000)) * 10n ** 18n;
        const unit = BigInt(randInt(next, 1, 3)) * 10n ** 17n; // 0.1 to 0.3

        await (await pricing.setPrice(await token.getAddress(), price, true)).wait();

        chosen.push(await token.getAddress());
        decimals.push(dec);
        units.push(unit.toString());

        let raw;
        if (dec === 18) {
          raw = unit * k;
        } else if (dec < 18) {
          raw = (unit * k) / (10n ** BigInt(18 - dec));
        } else {
          raw = (unit * k) * (10n ** BigInt(dec - 18));
        }

        const roundTrip = normalizeTo1e18(raw, dec);
        if (roundTrip !== unit * k) {
          i--;
          chosen.pop();
          decimals.pop();
          units.pop();
          continue;
        }

        amounts.push(raw);
      }

      await (await manager.activateSnapshot(chosen, decimals, units)).wait();

      const balancesBefore = [];
      for (let i = 0; i < 3; i++) {
        balancesBefore.push(await tokens[i].balanceOf(user.address));
      }
 
      await (await manager.connect(user).mintBasketExact(amounts, user.address)).wait();

      const minted = await p10.balanceOf(user.address);
      expect(minted).to.be.gt(0);

      await (await manager.connect(user).redeemBasketProRata(minted, user.address)).wait();

      for (let i = 0; i < 3; i++) {
        const balAfter = await tokens[i].balanceOf(user.address);
        expect(balAfter).to.be.lte(balancesBefore[i]);
      }
    }
  });

  it("randomized previews remain conservative across mixed decimals and prices", async function () {
    const { tokens, pricing, manager } = await deployBase();
    const next = rng(999);

    for (let iter = 0; iter < 10; iter++) {
      const chosen = [];
      const decimals = [];
      const units = [];

      for (let i = 0; i < 3; i++) {
        const token = tokens[i];
        const dec = Number(await token.decimals());
        const price = BigInt(randInt(next, 1, 4000)) * 10n ** 18n;
        const unit = BigInt(randInt(next, 1, 4)) * 10n ** 17n;

        await (await pricing.setPrice(await token.getAddress(), price, true)).wait();

        chosen.push(await token.getAddress());
        decimals.push(dec);
        units.push(unit.toString());
      }

      await (await manager.activateSnapshot(chosen, decimals, units)).wait();

      const amountIn = 10n ** BigInt(decimals[0]);
      const previewMint = await manager.previewMintSingle(chosen[0], amountIn);
      expect(previewMint).to.be.gt(0);

      const previewRedeem = await manager.previewRedeemSingle(E("0.1"), chosen[0]);
      expect(previewRedeem).to.be.gt(0);
    }
  });
});