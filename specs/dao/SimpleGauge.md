# SimpleGauge — SPEC

**Intent:** Receive emissions (from Emitter) and fee rewards (from FeeDistributorERC20), track stake, and let stakers claim pro-rata.

## State
- `stakingToken` — LP or asset to stake
- `totalStaked`, `balanceOf[user]`
- `rewardPerTokenStored[token]`
- `userPaidPerToken[user][token]`, `accrued[user][token]`
- `emissionsDistributor` — Emitter address authorized to notify emissions

## Invariants
- **INV-SG-01 (Accounting):** On stake/withdraw/notify, `rewardPerTokenStored` and user accruals update so that `claim()` pays exactly accrued amounts.
- **INV-SG-02 (Authorized notify):** Only `emissionsDistributor` (and optionally FeeDistributor) may `notifyRewardAmount`.
- **INV-SG-03 (No reentrancy):** All state-changing flows are non-reentrant.

## Permissions
- **Public:** `stake`, `withdraw`, `claim(rewardTokens[])`
- **Emitter/FeeDistributor:** `notifyRewardAmount(token, amount)`

## External Interactions
- Transfers staking token and reward tokens

## Failure Modes
- Revert on zero amount stake/withdraw, unauthorized notify

## Events
- `Staked(user, amount)`, `Withdrawn(user, amount)`
- `RewardNotified(token, amount)`, `Claimed(user, token, amount)`

## Tests Map
- **INV-SG-01:** `test/Gauge.t.sol::testAccrualAndClaimExact()`
- **INV-SG-02:** `test/Gauge.t.sol::testOnlyEmitterCanNotify()`
- **INV-SG-03:** `test/Gauge.t.sol::testNonReentrant()`
