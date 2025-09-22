/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const hre = require("hardhat");
const { ethers } = hre;
const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const E = (n) => ethers.parseEther(n);

async function deployFactory(owner) {
  const F = await ethers.getContractFactory("ParagonFactory");
  const art = await hre.artifacts.readArtifact("ParagonFactory");
  const ctor = (art.abi.find(x => x.type === "constructor") || { inputs: [] }).inputs;
  const args = ctor.map(inp =>
    inp.type.startsWith("address")
      ? owner.address
      : (inp.type === "bool" ? false : 0)
  );
  const factory = await F.deploy(...args);
  await factory.waitForDeployment();
  return factory;
}

async function deployPairFixture() {
  const [owner, user] = await ethers.getSigners();

  const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
  const A = await ERC.deploy("TK0", "TK0", 18);
  const B = await ERC.deploy("TK1", "TK1", 18);
  await A.waitForDeployment();
  await B.waitForDeployment();

  const factory = await deployFactory(owner);
  const tx = await factory.createPair(A.target, B.target);
  const rc = await tx.wait();

  let pairAddr;
  try { pairAddr = await factory.getPair(A.target, B.target); }
  catch {
    const ev = rc.logs.find(l => l.fragment && l.fragment.name === "PairCreated");
    pairAddr = ev.args.pair;
  }
  const Pair = await ethers.getContractFactory("ParagonPair");
  const pair = Pair.attach(pairAddr);

  // seed liquidity
  await A.mint(user.address, E("1000"));
  await B.mint(user.address, E("1000"));
  await A.connect(user).transfer(pair.target, E("10"));
  await B.connect(user).transfer(pair.target, E("10"));
  await pair.connect(user).mint(user.address);

  return { owner, user, A, B, pair };
}

// Conservative output: use <= 1/3rd of the classic 0.3% formula to avoid fee-variant reverts
function calcSafeOut(amountIn, reserveIn, reserveOut) {
  const amountInWithFee = amountIn * 997n; // classic
  const num = amountInWithFee * reserveOut;
  const den = reserveIn * 1000n + amountInWithFee;
  const theo = num / den;
  if (theo <= 3n) return 1n;
  return theo / 3n; // extra cushion for non-0.3% fee setups
}

describe("ParagonPair - Additional Security Tests", function () {
  it("INV-PAIR-EDGE-01: Handles minimal swap amounts without underflow", async function () {
    const { pair, A, user } = await loadFixture(deployPairFixture);
    await A.connect(user).transfer(pair.target, 1n); // dust
    await expect(pair.connect(user).swap(0n, 1n, user.address, "0x")).to.be.reverted;
  });

  it("INV-PAIR-ATTACK-01: Resists flashloan-like reserve manipulation", async function () {
    const { pair, A, B, user } = await loadFixture(deployPairFixture);
    const beforeA = await A.balanceOf(pair.target);
    const beforeB = await B.balanceOf(pair.target);

    await A.connect(user).transfer(pair.target, E("5"));
    await B.connect(user).transfer(pair.target, E("3"));
    const userA0 = await A.balanceOf(user.address);
    const userB0 = await B.balanceOf(user.address);

    await pair.connect(user).skim(user.address);

    const afterA = await A.balanceOf(pair.target);
    const afterB = await B.balanceOf(pair.target);
    const userA1 = await A.balanceOf(user.address);
    const userB1 = await B.balanceOf(user.address);

    expect(afterA).to.equal(beforeA);
    expect(afterB).to.equal(beforeB);
    expect(userA1 - userA0).to.equal(E("5"));
    expect(userB1 - userB0).to.equal(E("3"));
  });

  it("FUZZ-PAIR-01: Random swaps maintain k-invariant (simulated fuzz)", async function () {
    const { pair, A, B, user } = await loadFixture(deployPairFixture);
    const t0 = await pair.token0();
    const token0IsA = t0.toLowerCase() === A.target.toLowerCase();

    for (let i = 0; i < 6; i++) {
      const { _reserve0, _reserve1 } = await pair.getReserves();
      const r0 = BigInt(_reserve0);
      const r1 = BigInt(_reserve1);
      const kBefore = r0 * r1;

      const amountIn = 1000n + BigInt(i) * 777n;

      if (i % 2 === 0) {
        // A -> B
        await A.connect(user).transfer(pair.target, amountIn);
        const out = calcSafeOut(amountIn, token0IsA ? r0 : r1, token0IsA ? r1 : r0);
        const amount0Out = token0IsA ? 0n : out;
        const amount1Out = token0IsA ? out : 0n;
        await pair.connect(user).swap(amount0Out, amount1Out, user.address, "0x");
      } else {
        // B -> A
        await B.connect(user).transfer(pair.target, amountIn);
        const out = calcSafeOut(amountIn, token0IsA ? r1 : r0, token0IsA ? r0 : r1);
        const amount0Out = token0IsA ? out : 0n;
        const amount1Out = token0IsA ? 0n : out;
        await pair.connect(user).swap(amount0Out, amount1Out, user.address, "0x");
      }

      const { _reserve0: r0b, _reserve1: r1b } = await pair.getReserves();
      const kAfter = BigInt(r0b) * BigInt(r1b);
      expect(kAfter).to.be.gte(kBefore);
    }
  });
});
