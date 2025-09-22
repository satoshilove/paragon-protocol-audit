// test/helpers/index.js (or wherever you export from)
const { ethers } = require("hardhat");

// parseEther helper (unchanged)
const E = (n) => ethers.parseEther(n);

// --- Chain-time helpers (✅ use the latest block timestamp) ---
async function now() {
  const b = await ethers.provider.getBlock("latest");
  // return a JS number; safe for timestamps
  return Number(b.timestamp);
}

async function deadline(secs = 600) {
  // return BigInt for uint256 params
  return BigInt((await now()) + secs);
}

// Convenience miners (handy in a lot of tests)
async function mineBlocks(n = 1) {
  for (let i = 0; i < n; i++) {
    await ethers.provider.send("evm_mine", []);
  }
}
async function timeTravel(secs) {
  await ethers.provider.send("evm_increaseTime", [secs]);
  await ethers.provider.send("evm_mine", []);
}

module.exports = { E, now, deadline, mineBlocks, timeTravel };
