require("@nomicfoundation/hardhat-toolbox");
require("@typechain/hardhat");
require("solidity-coverage");
require("hardhat-gas-reporter");
require("dotenv").config();

/** @type {import('hardhat/config').HardhatUserConfig} */
const config = {
  solidity: {
    version: "0.8.25",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true, // <-- enable IR pipeline to fix "stack too deep"
    },
  },
  networks: {
    hardhat: { chainId: 31337 },
    bscTestnet: {
      url: process.env.BSC_TESTNET_RPC_URL || "",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 97,
    },
  },
  typechain: { outDir: "typechain-types", target: "ethers-v6" },
  gasReporter: { enabled: true, currency: "USD", excludeContracts: ["contracts/mocks/"] },
  paths: { sources: "contracts", tests: "test", cache: "cache", artifacts: "artifacts" },
};

module.exports = config;
