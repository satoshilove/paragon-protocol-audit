# Build & Test Repro


# 0. Prereqs (Node 20+, pnpm)
node -v            # v20.x
corepack enable
npm -v

# 1. Install
npm i

# 2. Compile
npm hardhat compile

# 3. Run the whole suite
npm hardhat test

# 4. Only the extra security suites
npm hardhat test \
  test/exchange/ParagonPair.extra.js \
  test/exchange/ParagonRouter.extra.js \
  test/farms/ParagonFarmController.extra.js \
  test/payflow/ParagonPayFlowExecutorV2.extra.js \
  test/vaults/ParagonLockingVault.extra.js
