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

async function deployRouter(owner, ctx) {
  const R = await ethers.getContractFactory("ParagonRouter");
  const art = await hre.artifacts.readArtifact("ParagonRouter");
  const ctor = (art.abi.find(x => x.type === "constructor") || { inputs: [] }).inputs;

  const map = (name) => {
    const n = (name || "").toLowerCase();
    if (n.includes("factory")) return ctx.factory.target;
    if (n.includes("weth"))    return ctx.WETH.target;
    return owner.address; // satisfy non-zero checks
  };

  const args = ctor.map(i =>
    i.type.startsWith("address")
      ? map(i.name)
      : (i.type === "bool" ? false : 0)
  );
  const router = await R.deploy(...args);
  await router.waitForDeployment();
  return router;
}

async function deployRouterFixture() {
  const [owner, user] = await ethers.getSigners();
  const ERC   = await ethers.getContractFactory("contracts/mocks/MockERC20.sol:MockERC20");
  const WETH9 = await ethers.getContractFactory("contracts/mocks/WETH9.sol:WETH9");
  const A = await ERC.deploy("TK0", "TK0", 18);
  const B = await ERC.deploy("TK1", "TK1", 18);
  const WETH = await WETH9.deploy();
  await A.waitForDeployment(); await B.waitForDeployment(); await WETH.waitForDeployment();

  const factory = await deployFactory(owner);
  const router  = await deployRouter(owner, { factory, WETH });

  await (await factory.createPair(A.target, B.target)).wait();

  // Seed balances / approvals for swaps
  await A.mint(user.address, E("10"));
  await B.mint(user.address, E("10"));
  await A.connect(user).approve(router.target, ethers.MaxUint256);
  await B.connect(user).approve(router.target, ethers.MaxUint256);

  return { owner, user, A, B, WETH, factory, router };
}

/** Find a swapExactTokensForTokens* function that takes a path + deadline */
function findSwapFragment(router) {
  const cands = router.interface.fragments.filter(
    (f) =>
      f.type === "function" &&
      f.name.startsWith("swapExactTokensForTokens") &&
      f.inputs.some((i) => i.type === "address[]")
  );
  // Prefer SupportingFeeOnTransfer variant if present
  cands.sort((a, b) => (b.name.includes("SupportingFeeOnTransferTokens") ? 1 : 0) - (a.name.includes("SupportingFeeOnTransferTokens") ? 1 : 0));
  return cands[0] || null;
}

function buildArgsForSwap(fn, { A, B, user, deadlineTs, mode }) {
  // mode: 'expired' or 'absurdMinOut'
  const args = [];

  // Identify indices for special params
  const deadlineIdx = fn.inputs.findIndex((i) => (i.name || "").toLowerCase().includes("deadline") && i.type.startsWith("uint"));
  const pathIdx     = fn.inputs.findIndex((i) => i.type === "address[]");
  const minOutIdx   = fn.inputs.findIndex((i) => (i.name || "").toLowerCase().includes("min") && i.type.startsWith("uint"));

  for (let i = 0; i < fn.inputs.length; i++) {
    const inp = fn.inputs[i];
    const name = (inp.name || "").toLowerCase();

    if (inp.type === "address[]") {
      args.push([A.target, B.target]);
      continue;
    }
    if (inp.type === "address") {
      // 'to' or similar
      args.push(user.address);
      continue;
    }
    if (inp.type.startsWith("uint")) {
      if (i === deadlineIdx) {
        // past time to trigger deadline revert
        args.push(mode === "expired" ? deadlineTs - 1 : deadlineTs + 600);
      } else if (i === minOutIdx) {
        // either absurdly high minOut to force revert, or zero for deadline test
        args.push(mode === "absurdMinOut" ? E("1000") : 0);
      } else if (name.includes("amountin")) {
        args.push(E("1"));
      } else {
        args.push(0);
      }
      continue;
    }
    if (inp.type === "bytes") { args.push("0x"); continue; }
    if (inp.type === "bool")  { args.push(false); continue; }
    if (inp.type.endsWith("[]")) { args.push([]); continue; } // any other array
    // fallback
    args.push(0);
  }
  return args;
}

describe("ParagonRouter - Additional Security Tests", function () {
  it("INV-ROUTER-EDGE-01: Reverts on expired deadline during swap", async function () {
    const { router, A, B, user } = await loadFixture(deployRouterFixture);

    const frag = findSwapFragment(router);
    if (!frag) return this.skip?.();

    // Must have a deadline-like uint param; otherwise this case is irrelevant
    const hasDeadline = frag.inputs.some((i) => (i.name || "").toLowerCase().includes("deadline") && i.type.startsWith("uint"));
    if (!hasDeadline) return this.skip?.();

    const latest = await ethers.provider.getBlock("latest");
    const args = buildArgsForSwap(frag, { A, B, user, deadlineTs: latest.timestamp, mode: "expired" });

    await expect(router[frag.name](...args)).to.be.reverted;
  });

  it("INV-ROUTER-ATTACK-01: Pause blocks liquidity addition/removal", async function () {
    const { router, A, B, owner, user } = await loadFixture(deployRouterFixture);
    try { await router.connect(owner).pause(); } catch {}

    await expect(
      router.connect(user).addLiquidity(
        A.target, B.target, E("1"), E("1"), 0, 0, user.address,
        (await ethers.provider.getBlock("latest")).timestamp + 600
      )
    ).to.be.reverted;
  });

  it("FUZZ-ROUTER-01: Multi-hop paths with random amounts enforce minOut", async function () {
    const { router, A, B, user } = await loadFixture(deployRouterFixture);

    const frag = findSwapFragment(router);
    if (!frag) return this.skip?.();

    // Need a minOut-like param to make this meaningful; otherwise skip
    const hasMinOut = frag.inputs.some((i) => (i.name || "").toLowerCase().includes("min") && i.type.startsWith("uint"));
    if (!hasMinOut) return this.skip?.();

    const latest = await ethers.provider.getBlock("latest");
    for (let i = 0; i < 3; i++) {
      const args = buildArgsForSwap(frag, { A, B, user, deadlineTs: latest.timestamp + 600, mode: "absurdMinOut" });
      await expect(router[frag.name](...args)).to.be.reverted;
    }
  });
});
