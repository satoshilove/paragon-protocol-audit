# FeeDistributorERC20 — SPEC

**Intent:** Receive protocol fee tokens and dispense them to gauges (or recipients) pro-rata by configured shares/weights.

## State
- `supportedRewardTokens[]` — allowed fee tokens
- `recipientShare[gauge]` — share (bps) of fee distributions
- `totalRecipientShare` — sum of shares (bps)
- `sweeper` / `dao` — roles for rescue/admin

## Invariants
- **INV-FD-01 (Sum bound):** `totalRecipientShare ≤ 10000 bps`.
- **INV-FD-02 (Exact allocation):** `distribute(token)` sends the current token balance to recipients according to shares, subject to rounding at most ±1 wei.
- **INV-FD-03 (Allow-listed):** Only supported reward tokens can be distributed; others revert or are ignored.

## Permissions
- **DAO/Admin:** manage recipients & shares, set supported tokens
- **Anyone/bot:** trigger `distribute(token)` when balances accrue

## External Interactions
- ERC-20 transfers of fee tokens to gauges or direct recipients

## Failure Modes
- Revert on invalid shares (sum>10000), unknown token, zero recipient

## Events
- `RecipientSet(recipient, bps)`
- `SupportedRewardAdded(token)`, `SupportedRewardRemoved(token)`
- `Distributed(token, total, recipients[], amounts[])`

## Tests Map
- **INV-FD-01:** `test/FeeDistributor.t.sol::testSharesSumBound()`
- **INV-FD-02:** `test/FeeDistributor.t.sol::testExactSplitSum()`
- **INV-FD-03:** `test/FeeDistributor.t.sol::testAllowlistedTokensOnly()`
