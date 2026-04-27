# RevenueRouter — SPEC

**Intent:**  
Split accumulated protocol revenue among fee distribution, treasury, and trader rewards sinks, with optional notify-mode accounting into single-token sinks.

## State
- `feeDistributorSink`
- `treasurySink`
- `traderRewardsSink`
- `feeDistributorMode`
- `traderRewardsMode`
- `feeDistributorBps`
- `treasuryBps`
- `traderRewardsBps`

## Invariants
- **INV-RR-01 (Split sums to 100%):** Fee + treasury + trader bps must equal `BPS_DENOM`.
- **INV-RR-02 (Notify-mode token compatibility):** If notify mode is used, router must verify sink token matches the token being distributed.
- **INV-RR-03 (Trader epoch required in trader notify mode):** Trader notify distribution requires explicit epoch input.
- **INV-RR-04 (Treasury is plain transfer path):** Treasury leg always transfers token directly.
- **INV-RR-05 (Approvals reset):** Temporary notify approvals are reset to zero after notify calls.

## Permissions
- **DAO/Admin:** `setSinks`, `setSinkModes`, `setSplit`, `pause`, `unpause`, `sweep`
- **Owner/Governance ops:** `distribute(token)` or `distribute(token, traderEpoch)`

## External Interactions
- `FeeDistributorERC20.notifyRewardAmount(amount)`
- `TraderRewardsLocker.notifyRewardAmount(epoch, amount)`
- ERC20 transfers to treasury or transfer-mode sinks

## Failure Modes
- Revert on:
  - zero token address
  - zero router balance
  - sink token mismatch in notify mode
  - missing trader epoch in trader notify mode
  - bad split or invalid sink config

## Events
- `SinksUpdated(...)`
- `SinkModesUpdated(...)`
- `SplitUpdated(...)`
- `Distributed(token, totalAmount, toFeeDistributor, toTreasury, toTraderRewards)`
- `Swept(token, to, amount)`

## Tests Map
- **INV-RR-01:** `test/RevenueRouter.t.sol::testSplitMustSumToBpsDenom()`
- **INV-RR-02:** `test/RevenueRouter.t.sol::testNotifyModeChecksSinkTokenCompatibility()`
- **INV-RR-03:** `test/RevenueRouter.t.sol::testTraderNotifyModeRequiresEpoch()`
- **INV-RR-04:** `test/RevenueRouter.t.sol::testTreasuryAlwaysReceivesTransfer()`
- **INV-RR-05:** `test/RevenueRouter.t.sol::testApprovalsResetAfterNotify()`
