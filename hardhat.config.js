const path = require("path");

// Force load root .env (../.env from /audit)
require("dotenv").config({
  path: path.resolve(__dirname, "../.env"),
});

require("@nomicfoundation/hardhat-toolbox");
require("@typechain/hardhat");
require("solidity-coverage");
require("hardhat-gas-reporter");

/** @type {import('hardhat/config').HardhatUserConfig} */

const {
  BSC_TESTNET_RPC_URL,
  PRIVATE_KEY,
  REPORT_GAS,
  SOLIDITY_COVERAGE,
} = process.env;

// Optional debug
if (BSC_TESTNET_RPC_URL) {
  console.log("Loaded RPC:", BSC_TESTNET_RPC_URL);
} else {
  console.log("Loaded RPC: <not set, local hardhat only>");
}

const isCoverage = SOLIDITY_COVERAGE === "true";
const enableGasReporter = REPORT_GAS === "true";

function compilerSettings(version) {
  return {
    version,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: isCoverage ? false : true,
    },
  };
}

const networks = {
  hardhat: {
    chainId: 31337,
  },
};

// Only require deployment secrets when using bscTestnet
if (BSC_TESTNET_RPC_URL && PRIVATE_KEY) {
  networks.bscTestnet = {
    url: BSC_TESTNET_RPC_URL,
    accounts: [PRIVATE_KEY],
    chainId: 97,
  };
}

const config = {
  solidity: {
    compilers: [
      compilerSettings("0.8.25"),
      compilerSettings("0.8.27"),
    ],
    overrides: {
      "contracts/P10ExecutionManager.sol": compilerSettings("0.8.27"),
      "contracts/P10IndexManager.sol": compilerSettings("0.8.27"),
      "contracts/P10OneInchAdapter.sol": compilerSettings("0.8.27"),
      "contracts/P10Venue1Inch.sol": compilerSettings("0.8.27"),
      "contracts/P10VenueParagon.sol": compilerSettings("0.8.27"),
      "contracts/P10Vault.sol": compilerSettings("0.8.27"),
      "contracts/P10Token.sol": compilerSettings("0.8.27"),
      "contracts/P10View.sol": compilerSettings("0.8.27"),
    },
  },

  networks,

  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6",
  },

  gasReporter: {
    enabled: enableGasReporter,
    currency: "USD",
    excludeContracts: ["contracts/mocks/"],
  },

  paths: {
    sources: "contracts",
    tests: "test",
    cache: "cache",
    artifacts: "artifacts",
  },

  mocha: {
    timeout: 120000,
  },
};

module.exports = config;