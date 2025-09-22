# Audit Scope — Paragon Protocol

- **Project:** Paragon Protocol (DEX + Payflow + Farm + DAO)
- **Tag (frozen):** v1.0.0-audit
- **Commit:** <98273f7f0117d518040b77d90229adcfdd9dbae0>
- **Package lock hash:** sha256(pnpm-lock.yaml)=<DF038F04FAC28E92B912FF974AE9F35A153FD7E7504E65711FB668A51E3442BA>
- **Solidity / Tooling Pins:**
  - Solidity: <0.8.25> (optimizer: enabled, runs=<200>)
  - Hardhat: <2.26.3>, ethers v6
  - OpenZeppelin: <5.4.0>

## In-scope (production contracts only)

### DEX / Exchange (`contracts/exchange/`)
- `ParagonFactory.sol`
- `ParagonPair.sol`
- `ParagonRouter.sol`
- `ParagonRouterAdmin.sol` 
- `ParagonZapV2.sol` 
- `ParagonOracle.sol`
- `WETH9.sol`

### Payflow (`contracts/payflow/`)
- `ParagonPayflowExecutorV2.sol`
- `ParagonBestExecutionV14.sol`
- `LPFlowRebates.sol`  
- `LockerCollector.sol`
- `TreasurySplitter.sol`
- Interfaces used by the above (e.g., `IUsdValuer`, `IReputationOperator`)

### DAO / Emissions / Gauges / Locker (`contracts/dao/`)
- `VoterEscrow.sol`
- `GaugeController.sol`
- `SimpleGauge.sol`
- `EmissionsMinter.sol`
- `FeeDistributorERC20.sol`  
- `TraderRewardsLocker.sol`
- `UsagePoints.sol`

### Dripper / Treasury / Utils
- `RewardDripperEscrow.sol`
- `TreasurySplitter.sol` 
- `Multicall.sol` 

> **Note:** If any of the above are not deployed in this release, mark them **out-of-scope** explicitly to avoid wasted time.

## Out-of-scope
- `contracts/mocks/**`, `contracts/test/**`
- Hardhat scripts, deployment helpers, subgraph, UI, marketing
- Off-chain relayer/signing services for Payflow (unless specified otherwise)
- Non-canonical or deprecated variants not deployed under `v1.0.0-audit`

## Networks
- **Local Hardhat** (for deterministic repro)
- **BSC Testnet (97)** — addresses in RUNBOOK.md
- **BSC Mainnet** — **TBA** (out-of-scope until addresses are frozen)

## Code-freeze window
- `<START_YYYY-MM-DD>` → audit end. Only auditor-requested fixes allowed. Any change requires bumping tag to `v1.0.0-audit.1` and a new commit hash.

## Known assumptions
- ERC-20 behavior is “standard” unless FOT; Router/Payflow include FOT-safe paths.
- Oracle: Chainlink-style semantics where used (staleness/decimals normalized).
- Governance: timelock minima per `GOVERNANCE.md` (provide link/file).

## Privileged roles & admin ops (for review)
- Owner/DAO/Timelock/Multisig addresses (testnet & mainnet TBA)
- Pause controls: RouterAdmin, Vault emergency mode
- Payflow params: `setSplitBips`, `setRelayerFeeBips`, `setParams`
- Dripper schedule & cooldown controls

## Auditor deliverables
- Findings report (Critical/High/Medium/Low/Informational)
- PoC/Tests for exploitable issues
- Recommended fixes/patch review included
