| ID | Area | Risk | Impact | Likelihood | Severity | Mitigation | Status |
|---:|------|------|------|----------|-----------|----------|---------|
| EX-01 | Exchange | Invariant drift on fee accounting | High | Low | High | Fuzz tests; invariants; audited math | Open |
| EX-02 | Exchange | ERC20 FOT/deflation breaks Router flows | Medium | Medium | Medium | FOT-safe paths + tests; explicit warnings | Open |
| OR-01 | Oracle | Stale/zero/manipulated price | High | Low | High | Stale threshold; TWAP; circuit breaker; pause | Open |
| PF-01 | Payflow | Signature replay / domain mixup | High | Low | High | Nonces; expiry; chainId/domain pin; EIP-712 verification | Open |
| PF-02 | Payflow | MEV sandwich around intents | Medium | Medium | Medium | MinOut/MaxSlippage; TWAP checks; revert-on-worse | Open |
| PF-03 | Payflow | Partial fills / griefing | Medium | Low | Medium | Atomic execution; all-or-nothing; bounded gas | Monitoring |
| DAO-01 | DAO | Gauge weight overflow / mis-sum | Medium | Low | Medium | MAX_BPS=10k; per-user sum≤100%; cooldown | Mitigated |
| GOV-01 | Governance | Privileged param abuse | High | Low | High | On-chain bounds + DAO timelock | Open |
| GOV-02 | Governance | Emergency pause misuse | Medium | Low | Medium | Guardian pause; DAO-only unpause (timelocked) | Open |
| GA-01 | Gauges | Bypass vote cooldown / double voting | Medium | Low | Medium | 7-day cooldown; replace-in-place accounting | Mitigated |
| GA-02 | Gauges | Remove gauge leaves stale weight | Medium | Low | Medium | Zero weight on removal; compact list | Mitigated |
| EM-01 | EmissionsMinter | Funding source failure (mint/treasury) | High | Low | High | `useMinting` flag; treasury nonzero; tests | Open |
| EM-02 | EmissionsMinter | Double push same week | Medium | Low | Medium | Week boundary guard; `lastPushedWeek` check | Mitigated |
| EM-03 | EmissionsMinter | Weight drift due to controller error | Medium | Low | Medium | Controller address updatable by DAO; pausable ecosystem | Monitoring |
| FD-01 | FeeDistributor | Mismatch snapshots (supply vs user) | High | Low | High | End-of-week snapshots for both; tested | Mitigated |
| FD-02 | FeeDistributor | Unbounded claim window gas grief | Medium | Low | Medium | Default 12 completed weeks; cursor updates | Mitigated |
| DR-01 | Dripper | Misordered/duplicate rate schedule | Medium | Low | Medium | Strictly increasing `startTime`; revert on past | Mitigated |
| DR-02 | Dripper | Reentrancy on `drip()` | High | Low | High | `nonReentrant`; pull/push cap; tests | Mitigated |
| DR-03 | Dripper | Allowance miswire on farm change | Medium | Low | Medium | Revoke old allowance; grant new max; toggle tested | Mitigated |
| SG-01 | SimpleGauge | Reward rate math under/overflow | Medium | Low | Medium | Accrual with leftovers; capped duration; tests | Mitigated |
| SG-02 | SimpleGauge | Stuck rewards (no approval) | Medium | Low | Medium | Owner/minter-only `notify`; `transferFrom` checks | Monitoring |
| VE-01 | VoterEscrow | Rounding / week alignment bugs | Medium | Low | Medium | Round-up unlocks; round-down weeks; checkpoints | Mitigated |
| VE-02 | VoterEscrow | Slope/bias underflow on decay | Medium | Low | Medium | Clamp at 0; week-by-week decay; tests | Mitigated |
| VL-01 | LockingVault | Early-unlock penalty miscalc | Medium | Low | Medium | Bips bound (≤10000); tests; DAO recipient | Mitigated |
| VL-02 | LockingVault | Emergency mode misuse | Medium | Low | Medium | Owner/Guardian toggle; deposits blocked; audits | Monitoring |
| USG-01 | UsagePoints | Inflated points by rogue caller | High | Low | High | Allowlist callers; bips caps; per-user daily cap | Mitigated |
| USG-02 | UsagePoints | Integer scaling drift (1e18) | Medium | Low | Medium | Unit tests; explicit comments; bounds | Monitoring |
| TRL-01 | TraderRewardsLocker | Lock creation fails (ve signature order) | Medium | Low | Medium | Dual ABI support (`useSolidlyOrder`); approvals | Mitigated |
| TRL-02 | TraderRewardsLocker | Kickback abuse | Medium | Low | Medium | Kickback ≤10%; DAO-settable; events | Mitigated |
| FARM-01 | Farm | Performance fee > cap | High | Low | High | Max 500 bips; on-chain check; events | Mitigated |
| FARM-02 | Farm | Dripper recursion / revert | Medium | Low | Medium | Skip if `msg.sender==dripper`; `try/catch` | Mitigated |
| SEC-01 | Tokens | Infinite approvals / residue | Medium | Medium | Medium | `forceApprove` usage; sweep only for non-core | Monitoring |
| OPS-01 | Ops | Keeper missed epochs / rolls | Medium | Medium | Medium | Public/permissionless entrypoints; runbooks | Monitoring |
| DEP-01 | Tooling | Solidity version skew (0.8.25) | Medium | Low | Medium | Pin compiler; CI matrix; `pragma` unify | Mitigated |
| UPG-01 | Upgrades | Proxy storage collisions | High | Low | High | EIP-1967 + layout docs + tests (if proxies used) | Open |
