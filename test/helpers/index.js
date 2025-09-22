// test/helpers/index.js
const { ethers } = require("hardhat");

async function now() {
  const b = await ethers.provider.getBlock("latest");
  return Number(b.timestamp);
}
async function deadline(secs = 600) {
  return BigInt((await now()) + secs);
}
async function timeTravel(secs) {
  await ethers.provider.send("evm_increaseTime", [secs]);
  await ethers.provider.send("evm_mine", []);
}
async function mineBlocks(n = 1) {
  for (let i = 0; i < n; i++) await ethers.provider.send("evm_mine", []);
}

module.exports = { now, deadline, timeTravel, mineBlocks };
