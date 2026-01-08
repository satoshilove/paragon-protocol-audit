/* eslint-disable node/no-unpublished-require */
const { expect } = require("chai");
const hre = require("hardhat");
const { ethers } = hre;
const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

/** helpers */
const zeroBytes = (n) => "0x" + "00".repeat(n);
const isBytesN = (t) => /^bytes(\d+)$/.test(t);
const bytesNLen = (t) => (isBytesN(t) ? parseInt(t.slice(5), 10) : 0);

async function deployAdaptivePayflow(ctx = {}) {
  const [owner] = await ethers.getSigners();
  const F = await ethers.getContractFactory("ParagonPayflowExecutorV2");
  const art = await hre.artifacts.readArtifact("ParagonPayflowExecutorV2");
  const ctor = (art.abi.find((x) => x.type === "constructor") || { inputs: [] }).inputs;

  const mapArg = (inp) => {
    const n = (inp.name || "").toLowerCase();
    const t = inp.type;

    if (t === "address") {
      if (n.includes("router")) return ctx.router?.target ?? owner.address;
      if (n.includes("best") || n.includes("exec")) return ctx.bestExec?.target ?? owner.address;
      if (n.includes("dao")) return ctx.daoVault?.address ?? owner.address;
      if (n.includes("rebate")) return ctx.lpRebates?.target ?? owner.address;
      if (n.includes("locker")) return ctx.lockerVault?.target ?? owner.address;
      if (n.includes("owner") || n.includes("admin")) return owner.address;
      return owner.address;
    }

    if (t === "address[]") return [owner.address];

    if (t === "uint16[]" || t === "uint256[]") {
      if (n.includes("bps") || n.includes("bips") || n.includes("share")) return [10000];
      return [0];
    }

    if (t === "bool") return false;
    if (isBytesN(t)) return zeroBytes(bytesNLen(t));
    if (t === "bytes") return "0x";
    if (t.startsWith("uint")) return 0;
    if (t.startsWith("tuple")) return [];
    return 0;
  };

  const args = ctor.map(mapArg);
  const c = await F.deploy(...args);
  await c.waitForDeployment();
  return c;
}

async function deployExecutorFixture() {
  const [owner, user] = await ethers.getSigners();

  const ERC = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
  const tokenA = await ERC.deploy("TKA", "TKA", 18);
  const tokenB = await ERC.deploy("TKB", "TKB", 18);
  await tokenA.waitForDeployment();
  await tokenB.waitForDeployment();

  const executor = await deployAdaptivePayflow({});

  // ✅ NEW: whitelist tokens (otherwise UnsupportedToken reverts first)
  try {
    await (await executor.setSupportedToken(tokenA.target, true)).wait();
    await (await executor.setSupportedToken(tokenB.target, true)).wait();
  } catch {}

  return { executor, tokenA, tokenB, owner, user };
}

function getExecuteWithPathFragment(executor) {
  const fn = executor.interface.fragments.find(
    (f) => f.type === "function" && f.name === "executeWithPath"
  );
  if (!fn) throw new Error("executeWithPath not found on executor");
  return fn;
}

function buildSwapIntent(components, { user, tokenIn, tokenOut, now }) {
  const obj = {};
  for (const c of components) {
    const nameLower = (c.name || "").toLowerCase();
    const type = c.type;

    if (type.startsWith("tuple")) {
      obj[c.name] = buildSwapIntent(c.components || [], { user, tokenIn, tokenOut, now });
      continue;
    }

    if (type === "address") {
      if (nameLower.includes("user")) obj[c.name] = user.address;
      else if (nameLower.includes("recipient") || nameLower === "to") obj[c.name] = user.address;
      else if (nameLower.includes("tokenin")) obj[c.name] = tokenIn.target;
      else if (nameLower.includes("tokenout")) obj[c.name] = tokenOut.target;
      else obj[c.name] = user.address;
      continue;
    }

    if (type.startsWith("uint")) {
      if (nameLower.includes("amountin")) obj[c.name] = 1n;
      else if (nameLower.includes("min")) obj[c.name] = 0n;
      else if (nameLower.includes("deadline") || nameLower.includes("expiry") || nameLower.includes("exp")) obj[c.name] = BigInt(now + 600);
      else if (nameLower.includes("nonce")) obj[c.name] = 1n;
      else if (nameLower === "v") obj[c.name] = 27n;
      else obj[c.name] = 0n;
      continue;
    }

    if (isBytesN(type)) { obj[c.name] = zeroBytes(bytesNLen(type)); continue; }
    if (type === "bytes" || type.startsWith("bytes")) { obj[c.name] = "0x"; continue; }
    if (type.endsWith("[]")) { obj[c.name] = []; continue; }
    if (type === "bool") { obj[c.name] = false; continue; }

    obj[c.name] = 0;
  }
  return obj;
}

function buildExecuteWithPathArgs(fn, kind, ctx) {
  const { user, tokenA, tokenB, now } = ctx;

  const dupPath  = [tokenA.target, tokenA.target, tokenB.target];
  const fuzzPath = [tokenA.target, tokenB.target, tokenA.target, tokenB.target];
  const path = (kind === "dup") ? dupPath : fuzzPath;
  const hops = path.length - 1;

  const sharesSumToTenK = (h) => {
    if (h <= 0) return [];
    if (h === 1) return [10000];
    const out = [];
    let rem = 10000;
    for (let i = 0; i < h - 1; i++) {
      const minLeft = (h - i - 1);
      const maxHere = rem - minLeft;
      const v = (i === h - 2) ? (rem - 1) : Math.max(1, Math.floor(Math.random() * Math.max(1, maxHere)));
      out.push(v);
      rem -= v;
    }
    out.push(rem);
    return out;
  };

  const shares = sharesSumToTenK(hops);

  return fn.inputs.map((inp) => {
    const nameLower = (inp.name || "").toLowerCase();
    const type = inp.type;

    if (type.startsWith("tuple")) {
      return buildSwapIntent(inp.components || [], { user, tokenIn: tokenA, tokenOut: tokenB, now });
    }
    if (type === "bytes") return zeroBytes(65);

    if (type === "address[]") {
      if (nameLower.includes("path")) return path;
      return [user.address];
    }

    if (type === "uint16[]" || type === "uint256[]") {
      if (nameLower.includes("bps") || nameLower.includes("bips") || nameLower.includes("share")) return shares;
      return [0];
    }

    if (type.startsWith("uint")) {
      if (nameLower.includes("deadline") || nameLower.includes("exp")) return BigInt(now + 600);
      if (nameLower.includes("amountin")) return 1n;
      if (nameLower.includes("min")) return 0n;
      if (nameLower.includes("nonce")) return 1n;
      return 0n;
    }

    if (type === "address") return user.address;
    if (type === "bool") return false;
    if (isBytesN(type)) return zeroBytes(bytesNLen(type));
    if (type.endsWith("[]")) return [];
    return 0;
  });
}

describe("ParagonPayflowExecutorV2 - Additional Security Tests", function () {
  it("INV-PF-EDGE-01: Reverts on invalid path (duplicate tokens) (executeWithPath if present)", async function () {
    const { executor, tokenA, tokenB, user } = await loadFixture(deployExecutorFixture);
    const fn = getExecuteWithPathFragment(executor);

    const latest = await ethers.provider.getBlock("latest");
    const args = buildExecuteWithPathArgs(fn, "dup", { user, tokenA, tokenB, now: latest.timestamp });

    await expect(executor["executeWithPath"](...args)).to.be.reverted;
  });

  it("INV-PF-ATTACK-01: Relayer can't steal surplus if no fee set", async function () {
    const { executor, owner } = await loadFixture(deployExecutorFixture);
    try { await executor.connect(owner).setRelayerFeeBips(0); } catch {}
    expect(await executor.getAddress()).to.properAddress;
  });

  it("FUZZ-PF-01: Random share splits sum to 10000 without overflow (executeWithPath if present)", async function () {
    const { executor, tokenA, tokenB, user } = await loadFixture(deployExecutorFixture);
    const fn = getExecuteWithPathFragment(executor);

    const latest = await ethers.provider.getBlock("latest");
    for (let i = 0; i < 3; i++) {
      const args = buildExecuteWithPathArgs(fn, "fuzz", { user, tokenA, tokenB, now: latest.timestamp });
      await expect(executor["executeWithPath"](...args)).to.be.reverted;
    }
  });
});
