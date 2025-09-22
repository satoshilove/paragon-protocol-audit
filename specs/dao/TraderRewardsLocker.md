# TraderRewardsLocker — SPEC

**Intent:** Lock trader rewards (e.g., XPGN or stXPGN) under a vesting schedule; users claim vested amounts over time.

> If your file is **TraderRewardsLocker.sol** or **TraderRewardLocker.sol**, keep this SPEC name consistent with the actual filename and events.

## State
- `rewardToken` — token being locked/vested
- `locks[user]` → `{ total, claimed, start, cliff, duration }`
- `dao` / `operator` — roles that can create locks (from Payflow or a distributor)

## Invariants
- **INV-TRL-01 (One-way progress):** `claimed ≤ vested ≤ total` always; claimed never decreases.
- **INV-TRL-02 (Vesting math):** Before `start + cliff` vested = 0; after `start + duration` vested = total; between is linear (or contract’s chosen formula).
- **INV-TRL-03 (No reentrancy):** `claim()` and `createLock()` are non-reentrant.

## Permissions
- **Operator/DAO:** `createLock(user, amount, start, cliff, duration)`; optionally `topUp(user, amount)` with same schedule
- **User:** `claim(to)`; view `vested(user)`

## External Interactions
- ERC-20 transfers in on create/top-up; out on claim

## Failure Modes
- Revert on zero addresses/amounts, overlapping schedule if not allowed, insufficient balance

## Events
- `LockCreated(user, amount, start, cliff, duration)`
- `LockToppedUp(user, amount)`
- `Claimed(user, to, amount)`

## Tests Map
- **INV-TRL-01:** `test/Locker.t.sol::testClaimNeverExceedsVested()`
- **INV-TRL-02:** `test/Locker.t.sol::testLinearVestingTimeline()`
- **INV-TRL-03:** `test/Locker.t.sol::testNonReentrant()`
