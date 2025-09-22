# ParagonPayflowExecutorV2 — SPEC

**Intent:** Execute user-signed swap intents (EIP-712), route via Router, and split **surplus** among trader cashback, LP flow rebates, locker vault, optional protocol cut, and optional relayer fee. Supports path-based routing (max 5 hops) and fee-on-transfer tokens via Router.

## State (key)
- `router: IParagonRouterV2Like` — execution venue (must support FOT-safe swaps)
- `bestExec: IBestExec` — nonce/intent verifier & consumer
- `daoVault` — protocol revenue sink (if `protocolFeeBips > 0`)
- `lpRebates: ILPFlowRebates` — LP attribution sink (optional)
- `lockerVault` — address that receives the **locker** portion
- `protocolFeeBips` — cap **≤ 1000** (10% of **surplus**) — enforced in setters
- Split bips: `traderBips`, `lpBips` (locker share = `10000 - traderBips - lpBips`; `_checkSplit()` enforces `traderBips + lpBips ≤ 10000`)
- `relayerFeeBips` — cap **≤ 10 bps** (0.10%), from **surplus only**
- (Optional integrations) `usdValuer`, `reputationOperator`
- **Constants:** `MAX_PATH_LEN = 5`

## API (primary)
- `execute(SwapIntent it, bytes sig)` — route using on-chain discovery
- `executeWithPath(SwapIntent it, address[] path, uint256[] hopShareBips)` — caller provides path and optional per-hop LP attribution
- **Owner/DAO admin:** `setParams`, `setSplitBips`, `setRelayerFeeBips`, `setUsdValuer`, `setReputationOperator`, `sweep(token)`, `sweepNative()`

## Invariants
- **INV-PF-01 (Nonce single-use):** A `(user, nonce)` is consumed at most once (via `bestExec.consume`) within the tx.
- **INV-PF-02 (Basic guards):** Revert unless `tokenIn ≠ tokenOut`, `recipient ≠ 0`, and `deadline` valid.
- **INV-PF-02a (Path validity for executeWithPath):** For `executeWithPath`, `path.length ∈ [2, MAX_PATH_LEN]`, `path[0] == it.tokenIn`, and `path[path.length-1] == it.tokenOut`; else revert (`PathMismatch/PathTooLong`).
- **INV-PF-03 (User protection):** `amountReceived ≥ it.minAmountOut` else revert.
- **INV-PF-04 (Split bounds):** `traderBips + lpBips ≤ 10000`; locker share = `10000 - traderBips - lpBips`. Emit `SplitUpdated` on change.
- **INV-PF-05 (Fee caps):** `protocolFeeBips ≤ 1000`; `relayerFeeBips ≤ 10`.
- **INV-PF-06 (Per-hop attribution):** If `hopShareBips` used, `hopShareBips.length == path.length - 1` and sum of all hop shares = **10000**; otherwise LP portion is notified once for the whole trade.
- **INV-PF-07 (Settlement order):** relayer → protocol → trader → LP rebate notify → locker vault.
- **INV-PF-08 (Relayer fee behavior):** Relayer fee applies **only when `msg.sender != it.user`**, is taken **from surplus only**, and **never** reduces the user below `minAmountOut`.

## External Interactions
- Calls Router swap (FOT-safe first; regular fallback if applicable)
- Calls `bestExec.consume(it, sig)` to verify & increment nonce
- Notifies `lpRebates.notify(...)` per hop if configured
- Transfers locker share to `lockerVault`, protocol cut to `daoVault`
- Optionally values USD via `IUsdValuer` and reports to `IReputationOperator`

## Failure Modes
- Revert on wrong path/length (`PathMismatch/PathTooLong`), invalid recipient, Router failure, stale/invalid signature via `bestExec`; any `permit` failures bubble up if used in the flow.

## Events
- `PayflowExecuted(user, tokenIn, tokenOut, amountIn, minOut, amountOut, surplus, traderGet, lpShare, lockerShare, protocolCut, recipient)`
- `LPRebateAttributed(tokenIn, tokenOut, rewardToken, amount)`
- `SplitUpdated(traderBips, lpBips, lockerBips)`
- `RelayerFeeUpdated(bps)`, `RelayerPaid(relayer, amount)`
- `ParamsUpdated(...)`

## Tests Map
- **INV-PF-01:** `test/Payflow.t.sol::testNonceConsumedOnce()`
- **INV-PF-02:** `test/Payflow.t.sol::testSwapGuards()`
- **INV-PF-02a:** `test/Payflow.t.sol::testExecuteWithPathGuards()`
- **INV-PF-03:** `test/Payflow.t.sol::testMinOutRespected()`
- **INV-PF-04/05:** `test/Payflow.t.sol::testSplitAndCaps()`
- **INV-PF-06:** `test/Payflow.t.sol::testPerHopAttribution()`
- **INV-PF-07:** `test/Payflow.t.sol::testSettlementOrder()`
- **INV-PF-08:** `test/Payflow.t.sol::testRelayerFeeFromSurplusOnly()`