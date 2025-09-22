# Governance & Permissions


**Controllers**
- **DAO (ve/Governor + Timelock):** Parameter changes, emissions, gauge weights, whitelist lists.
- **Guardian Multisig:** Emergency pause/unpause, circuit breakers, upgrade trigger with delay.
- **Ops Bots:** Keeper-style automation (epoch rolls, oracle keep-alive) — *no funds custody*.


**Timelocks (suggested defaults)**
- Param changes: **≥48h**
- Contract upgrades: **≥72h** (EIP-1967 ProxyAdmin behind DAO timelock)
- Emergency pause: immediate; unpause after **24h** review window


**Upgrade Model**
- If proxies are used: `initializer` guards on implementations; ProxyAdmin controlled by DAO timelock; migration runbooks appended to RUNBOOK.md.


**Centralization Risk Mitigation**
- On-chain **bounds** for all sensitive setters (fees, emissions, oracle staleness, slippage caps).
- Role separation: DAO vs Guardian vs Ops; no `tx.origin` usage; least-privilege design.


**Auditor Pointers**
- See PERMISSIONS_MATRIX.csv for function-level mapping; see PARAMS_REGISTRY.md for allowed ranges.