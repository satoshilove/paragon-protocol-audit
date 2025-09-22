# Threat Model


## Exchange
- **AMM math & fees:** invariant violations, fee rounding drift, skim/sync abuse.
- **MEV/price manipulation:** low-liquidity windows, sandwich.
- **ERC20 quirks:** fee-on-transfer, non-standard `decimals`, revert-on-zero.
- **Reentrancy:** callbacks on tokens; CEI enforced.


## Oracle
- **Staleness/zero price:** bounded by `staleThreshold`; revert on zero; circuit breaker.
- **Manipulation:** TWAP windows; min liquidity thresholds to read.


## Payflow
- **Signature replay:** nonces + expiries; EIP-712 domain separators pinned.
- **Best-exec spoofing:** cross-check with on-chain quotes; bound slippage; revert on route mismatch.
- **Surplus distribution:** rounding/overflow risk → checked math; events for auditability.


## DAO
- **Governance capture:** quorum/threshold design; timelocks; pause power separation.
- **Emission math:** epoch rollover rounding; cap per epoch; gauge weights must sum to 1.


## Cross-cutting
- **Access control:** onlyOwner/onlyDAO gating with bounds; zero-address guards.
- **Upgradability:** init locks; UUPS/1967 safety; storage layout freezes.
- **Denial of service:** gas grief on loops; per-tx bound checks; pagination.